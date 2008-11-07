package PHEDEX::Monitoring::PerfMonitor::Agent;
use strict;
use warnings;
use base 'PHEDEX::Core::Agent', 'PHEDEX::Core::Logging';
use PHEDEX::Core::Timing;
use PHEDEX::Core::DB;

sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = $class->SUPER::new(@_);
    my $compact = time() + 3600;		# Delay compact at start-up
    my %params = (DBCONFIG => undef,		# Database configuration file
		  MYNODE => undef,		# My TMDB node name
	          WAITTIME => 60,		# Agent activity cycle
		  NEXT_RUN => 0,		# Next time to run
		  NEXT_COMPACT => $compact,	# Next time to compact old entries
		  ME => 'PerfMonitor',
		 );
    my %args = (@_);
    map { $$self{$_} = $args{$_} || $params{$_} } keys %params;
    bless $self, $class;
    return $self;
}

# Called by agent main routine before sleeping.  Update database.
sub idle
{
    my ($self, @pending) = @_;
    my $dbh = undef;
    eval
    {
	$dbh = $self->connectAgent();

	# Use 5-minute binning.
	my $now = &mytimeofday();
	my $timewidth = 300;
	my $timebin = int($now/$timewidth)*$timewidth;

	# Don't run until we need to.
	return if $now < $$self{NEXT_RUN};
	$$self{NEXT_RUN} = $timebin + $timewidth + 60;

	# PART I

	# Summarise various system aspects into stats tables.  This
	# covers only elements not already maintained by some other
	# agent: to avoid data trashing we usually have the agent
	# in charge of the data also maintaining the stats.
	#   - FilePump updates t_status_task
	#   - FileRouter updates t_status_request and t_status_path
	#   - This agent maintains the rest, but could rationalise
	#     in particular with BlockMonitor and BlockAllocate

	# Summarise block destination status.
	# FIXME: block destination -> subscriptions!?
	&dbexec($dbh, qq{delete from t_status_block_dest});
	&dbexec($dbh, qq{
	    insert into t_status_block_dest
	    (time_update, destination, state, files, bytes, is_custodial)
	    select :now, bd.destination, bd.state,
	           count(f.id), nvl(sum(f.filesize),0), bd.is_custodial
	    from t_dps_block_dest bd
	      join t_dps_file f on f.inblock = bd.block
	    group by :now, bd.destination, bd.state, bd.is_custodial},
	    ":now" => $now);

	# Summarise file origins.
	&dbexec($dbh, qq{delete from t_status_file});
	&dbexec($dbh, qq{
	    insert into t_status_file
	    (time_update, node, files, bytes)
	    select :now, br.node,
	           nvl(sum(br.src_files),0),
	           nvl(sum(br.src_bytes),0)
	    from t_dps_block_replica br
	    group by :now, br.node},
	    ":now" => $now);

	# Summarise nod replicas
	&dbexec($dbh, qq{delete from t_status_replica});
	&dbexec($dbh, qq{
	    insert into t_status_replica
	    (time_update, node, state, files, bytes, is_custodial)
	    select :now, br.node, 0,
	           nvl(sum (br.node_files), 0), nvl(sum (br.node_bytes), 0), br.is_custodial
	    from t_dps_block_replica br
	    group by br.node, br.is_custodial },
	    ":now" => $now);

	# PART II

	# Update statistics from the stats tables into the history.
	# These are heart beat routines where we don't want to miss
	# a bin in the time series histogram.
	&dbexec($dbh, qq{
	    merge into t_history_link_stats h using
	      (select :timebin timebin, :timewidth timewidth,
	      	      from_node, to_node, priority,
	              sum(files) pend_files,
		      sum(bytes) pend_bytes,
	              sum(decode(state,0,files)) wait_files,
	              sum(decode(state,0,bytes)) wait_bytes,
	              sum(decode(state,1,files)) ready_files,
	              sum(decode(state,1,bytes)) ready_bytes,
	              sum(decode(state,2,files)) xfer_files,
	              sum(decode(state,2,bytes)) xfer_bytes
		from t_status_task
		group by :timebin, :timewidth, from_node, to_node, priority) v
	    on (h.timebin = v.timebin and
	        h.from_node = v.from_node and
		h.to_node = v.to_node and
		h.priority = v.priority)
	    when matched then
	      update set
	        h.pend_files = v.pend_files, h.pend_bytes = v.pend_bytes,
	        h.wait_files = v.wait_files, h.wait_bytes = v.wait_bytes,
	        h.ready_files = v.ready_files, h.ready_bytes = v.ready_bytes,
	        h.xfer_files = v.xfer_files, h.xfer_bytes = v.xfer_bytes
	    when not matched then
	      insert (timebin, timewidth, from_node, to_node, priority,
	              pend_files, pend_bytes, wait_files, wait_bytes,
		      ready_files, ready_bytes, xfer_files, xfer_bytes)
	      values (v.timebin, v.timewidth, v.from_node, v.to_node, v.priority,
	              v.pend_files, v.pend_bytes, v.wait_files, v.wait_bytes,
		      v.ready_files, v.ready_bytes, v.xfer_files, v.xfer_bytes)},
	    ":timebin" => $timebin, ":timewidth" => $timewidth);

	# Routing statistics.
	&dbexec($dbh, qq{
	    merge into t_history_link_stats h using
	      (select :timebin timebin, :timewidth timewidth,
	      	      from_node, to_node, priority, files, bytes
		from t_status_path where is_valid = 1) v
	    on (h.timebin = v.timebin and
	        h.from_node = v.from_node and
		h.to_node = v.to_node and
		h.priority = v.priority)
	    when matched then
	      update set
	        h.confirm_files = v.files,
		h.confirm_bytes = v.bytes
	    when not matched then
	      insert (h.timebin, h.timewidth, h.from_node, h.to_node,
		      h.priority, h.confirm_files, h.confirm_bytes)
	      values (v.timebin, v.timewidth, v.from_node, v.to_node,
		      v.priority, v.files, v.bytes)},
	    ":timebin" => $timebin, ":timewidth" => $timewidth);

	# Now "close" the link statistics.  This ensures at least one
	# row of nulls for links which have previously had stats, and
	# makes the link parameter calculation below pick up correct
	# "empty" final state.
	&dbexec($dbh, qq{
	    insert into t_history_link_stats
	    (timebin, timewidth, from_node, to_node, priority)
	    select :timebin, :timewidth, from_node, to_node, priority
	    from (select from_node, to_node, priority, max(timebin) prevbin
	          from t_history_link_stats where timebin < :timebin
		  group by from_node, to_node, priority) h
	    where exists
		(select 1 from t_history_link_stats hh
		 where hh.from_node = h.from_node
		   and hh.to_node = h.to_node
		   and hh.priority = h.priority
		   and hh.timebin = h.prevbin
		   and hh.pend_bytes > 0)
	      and not exists
		(select 1 from t_history_link_stats hh
		 where hh.from_node = h.from_node
		   and hh.to_node = h.to_node
		   and hh.priority = h.priority
		   and hh.timebin > h.prevbin)},
	    ":timebin" => $timebin, ":timewidth" => $timewidth);

	# PART III: Node statistics.
	&dbexec($dbh, qq{
	    merge into t_history_dest h using
	      (select :timebin timebin, :timewidth timewidth, destination,
	              sum(files) files, sum(bytes) bytes
	       from t_status_block_dest
	       group by :timebin, :timewidth, destination) v
	    on (h.timebin = v.timebin and h.node = v.destination)
	    when matched then
	      update set h.dest_files = v.files, h.dest_bytes = v.bytes
	    when not matched then
	      insert (h.timebin, h.timewidth, h.node, h.dest_files, h.dest_bytes)
	      values (v.timebin, v.timewidth, v.destination, v.files, v.bytes)},
	    ":timebin" => $timebin, ":timewidth" => $timewidth);

	&dbexec($dbh, qq{
	    merge into t_history_dest h using
	      (select :timebin timebin, :timewidth timewidth, node, files, bytes
	       from t_status_file) v
	    on (h.timebin = v.timebin and h.node = v.node)
	    when matched then
	      update set h.src_files = v.files, h.src_bytes = v.bytes
	    when not matched then
	      insert (h.timebin, h.timewidth, h.node, h.src_files, h.src_bytes)
	      values (v.timebin, v.timewidth, v.node, v.files, v.bytes)},
	    ":timebin" => $timebin, ":timewidth" => $timewidth);

	&dbexec($dbh, qq{
	    merge into t_history_dest h using
	      (select :timebin timebin, :timewidth timewidth, node,
	              sum(files) files, sum(bytes) bytes
	       from t_status_replica
	       group by :timebin, :timewidth, node) v
	    on (h.timebin = v.timebin and h.node = v.node)
	    when matched then
	      update set
	        h.node_files = v.files, h.node_bytes = v.bytes
	    when not matched then
	      insert (h.timebin, h.timewidth, h.node, h.node_files, h.node_bytes)
	      values (v.timebin, v.timewidth, v.node, v.files, v.bytes)},
	    ":timebin" => $timebin, ":timewidth" => $timewidth);

	&dbexec($dbh, qq{
	    merge into t_history_dest h
	    using
	      (select :timebin timebin, :timewidth timewidth, destination,
	              sum(files) request_files, sum(bytes) request_bytes,
		      sum(decode(state,1,files)) idle_files,
	              sum(decode(state,1,bytes)) idle_bytes
		from t_status_request
		group by :timebin, :timewidth, destination) v
	    on (h.timebin = v.timebin and h.node = v.destination)
	    when matched then
	      update set
	        h.request_files = v.request_files, h.request_bytes = v.request_bytes,
	        h.idle_files = v.idle_files, h.idle_bytes = v.idle_bytes
	    when not matched then
	      insert (h.timebin, h.timewidth, h.node,
	              h.request_files, h.request_bytes,
	              h.idle_files, h.idle_bytes)
	      values (v.timebin, v.timewidth, v.destination,
	      	      v.request_files, v.request_bytes,
	      	      v.idle_files, v.idle_bytes)},
	    ":timebin" => $timebin, ":timewidth" => $timewidth);

	# Part V: Update link parameters.
	&dbexec($dbh, qq{delete from t_adm_link_param});
        foreach my $span (3600, 12*3600, 2*86400)
	{
	    &dbexec($dbh, qq{
                merge into t_adm_link_param p using
		  (select
                       from_node, to_node,
                       nvl(sum(pend_bytes) keep (dense_rank last order by timebin asc),0) pend_bytes,
                       sum(done_bytes) done_bytes,
                       sum(try_bytes) try_bytes,
                       count(distinct case
                             when timewidth=300
                               and (pend_bytes > 0 or done_bytes > 0 or try_bytes > 0)
                             then timebin end)*300
                       + count(distinct case
                               when timewidth=3600
                                 and (pend_bytes > 0 or done_bytes > 0 or try_bytes > 0)
                               then timebin end)*3600 time_span
                   from (select nvl(hs.from_node,he.from_node) from_node,
                                nvl(hs.to_node,he.to_node) to_node,
                                nvl(hs.timebin,he.timebin) timebin,
                                nvl(hs.timewidth,he.timewidth) timewidth,
                                hs.pend_bytes, he.done_bytes, he.try_bytes
                         from t_history_link_stats hs
                           full join t_history_link_events he
                             on he.timebin = hs.timebin
                             and he.from_node = hs.from_node
                             and he.to_node = hs.to_node
                             and he.priority = hs.priority
                         where hs.timebin > :period
                           and he.timebin > :period)
                   group by from_node, to_node) n
                on (p.from_node = n.from_node and p.to_node = n.to_node)
		when matched then
		  update set p.pend_bytes = n.pend_bytes,
                             p.done_bytes = n.done_bytes,
                             p.try_bytes = n.try_bytes,
                             p.time_span = n.time_span,
			     p.time_update = :now
                  where (p.time_span is null or p.time_span = 0)
                     or (p.done_bytes is null or p.try_bytes is null)
                when not matched then
                  insert (p.from_node, p.to_node, p.pend_bytes, p.done_bytes,
			  p.try_bytes, p.time_span, p.time_update)
		  values (n.from_node, n.to_node, n.pend_bytes, n.done_bytes,
			  n.try_bytes, n.time_span, :now)},
	        ":period" => $timebin - $span, ":now" => $timebin);
	}

	&dbexec($dbh, qq{
	    merge into t_adm_link_param p using
	      (select from_node, to_node from t_adm_link) n
	    on (p.from_node = n.from_node and p.to_node = n.to_node)
	    when not matched then
	      insert (from_node, to_node, time_update)
	      values (n.from_node, n.to_node, :now)},
	    ":now" => $timebin);

	&dbexec($dbh, qq{
	    update (select
	    	      pend_bytes, xfer_rate, xfer_latency,
		      case
		        when nvl(pend_bytes,0) = 0 then null
		        when time_span > 0 then
		          nvl(done_bytes,0)/time_span
			else 0
		      end rate
	            from t_adm_link_param
		    where time_span is not null and time_span != 0)
	    set xfer_rate = rate,
	        xfer_latency =
		   case
		     when pend_bytes = 0
		       then 0
		     when rate > 0
		       then least(pend_bytes/rate,7*86400)
		     else 7*86400
		   end});

        &dbexec($dbh, qq{
	    update t_history_link_stats h
	    set (param_rate, param_latency) =
	      (select xfer_rate, xfer_latency
	       from t_adm_link_param p
	       where p.from_node = h.from_node
	         and p.to_node = h.to_node)
	    where timebin = :timebin},
 	    ":timebin" => $timebin);

	$dbh->commit();

	# Part VI: Compact old time series data to be in per-hour instead
	# of per-5-minute bins.  We do this only rarely to avoid loading
	# the database servers excessively.  We read the old data stats
	# in memory, merge, and write back.  This is mainly because some
	# of the data is accumulated, some not, and sql makes it awkward
	# to handle both.
	return if ($timebin < $$self{NEXT_COMPACT});
        my $limit = int($timebin/86400)*86400 - 86400;
	$self->compactLinkData($dbh, $limit, "events");
	$self->compactLinkData($dbh, $limit, "stats");
	$self->compactDestData($dbh, $limit);
	$dbh->commit();
	$$self{NEXT_COMPACT} = $timebin + 2*86400; # Every two days
    };
    do { chomp ($@); $self->Alert ("database error: $@");
	 eval { $dbh->rollback() } if $dbh; } if $@;

    # Disconnect from the database
    $self->disconnectAgent();
}

sub compactUpdate
{
    my ($self, $dbh, $limit, $table, $stats, $primary) = @_;
    &dbexec($dbh, qq{
	delete from $table
	where timebin < :old and timewidth = 300},
	":old" => $limit);

    my $i = undef;
    foreach my $data (values %$stats)
    {
	if (! defined $i)
	{
	    my @keys = keys %$data;
	    my %primarykeys = map { $_ => 1 } @$primary;
	    my @valuekeys = grep(! $primarykeys{$_}, @keys);
	    my $sql = "merge into $table t using "
		      . "(select "
		      . join(",", map { ":$_ $_" } @keys)
		      . " from dual) e on ("
		      . join(" and ", map { "t.$_ = e.$_" } @$primary)
		      . ") when matched then update set "
		      . join(", ", map { "t.$_ = nvl(t.$_, 0) + nvl(e.$_, 0)" } @valuekeys)
		      . " when not matched then insert ("
		      . join(",", @keys) . ") values ("
		      . join(",", map { "e.$_" } @keys) . ")";
	    $i = &dbprep($dbh, $sql);
	}
	&dbbindexec($i, map { (":$_" => $$data{$_}) } keys %$data);
    }
}

sub compactLinkData
{
    my ($self, $dbh, $limit, $suffix) = @_;
    my %stats;
    my @primary = ('TIMEBIN', 'TO_NODE', 'FROM_NODE', 'PRIORITY');
    my $q = &dbexec($dbh, qq{
	select * from t_history_link_$suffix
	where timebin < :old and timewidth = 300
	order by timebin asc, from_node, to_node, priority},
    	":old" => $limit);
    while (my $row = $q->fetchrow_hashref())
    {
	my $bin = int($$row{TIMEBIN}/3600)*3600;
	my $key = "$bin $$row{FROM_NODE} $$row{TO_NODE} $$row{PRIORITY}";
	if (! exists $stats{$key})
	{
	    $stats{$key} = $row;
	    $$row{TIMETOT} = $$row{TIMEWIDTH};
	}
	else
	{
	    my $s = $stats{$key};
	    $$s{$_} = ($$row{$_} || 0)
		for grep(/^(PEND|WAIT|COOL|READY|XFER|CONFIRM)_/, keys %$row);
	    $$s{$_} = ($$s{$_} || 0) + ($$row{$_} || 0)
		for grep(/^(AVAIL|DONE|TRY|FAIL|EXPIRE)_/, keys %$row);
	    $$s{$_} = ($$s{$_} || 0) + ($$row{$_} || 0)*$$row{TIMEWIDTH}
		for grep(/^(PARAM)_/, keys %$row);
	    $$s{TIMETOT} += $$row{TIMEWIDTH};
	}
	$$row{TIMEBIN} = $bin;
	$$row{TIMEWIDTH} = 3600;
    }

    foreach my $s (values %stats)
    {
	if ($suffix ne 'events')
	{
	    if ($$s{TIMETOT})
	    {
	        $$s{PARAM_RATE} = ($$s{PARAM_RATE} || 0) / $$s{TIMETOT};
	        $$s{PARAM_LATENCY} = ($$s{PARAM_LATENCY} || 0) / $$s{TIMETOT};
	    }
	    else
	    {
	        $$s{PARAM_RATE} = 0;
	        $$s{PARAM_LATENCY} = 0;
            }
	}
	delete $$s{TIMETOT};
    }

    $self->compactUpdate ($dbh, $limit, "t_history_link_$suffix",
			  \%stats, \@primary);
}

sub compactDestData
{
    my ($self, $dbh, $limit) = @_;
    my %stats;
    my @primary = ('TIMEBIN', 'NODE');
    my $q = &dbexec($dbh, qq{
	select * from t_history_dest
	where timebin < :old and timewidth = 300
	order by timebin asc, node},
    	":old" => $limit);
    while (my $row = $q->fetchrow_hashref())
    {
	my $bin = int($$row{TIMEBIN}/3600)*3600;
	my $key = "$bin $$row{NODE}";
	$$row{TIMEBIN} = $bin;
	$$row{TIMEWIDTH} = 3600;
	if (! exists $stats{$key})
	{
	    $stats{$key} = $row;
	}
	else
	{
	    my $s = $stats{$key};
	    $$s{$_} = ($$row{$_} || 0)
		for grep(/^(DEST|NODE|REQUEST|IDLE)_/, keys %$row);
	}
    }

    $self->compactUpdate ($dbh, $limit, "t_history_dest",
			  \%stats, \@primary);
}

1;
