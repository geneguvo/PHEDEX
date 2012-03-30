package PHEDEX::Testbed::Lifecycle::Command;
#
# Not a true class, simply a repository for shared code among Lifecycle
# Agent perl plugins using external commands
#
use strict;
use warnings;
use base 'PHEDEX::Core::Logging';
use POE qw( Queue::Array );
use Clone qw(clone);
use Data::Dumper;

our $me;

sub new {
  return $me if $me; # I am idempotent!
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self = { parent => shift };

  $self->{Alias} = __PACKAGE__;

  $self->{_njobs} = 0;
  $self->{QUEUE} = POE::Queue::Array->new();

  $self->{Verbose} = $self->{parent}->{Verbose};
  $self->{Debug}   = $self->{parent}->{Debug};
  bless $self, $class;

  POE::Session->create(
    object_states => [
      $self => {
        _start          => '_start',
        on_child_stdout => 'on_child_stdout',
        on_child_stderr => 'on_child_stderr',
        on_child_close  => 'on_child_close',
        on_child_signal => 'on_child_signal',
        start_task      => 'start_task',
      },
    ]
  );
  $me = $self;
  return $self;
}

sub Dbgmsg { my $self = shift; $self->SUPER::Dbgmsg(@_) if $self->{Debug}; }

sub _start {
  my ($self,$kernel,$session) = @_[ OBJECT, KERNEL, SESSION ];
  $kernel->alias_set($self->{Alias});
  $self->{SESSION} = $session;
}

use POSIX;
sub slow {
  my $i = 3;
  while ( $i-- ) { print "slow... $i\n"; sleep 1; }
  POSIX::_exit(3);
}

sub start_task {
  my ($self,$heap,$kernel,$job) = @_[ OBJECT, HEAP, KERNEL, ARG0 ];
  my ($payload,$workflow,$method,$target,$params,$callback,$priority,$q_id);

  if ( $self->{_njobs} >= $self->{parent}{NJobs} ) {
    $self->Dbgmsg("enqueued $job->{method}($job->{target},",Data::Dumper->Dump([$job->{params}]),")\n");
    $self->{QUEUE}->enqueue(1,$job);
    return;
  }

  if ( ! $job ) {
    ($priority,$q_id,$job) = $self->{QUEUE}->dequeue_next();
    return unless $job;
  }
  $self->{_njobs}++;
  $payload  = $job->{payload};
  $workflow = $payload->{workflow};
  $method   = $job->{method};
  $target   = $job->{target};
  $params   = $job->{params};
  $callback = $job->{callback};

  $self->Dbgmsg("$method($target,",Data::Dumper->Dump([$params]),")\n");
  my $child = POE::Wheel::Run->new(
    Program => sub {
      my $ua = $self->{UA};
      my $response = $ua->$method($target,$params);
      my $content = $response->content();
      if ( $ua->response_ok($response) ) {
        print $content;
      } else {
        chomp $content;
        print "Bad response from server ",$response->code(),"(",$response->message(),"):\n$content\n";
        exit $response->code();
      }
    }, # TODO not thread-safe!
    StdoutEvent  => "on_child_stdout",
    StderrEvent  => "on_child_stderr",
    CloseEvent   => "on_child_close",
  );

  $kernel->sig_child($child->PID, "on_child_signal");
  $heap->{children_by_wid}{$child->ID} = $child;
  $heap->{children_by_pid}{$child->PID} = $child;
  $heap->{state}{$child->PID} = {
			 callback => $callback,
			 target   => $target,
			 params   => $params,
			 payload  => clone $payload,
			};

  $self->Dbgmsg("Child pid ",$child->PID," started as wheel ",$child->ID,".\n");
};

sub on_child_stdout {
  my ($heap,$stdout_line,$wheel_id) = @_[HEAP, ARG0, ARG1];
  my $child = $heap->{children_by_wid}{$wheel_id};
  $heap->{state}{$child->PID}{stdout} .= $stdout_line;
}

sub on_child_stderr {
  my ($heap,$stderr_line,$wheel_id) = @_[HEAP, ARG0, ARG1];
  my $child = $_[HEAP]{children_by_wid}{$wheel_id};
  $heap->{state}{$child->PID}{stderr} .= $stderr_line;
}

sub on_child_close {
  my ($self,$wheel_id) = @_[ OBJECT, ARG0 ];
  my $child = delete $_[HEAP]{children_by_wid}{$wheel_id};

  unless (defined $child) {
    $self->Dbgmsg("wid $wheel_id closed all pipes.\n");
    return;
  }

  $self->Dbgmsg("pid ",$child->PID," closed all pipes.\n");
  delete $_[HEAP]{children_by_pid}{$child->PID};
}

sub on_child_signal {
  my($self,$kernel,$heap,$sig,$pid,$rc) = @_[ OBJECT, KERNEL, HEAP, ARG0, ARG1, ARG2 ];
  my ($child,$status,$signal,$event,$callback,$target,$params,$obj);
  my ($payload,$workflow,$p,$stdout,$stderr);

  $child = delete $_[HEAP]{children_by_pid}{$_[ARG1]};

  delete $_[HEAP]{children_by_wid}{$child->ID} if defined $child;

  $status = $rc >> 8;
  $signal = $rc & 127;
  $self->Dbgmsg("pid $pid exited with status=$status, signal=$signal\n");
  $p = $heap->{state}{$pid};
  $stdout   = $p->{stdout} || '';
  $stderr   = $p->{stderr} || '';
  $payload  = $p->{payload};
  $callback = $p->{callback};
  $target   = $p->{target};
  $params   = $p->{params};
  $workflow = $payload->{workflow};
  $event    = $workflow->{Event};
  delete $heap->{state}{$pid};

  if ( $status ) {
    $obj = {
      error  => $status,
      stdout => $stdout,
      stderr => $stderr,
    };
    $self->Alert("target=$target params=",Dumper($params)," event=$event, status=$status, stdout=\"$stdout\", stderr=\"$stderr\"");
  } else {
    if ( $stdout ) {
      eval {
        no strict 'vars';
        $obj = eval($stdout);
      };
      die "Error evaluating $stdout\n" if $@;
    } else {
      $self->Logmsg("No output for event=$event");
      $obj = { stderr => $stderr, };
    }
    $kernel->post($self->{PARENT_SESSION},$callback,$payload,$obj,$target,$params);
  }

  $self->{_njobs}--;
  if ( $self->{_njobs} < $self->{parent}{NJobs} ) {
    $kernel->yield('start_task');
  }
}

1;
