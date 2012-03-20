package PHEDEX::Core::Agent::DB;

use strict;
use warnings;
use POSIX;
use PHEDEX::Core::Timing;
use PHEDEX::Core::DB;
use Data::Dumper;

sub new
{
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my %h = @_;
  my $self = {};
  bless $self, $class;

  $self->{_AL} = $h{_AL};

  no warnings 'redefine'; 
  *PHEDEX::Core::AgentLite::connectAgent = \&PHEDEX::Core::Agent::DB::connectAgent;
  *PHEDEX::Core::AgentLite::disconnectAgent = \&PHEDEX::Core::Agent::DB::disconnectAgent;
  *PHEDEX::Core::AgentLite::rollbackOnError = \&PHEDEX::Core::Agent::DB::rollbackOnError;
  *PHEDEX::Core::AgentLite::checkNodes = \&PHEDEX::Core::Agent::DB::checkNodes;
  *PHEDEX::Core::AgentLite::identifyAgent = \&PHEDEX::Core::Agent::DB::identifyAgent;
  *PHEDEX::Core::AgentLite::updateAgentStatus = \&PHEDEX::Core::Agent::DB::updateAgentStatus;
  *PHEDEX::Core::AgentLite::checkAgentMessages = \&PHEDEX::Core::Agent::DB::checkAgentMessages;
  *PHEDEX::Core::AgentLite::expandNodes = \&PHEDEX::Core::Agent::DB::expandNodes;
  *PHEDEX::Core::AgentLite::myNodeFilter = \&PHEDEX::Core::Agent::DB::myNodeFilter;
  *PHEDEX::Core::AgentLite::otherNodeFilter = \&PHEDEX::Core::Agent::DB::otherNodeFilter;

  return $self;
}   
    
# this workaround is ugly but allow us NOT rewrite everything
sub AUTOLOAD
{
  my $self = shift; 
  my $attr = our $AUTOLOAD;
  $attr =~ s/.*:://;
  return unless $attr =~ /[^A-Z]/;      # skip all-cap methods

  # if $attr exits, catch the reference to it, note we will call something
  # only if belogs to the parent calling class.
  print " up from DB $attr\n";
  if ( $self->{_AL}->can($attr) ) { $self->{_AL}->$attr(@_); } 
  else { PHEDEX::Core::Logging::Alert($self,"Unknown method $attr for Agent::DB"); }
}   

# Connect to database and identify self
sub connectAgent
{
    my ($self, $identify) = @_;
    my $dbh;

    print Dumper(" *** connectAgent -> identitify ",$identify);
    $dbh = &connectToDatabase($self->{_AL});

    # Make myself known if I have a name.  If this fails, the database
    # is probably so wedged that we can't do anything useful, so bail
    # out.  The caller is in charge of committing or rolling back on
    # any errors raised.
    $self->checkNodes();
    if ($self->{_AL}->{MYNODE}) {
	$self->updateAgentStatus();
	$self->identifyAgent();
	$self->checkAgentMessages();
    }
    return $dbh;
}

# Disconnects an agent.  Well, not really.  See
# PHEDEX::Core::DB::disconnectFromDatabase.
sub disconnectAgent
{
    my ($self, $force) = @_;
    print Dumper(" *** disconnectAgent -> force", $force);
    return if ($self->{_AL}->{SHARED_DBH});
    &disconnectFromDatabase($self, $self->{_AL}->{DBH}, $force);
}

# For use after eval { } protected DB-interaction code.  Logs the
# error and rolls back any transaction.  Returns 1 if there was an
# error and it was rolled back, returns 0 otherwise.
sub rollbackOnError
{
    my ($self, $err) = @_;
    print Dumper(" *** rollbackOnError -> err", $err);
    $err ||= $@;
    return 0 unless $err;
    chomp ($err);
    $self->Alert($err);

    eval { $self->{_AL}->{DBH}->rollback() } if $self->{_AL}->{DBH};
    return 1;
}

# Check that nodes used are valid
sub checkNodes
{
    my ($self) = @_;

    my $q = &dbprep($self->{_AL}->{DBH}, qq{
        select count(*) from t_adm_node where name like :pat});

    if ( $self->{_AL}->{MYNODE} )
    {
      &dbbindexec($q, ':pat' => $self->{_AL}->{MYNODE});
      $self->Fatal("'$self->{_AL}->{MYNODE}' does not match any node known to TMDB, check -node argument\n")
	unless $q->fetchrow();
    }

    my %params = (NODES => '-nodes', ACCEPT_NODES => '-accept', IGNORE_NODES => '-ignore');
    while (my ($param, $arg) = each %params) {
	foreach my $pat (@{$self->{_AL}->{$param}}) {
	    &dbbindexec($q, ':pat' => $pat);
	    $self->Fatal("'$pat' does not match any node known to TMDB, check $arg argument\n")
		unless $q->fetchrow();
	}
    }

    return 1;
}

# Identify the version of the code packages running in this agent.
# Scan all the perl modules imported into this process, and identify
# each significant piece of code.  We collect following information:
# relative file name, file size in bytes, MD5 sum of the file contents,
# PhEDEx distribution version, the CVS revision and tag of the file.
sub identifyAgent
{
  my ($self) = @_;
  my $dbh = $self->{_AL}->{DBH};
  my $now = &mytimeofday();

  # If we have a new database connection, log agent start-up and/or
  # new database connection into the logging table.
  if ($dbh->{private_phedex_newconn})
  {
    my ($ident) = qx(ps -p $$ wwwwuh 2>/dev/null);
    chomp($ident) if $ident;
    &dbexec($dbh, qq{
          insert into t_agent_log
          (time_update, reason, host_name, user_name, process_id,
           working_directory, state_directory, message)
          values
          (:now, :reason, :host_name, :user_name, :process_id,
           :working_dir, :state_dir, :message)},
          ":now" => $now,
          ":reason" => ($self->{_AL}->{DBH_AGENT_IDENTIFIED}{$self->{_AL}->{MYNODE}}
          ? "AGENT RECONNECTED" : "AGENT STARTED"),
          ":host_name" => $self->{_AL}->{DBH_ID_HOST},
          ":user_name" => scalar getpwuid($<),
          ":process_id" => $$,
          ":working_dir" => &getcwd(),
          ":state_dir" => $self->{_AL}->{DROPDIR},
          ":message" => $ident);
    $dbh->{private_phedex_newconn} = 0;
    $dbh->commit();
  }

  # Avoid re-identifying ourselves further if already done.
  return if $self->{_AL}->{DBH_AGENT_IDENTIFIED}{$self->{_AL}->{MYNODE}};

  # Get PhEDEx distribution version.
  my $distribution = undef;
  my $versionfile = $INC{'PHEDEX/Core/DB.pm'};
  $versionfile =~ s|/perl_lib/.*|/VERSION|;
  if (open (DBHVERSION, "< $versionfile"))
  {
    chomp ($distribution = <DBHVERSION>);
    close (DBHVERSION);
  }

  # Get all interesting modules loaded into this process.
  my @files = ($0, grep (m!(^|/)(PHEDEX|Toolkit|Utilities|Custom)/!, values %INC));
  return if ! @files;

  # Get the file data for each module: size, checksum, CVS info.
  my %fileinfo = ();
  my %cvsinfo = ();
  foreach my $file (@files)
  {
    my ($path, $fname) = ($file =~ m!(.*)/(.*)!);
    $fname = $file if ! defined $fname;
    next if exists $fileinfo{$fname};

    if (defined $path)
    {
      if (-d $path && ! exists $cvsinfo{$path} && open (DBHCVS, "< $path/CVS/Entries"))
      {
        while (<DBHCVS>)
        {
          chomp;
          my ($type, $cvsfile, $rev, $date, $flags, $sticky) = split("/", $_);
          next if ! $cvsfile || ! $rev;
          $cvsinfo{$path}{$cvsfile} = {
	      REVISION => $rev,
	      REVDATE => $date,
	      FLAGS => $flags,
	      STICKY => $sticky
          };
        }
        close (DBHCVS);
      }

      $fileinfo{$fname} = $cvsinfo{$path}{$fname}
        if exists $cvsinfo{$path}{$fname};
    }

    if (-f $file)
    {
      if (my $cksum = qx(md5sum $file 2>/dev/null))
      {
	  chomp ($cksum);
	  my ($sum, $f) = split(/\s+/, $cksum);
	  $fileinfo{$fname}{CHECKSUM} = "MD5:$sum";
      }

      $fileinfo{$fname}{SIZE} = -s $file;
      $fileinfo{$fname}{DISTRIBUTION} = $distribution;
    }
  }

  # Update the database
  my $stmt = &dbprep ($dbh, qq{
	insert into t_agent_version
	(node, agent, time_update,
	 filename, filesize, checksum,
	 release, revision, tag)
	values
	(:node, :agent, :now,
	 :filename, :filesize, :checksum,
	 :release, :revision, :tag)});
	
  &dbexec ($dbh, qq{
	delete from t_agent_version
	where node = :node and agent = :me},
	":node" => $self->{_AL}->{ID_MYNODE},
	":me" => $self->{_AL}->{ID_AGENT});

  foreach my $fname (keys %fileinfo)
  {
    &dbbindexec ($stmt,
		     ":now" => $now,
		     ":node" => $self->{_AL}->{ID_MYNODE},
		     ":agent" => $self->{_AL}->{ID_AGENT},
		     ":filename" => $fname,
		     ":filesize" => $fileinfo{$fname}{SIZE},
		     ":checksum" => $fileinfo{$fname}{CHECKSUM},
		     ":release" => $fileinfo{$fname}{DISTRIBUTION},
		     ":revision" => $fileinfo{$fname}{REVISION},
		     ":tag" => $fileinfo{$fname}{STICKY});
  }

  $dbh->commit ();
  $self->{_AL}->{DBH_AGENT_IDENTIFIED}{$self->{_AL}->{MYNODE}} = 1;
}

# Update the agent status in the database.  This identifies the
# agent as having connected recently and alive.
sub updateAgentStatus
{
  my ($self) = @_;
  my $dbh = $self->{_AL}->{DBH};
  my $now = &mytimeofday();
  return if ($self->{_AL}->{DBH_AGENT_UPDATE}{$self->{_AL}->{MYNODE}} || 0) > $now - 5*60;

  # Obtain my node id
  my $me = $self->{_AL}->{ME};
  ($self->{_AL}->{ID_MYNODE}) = &dbexec($dbh, qq{
	select id from t_adm_node where name = :node},
	":node" => $self->{_AL}->{MYNODE})->fetchrow();
  $self->Fatal("node $self->{_AL}->{MYNODE} not known to the database\n")
        if ! defined $self->{_AL}->{ID_MYNODE};

  # Check whether agent and agent status rows exist already.
  ($self->{_AL}->{ID_AGENT}) = &dbexec($dbh, qq{
	select id from t_agent where name = :me},
	":me" => $me)->fetchrow();
  my ($state) = &dbexec($dbh, qq{
	select state from t_agent_status
	where node = :node and agent = :agent},
    	":node" => $self->{_AL}->{ID_MYNODE}, ":agent" => $self->{_AL}->{ID_AGENT})->fetchrow();

  # Add agent if doesn't exist yet.
  if (! defined $self->{_AL}->{ID_AGENT})
  {
    eval
    {
      &dbexec($dbh, qq{
        insert into t_agent (id, name)
        values (seq_agent.nextval, :me)},
        ":me" => $me);
    };
    die $@ if $@ && $@ !~ /ORA-00001:/;
      ($self->{_AL}->{ID_AGENT}) = &dbexec($dbh, qq{
    select id from t_agent where name = :me},
    ":me" => $me)->fetchrow();
  }

  # Add agent status if doesn't exist yet.
  my ($ninbox, $npending, $nreceived, $ndone, $nbad, $noutbox) = (0) x 7;
  my $dir = $self->{_AL}->{DROPDIR};
     $dir =~ s|/worker-\d+$||; $dir =~ s|/+$||; $dir =~ s|/[^/]+$||;
  my $label = $self->{_AL}->{DROPDIR};
     $label =~ s|/worker-\d+$||; $label =~ s|/+$||; $label =~ s|.*/||;
  if ( defined($self->{_AL}->{LABEL}) )
  {
    if ( $label ne $self->{_AL}->{LABEL} )
    {
#      print "Using agent label \"",$self->{LABEL},
#	    "\" instead of derived label \"$label\"\n";
      $label = $self->{_AL}->{LABEL};
    }
  }
  my $wid = ($self->{_AL}->{DROPDIR} =~ /worker-(\d+)$/ ? "W$1" : "M");
  my $fqdn = $self->{_AL}->{DBH_ID_HOST};
  my $pid = $$;

  my $dirtmp = $self->{_AL}->{INBOX};
  foreach my $d (<$dirtmp/*>) {
    $ninbox++;
    $nreceived++ if -f "$d/go";
  }

  $dirtmp = $self->{_AL}->{WORKDIR};
  foreach my $d (<$dirtmp/*>) {
    $npending++;
    $nbad++ if -f "$d/bad";
    $ndone++ if -f "$d/done";
  }

  $dirtmp = $self->{_AL}->{OUTDIR};
  foreach my $d (<$dirtmp/*>) {
    $noutbox++;
  }

  &dbexec($dbh, qq{
	merge into t_agent_status ast
	using (select :node node, :agent agent, :label label, :wid worker_id,
	            :fqdn host_name, :dir directory_path, :pid process_id,
	            1 state, :npending queue_pending, :nreceived queue_received,
	            :nwork queue_work, :ncompleted queue_completed,
	            :nbad queue_bad, :noutgoing queue_outgoing, :now time_update
	       from dual) i
	on (ast.node = i.node and
	    ast.agent = i.agent and
	    ast.label = i.label and
	    ast.worker_id = i.worker_id)
	when matched then
	  update set
	    ast.host_name       = i.host_name,
	    ast.directory_path  = i.directory_path,
	    ast.process_id      = i.process_id,
	    ast.state           = i.state,
	    ast.queue_pending   = i.queue_pending,
	    ast.queue_received  = i.queue_received,
	    ast.queue_work      = i.queue_work,
	    ast.queue_completed = i.queue_completed,
	    ast.queue_bad       = i.queue_bad,
	    ast.queue_outgoing  = i.queue_outgoing,
	    ast.time_update     = i.time_update
	when not matched then
          insert (node, agent, label, worker_id, host_name, directory_path,
		  process_id, state, queue_pending, queue_received, queue_work,
		  queue_completed, queue_bad, queue_outgoing, time_update)
	  values (i.node, i.agent, i.label, i.worker_id, i.host_name, i.directory_path,
		  i.process_id, i.state, i.queue_pending, i.queue_received, i.queue_work,
		  i.queue_completed, i.queue_bad, i.queue_outgoing, i.time_update)},
       ":node"       => $self->{_AL}->{ID_MYNODE},
       ":agent"      => $self->{_AL}->{ID_AGENT},
       ":label"      => $label,
       ":wid"        => $wid,
       ":fqdn"       => $fqdn,
       ":dir"        => $dir,
       ":pid"        => $pid,
       ":npending"   => $ninbox - $nreceived,
       ":nreceived"  => $nreceived,
       ":nwork"      => $npending - $nbad - $ndone,
       ":ncompleted" => $ndone,
       ":nbad"       => $nbad,
       ":noutgoing"  => $noutbox,
       ":now"        => $now);

  $dbh->commit();
  $self->{_AL}->{DBH_AGENT_UPDATE}{$self->{_AL}->{MYNODE}} = $now;
}

# Now look for messages to me.  There may be many, so handle
# them in the order given, but only act on the final state.
# The possible messages are "STOP" (quit), "SUSPEND" (hold),
# "GOAWAY" (permanent stop), and "RESTART".  We can act on the
# first three commands, but not the last one, except if the
# latter has been superceded by a later message: if we see
# both STOP/SUSPEND/GOAWAY and then a RESTART, just ignore
# the messages before RESTART.
#
# When we see a RESTART or STOP, we "execute" it and delete all
# messages up to and including the message itself (a RESTART
# seen by the agent is likely indication that the manager did
# just that; it is not a message we as an agent can do anything
# about, an agent manager must act on it, so if we see it, it's
# an indicatioon the manager has done what was requested).
# SUSPENDs we leave in the database until we see a RESTART.
#
# Messages are only executed until my current time; there may
# be "scheduled intervention" messages for future.
sub checkAgentMessages
{
  my ($self) = @_;
  my $dbh = $self->{_AL}->{DBH};

  while (1)
  {
    my $now = &mytimeofday ();
    my ($time, $action, $keep) = (undef, 'CONTINUE', 0);
    my $messages = &dbexec($dbh, qq{
	    select time_apply, message
	    from t_agent_message
	    where node = :node and agent = :me
	    order by time_apply asc},
	    ":node" => $self->{_AL}->{ID_MYNODE},
	    ":me" => $self->{_AL}->{ID_AGENT});
    while (my ($t, $msg) = $messages->fetchrow())
    {
      # If it's a message for a future time, stop processing.
      last if $t > $now;

      if ($msg eq 'SUSPEND' && $action ne 'STOP')
      {
	# Hold, keep this in the database.
	($time, $action, $keep) = ($t, $msg, 1);
	$keep = 1;
      }
      elsif ($msg eq 'STOP')
      {
	# Quit.  Something to act on, and kill this message
	# and anything that preceded it.
	($time, $action, $keep) = ($t, $msg, 0);
      }
      elsif ($msg eq 'GOAWAY')
      {
	# Permanent quit: quit, but leave the message in
	# the database to prevent restarts before 'RESTART'.
	($time, $action, $keep) = ($t, 'STOP', 1);
      }
      elsif ($msg eq 'RESTART')
      {
	# Restart.  This is not something we can have done,
	# so the agent manager must have acted on it, or we
	# are processing historical sequence.  We can kill
	# this message and everything that preceded it, and
	# put us back into 'CONTINUE' state to override any
	# previous STOP/SUSPEND/GOAWAY.
	($time, $action, $keep) = (undef, 'CONTINUE', 0);
      }
      else
      {
	# Keep anything we don't understand, but no action.
	$keep = 1;
      }

      &dbexec($dbh, qq{
	delete from t_agent_message
	where node = :node and agent = :me
	  and (time_apply < :t or (time_apply = :t and message = :msg))},
      	":node" => $self->{_AL}->{ID_MYNODE},
	":me" => $self->{_AL}->{ID_AGENT},
	":t" => $t,
	":msg" => $msg)
        if ! $keep;
    }

    # Apply our changes.
    $messages->finish();
    $dbh->commit();

    # Act on the final state.
    if ($action eq 'STOP')
    {
      $self->Logmsg ("agent stopped via control message at $time");
      $self->doStop ();
      $self->doExit(0); # Still running?
    }
    elsif ($action eq 'SUSPEND')
    {
      # The message doesn't actually specify for how long, take
      # a reasonable nap to avoid filling the log files.
      $self->Logmsg ("agent suspended via control message at $time");
      $self->nap (90);
      next;
    }
    else
    {
      # Good to go.
      last;
    }
  }
}

######################################################################
# Expand a list of node patterns into node names.  This function is
# called when we don't yet know our "node identity."  Also runs the
# usual agent identification process against the database.
sub expandNodes
{
  my ($self, $require) = @_;
  print Dumper(" *** expandNodes -> require",$require);
  my $dbh = $self->{_AL}->{DBH};
  my $now = &mytimeofday();
  my @result;

  # Construct a query filter for required other agents to be active
  my (@filters, %args);
  foreach my $agent ($require ? keys %$require : ())
  {
    my $var = ":agent@{[scalar @filters]}";
    push(@filters, "(a.name like ${var}n and s.time_update >= ${var}t)");
    $args{"${var}t"} = $now - $require->{$agent};
    $args{"${var}n"} = $agent;
  }
  my $filter = "";
  $filter = ("and exists (select 1 from t_agent_status s"
	     . " join t_agent a on a.id = s.agent"
	     . " where s.node = n.id and ("
	     . join(" or ", @filters) . "))")
	if @filters;

  # Now expand to the list of nodes
  foreach my $pat (@{$self->{_AL}->{NODES}})
  {
    my $q = &dbexec($dbh, qq{
      select id, name from t_adm_node n
      where n.name like :pat $filter
      order by name},
      ":pat" => $pat, %args);
    while (my ($id, $name) = $q->fetchrow())
    {
      $self->{_AL}->{NODES_ID}{$name} = $id;
      push(@result, $name);

      my $old_mynode = $self->{_AL}->{MYNODE};
      eval {
        $self->{_AL}->{MYNODE} = $name;
        $self->updateAgentStatus();
        $self->identifyAgent();
        $self->checkAgentMessages();
      };
      $self->{_AL}->{MYNODE} = $old_mynode if ( defined $old_mynode );
      die $@ if $@;
    }
  }

  return @result;
}

# Construct a database query for destination node pattern
sub myNodeFilter
{
  my ($self, $idfield) = @_;
  print Dumper(" *** myNodeFilter -> idfield", $idfield);
  my (@filter, %args);
  my $n = 1;
  foreach my $id (values %{$self->{_AL}->{NODES_ID}})
  {
    $args{":dest$n"} = $id;
    push(@filter, "$idfield = :dest$n");
    ++$n;
  }

  unless (@filter) {
      $self->Fatal("myNodeFilter() matched no nodes");
  }

  my $filter =  "(" . join(" or ", @filter) . ")";
  return ($filter, %args);
}

# Construct database query parameters for ignore/accept filters.
sub otherNodeFilter
{
  my ($self, $idfield) = @_;
  print Dumper(" *** otherNodeFilter -> idfield", $idfield);
  my $now = &mytimeofday();
  if (($self->{_AL}->{IGNORE_NODES_IDS}{LAST_CHECK} || 0) < $now - 300)
  {
    my $q = &dbprep($self->{_AL}->{DBH}, qq{
        select id from t_adm_node where name like :pat});

    my $index = 0;
    foreach my $pat (@{$self->{_AL}->{IGNORE_NODES}})
    {
      &dbbindexec($q, ":pat" => $pat);
      while (my ($id) = $q->fetchrow())
      {
        $self->{_AL}->{IGNORE_NODES_IDS}{MAP}{++$index} = $id;
      }
    }

    $index = 0;
    foreach my $pat (@{$self->{_AL}->{ACCEPT_NODES}})
    {
      &dbbindexec($q, ":pat" => $pat);
      while (my ($id) = $q->fetchrow())
      {
        $self->{_AL}->{ACCEPT_NODES_IDS}{MAP}{++$index} = $id;
      }
    }
    $self->{_AL}->{IGNORE_NODES_IDS}{LAST_CHECK} = $now;
  }

  my (@ifilter, @afilter, %args);
  while (my ($n, $id) = each %{$self->{_AL}->{IGNORE_NODES_IDS}{MAP}})
  {
    $args{":ignore$n"} = $id;
    push(@ifilter, "$idfield != :ignore$n");
  }
  while (my ($n, $id) = each %{$self->{_AL}->{ACCEPT_NODES_IDS}{MAP}})
  {
    $args{":accept$n"} = $id;
    push(@afilter, "$idfield = :accept$n");
  }

  my $ifilter = (@ifilter ? join(" and ", @ifilter) : "");
  my $afilter = (@afilter ? join(" or ", @afilter) : "");
  if (@ifilter && @afilter)
  {
    return ("and ($ifilter) and ($afilter)", %args);
  }
  elsif (@ifilter)
  {
    return ("and ($ifilter)", %args);
  }
  elsif (@afilter)
  {
    return ("and ($afilter)", %args);
  }
  return ("", ());
}

1;
