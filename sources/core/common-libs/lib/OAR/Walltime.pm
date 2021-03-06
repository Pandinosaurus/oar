package OAR::Walltime;

use strict;
use warnings;
use DBI();
use OAR::IO;
use OAR::Conf;

sub get_conf($$$$) {
    my $conf = shift; #simple value or hash with value per queue
    my $queue = shift; #use undef is no queue
    my $walltime = shift; #use undef if no percentage expansion is wanted
    my $value = shift; #default value
    if (defined($conf)) { #if not, keep default value
        # See if the configuration line is a hash of per queue configurations 
        my $eval = eval($conf);
        if (ref($eval) eq "HASH") {
            if (defined($queue) and exists($eval->{$queue})) {
                $value = $eval->{$queue};
            } elsif (exists($eval->{_})) {
                $value = $eval->{_};
            }
        } else {
            # conf is a simple value, same for all queues
            $value = $conf;
        }
    }
    if (defined($walltime) and $value =~ /^(0\.\d+)$/) {
        $value = int($walltime * $1);
    }
    return $value;
}

sub get($$) {
    my $dbh = shift;
    my $jobid = shift;

    my $Walltime_change_enabled = uc(OAR::Conf::get_conf_with_default_param("WALLTIME_CHANGE_ENABLED","NO"));
    if ($Walltime_change_enabled ne "YES") {
        return (undef, "functionality is disabled");
    }
    my $job = OAR::IO::get_job($dbh,$jobid);
    if (not defined($job)) {
        return (undef, "unknown job");
    }
    my $walltime_change = OAR::IO::get_walltime_change_for_job($dbh, $jobid); # no lock here

    if ($job->{assigned_moldable_job} != 0) {
        my $moldable = OAR::IO::get_moldable_job($dbh, $job->{assigned_moldable_job});
        $walltime_change->{walltime} = $moldable->{moldable_walltime};
    } else {
        $walltime_change->{walltime} = 0;
    }

    if (not defined($walltime_change->{pending})) {
        $walltime_change->{pending} = 0;
    }
    if (not defined($walltime_change->{granted})) {
        $walltime_change->{granted} = 0;
    }
    if (not defined($walltime_change->{granted_with_force})) {
        $walltime_change->{granted_with_force} = 0;
    }
    if (not defined($walltime_change->{granted_with_delay_next_jobs})) {
        $walltime_change->{granted_with_delay_next_jobs} = 0;
    }

    OAR::Conf::init_conf($ENV{OARCONFFILE});
    my $Walltime_max_increase = get_conf(OAR::Conf::get_conf_with_default_param("WALLTIME_MAX_INCREASE",0), $job->{queue_name}, $walltime_change->{walltime} - $walltime_change->{granted}, 0);
    my $Walltime_min_for_change = get_conf(OAR::Conf::get_conf_with_default_param("WALLTIME_MIN_FOR_CHANGE",0), $job->{queue_name}, undef, 0);
    my $Walltime_allowed_users_to_force = get_conf(OAR::Conf::get_conf_with_default_param("WALLTIME_ALLOWED_USERS_TO_FORCE",""), $job->{queue_name}, undef, "");
    my $Walltime_allowed_users_to_delay_jobs = get_conf(OAR::Conf::get_conf_with_default_param("WALLTIME_ALLOWED_USERS_TO_DELAY_JOBS",""), $job->{queue_name}, undef, "");

    my $now = OAR::IO::get_date($dbh);
    my $suspended = OAR::IO::get_job_suspended_sum_duration($dbh, $jobid, $now);

    if ($job->{state} ne "Running" or $walltime_change->{walltime} < $Walltime_min_for_change) {
        $walltime_change->{possible} =  OAR::IO::duration_to_sql_signed(0);
    } elsif ($Walltime_max_increase == -1) {
        $walltime_change->{possible} = "UNLIMITED";
    } else {
        $walltime_change->{possible} = OAR::IO::duration_to_sql_signed($Walltime_max_increase);
    }
    if ($Walltime_allowed_users_to_force ne "*" and not grep(/^$job->{job_user}$/,split(/[,\s]+/,$Walltime_allowed_users_to_force))) {
        $walltime_change->{force} = "FORBIDDEN";
    } elsif (not defined($walltime_change->{force}) or $walltime_change->{pending} == 0) {
        $walltime_change->{force} = "NO";
    }
    if ($Walltime_allowed_users_to_delay_jobs ne "*" and not grep(/^$job->{job_user}$/,split(/[,\s]+/,$Walltime_allowed_users_to_delay_jobs))) {
        $walltime_change->{delay_next_jobs} = "FORBIDDEN";
    } elsif (not defined($walltime_change->{delay_next_jobs}) and $walltime_change->{pending} == 0) {
        $walltime_change->{delay_next_jobs} = "NO";
    }


    if ($walltime_change->{walltime} != 0) {
        $walltime_change->{walltime} = OAR::IO::duration_to_sql($walltime_change->{walltime});
        $walltime_change->{pending} = OAR::IO::duration_to_sql_signed($walltime_change->{pending});
        $walltime_change->{granted} = OAR::IO::duration_to_sql_signed($walltime_change->{granted});
        $walltime_change->{granted_with_force} = OAR::IO::duration_to_sql_signed($walltime_change->{granted_with_force});
        $walltime_change->{granted_with_delay_next_jobs} = OAR::IO::duration_to_sql_signed($walltime_change->{granted_with_delay_next_jobs});
    } else {
        # job is not running yet, walltime may not be known yet, in case of a moldable job
        delete $walltime_change->{walltime};
        delete $walltime_change->{pending};
        delete $walltime_change->{granted};
        delete $walltime_change->{granted_with_force};
        delete $walltime_change->{granted_with_delay_next_jobs};
    }
    return ($walltime_change, $job->{state});
}

sub request($$$$$$) {
    my $dbh = shift;
    my $jobid = shift;
    my $lusr = shift;
    my $new_walltime = shift;
    my $force = shift;
    my $delay_next_jobs = shift;
    my $job;
    my $moldable;
    my @result;

    my $Walltime_change_enabled = uc(OAR::Conf::get_conf_with_default_param("WALLTIME_CHANGE_ENABLED","NO"));
    if ($Walltime_change_enabled ne "YES") {
        return (5, 405, "not available", "functionality is disabled");
    }
    $job = OAR::IO::get_job($dbh, $jobid);

    if (not defined($job)) {
        return (4, 404, "not found", "could not find job $jobid");
    }

    # Job user must be lusr or root or oar
    if ($job->{job_user} ne $lusr and not grep(/^$lusr$/,('root','oar'))) { 
        return (3, 403, "forbidden", "job $jobid does not belong to you");
    }
    
    # Job must be running
    if ($job->{state} ne "Running") { 
        return (3, 403, "forbidden", "job $jobid is not running");
    }

    $moldable = OAR::IO::get_current_moldable_job($dbh, $job->{assigned_moldable_job});

    OAR::Conf::init_conf($ENV{OARCONFFILE});
    my $Remote_host = OAR::Conf::get_conf("SERVER_HOSTNAME");
    my $Remote_port = OAR::Conf::get_conf("SERVER_PORT");
    my $Walltime_max_increase = get_conf(OAR::Conf::get_conf_with_default_param("WALLTIME_MAX_INCREASE",0), $job->{queue_name}, $moldable->{moldable_walltime}, 0);
    my $Walltime_min_for_change = get_conf(OAR::Conf::get_conf_with_default_param("WALLTIME_MIN_FOR_CHANGE",0), $job->{queue_name}, undef, 0);
    my $Walltime_reduction_disallowed = get_conf(OAR::Conf::get_conf_with_default_param("WALLTIME_REDUCTION_DISALLOWED","NO"), $job->{queue_name}, undef, "NO");
    my $Walltime_allowed_users_to_force = get_conf(OAR::Conf::get_conf_with_default_param("WALLTIME_ALLOWED_USERS_TO_FORCE",""), $job->{queue_name}, undef, "");
    my $Walltime_allowed_users_to_delay_jobs = get_conf(OAR::Conf::get_conf_with_default_param("WALLTIME_ALLOWED_USERS_TO_DELAY_JOBS",""), $job->{queue_name}, undef, "");

    my $Walltime_min_for_change_hms = OAR::IO::duration_to_sql($Walltime_min_for_change);
    my $Walltime_max_increase_hms = OAR::IO::duration_to_sql($Walltime_max_increase);

    # Parse new walltime and convert it to the number of seconds to add/remove to the current walltime
    my ($sign,$hours,$min,$sec) = $new_walltime =~ /^([-+]?)(\d+)(?::(\d+)(?::(\d+))?)?$/;
    if (not defined($hours)) {
        return (1, 400, "bad request", "syntax error");
    }
    my $new_walltime_delta_seconds = OAR::IO::hms_to_duration($hours, defined($min)?$min:0, defined($sec)?$sec:0);
    if ($sign eq "-") {
        $new_walltime_delta_seconds = - $new_walltime_delta_seconds;
    } elsif ($sign ne "+") { # sign = ""
        $new_walltime_delta_seconds = $new_walltime_delta_seconds - $moldable->{moldable_walltime};
    }

    if ($new_walltime_delta_seconds == 0) {
        return (1, 400, "bad request", "walltime change is null");
    }

    if ($new_walltime_delta_seconds < 0 and uc($Walltime_reduction_disallowed) ne "NO") {
        return (1, 400, "bad request", "walltime reduction is not allowed");
    }

    # Is walltime change enabled ?
    if (not defined($lusr)) {
        return (1, 400, "bad request", "anonymous request is not allowed");
    }
    
    # If $force != YES then undef
    if (defined($force) and uc($force) ne "YES") {
        $force = undef;
    }
    # Can extra time delay next jobs ?
    if (defined($force) and $Walltime_allowed_users_to_force ne "*" and not grep(/^$lusr$/,('root','oar',split(/[,\s]+/,$Walltime_allowed_users_to_force)))) {
        return (3, 403, "forbidden", "walltime change for this job is not allowed to be forced");
    }
    
    # If $delay_next_jobs != YES then undef
    if (defined($delay_next_jobs) and uc($delay_next_jobs) ne "YES") {
        $delay_next_jobs = undef;
    }
    # Can extra time delay next jobs ?
    if (defined($delay_next_jobs) and $Walltime_allowed_users_to_delay_jobs ne "*" and not grep(/^$lusr$/,('root','oar',split(/[,\s]+/,$Walltime_allowed_users_to_delay_jobs)))) {
        return (3, 403, "forbidden", "walltime change for this job is not allowed to delay other jobs");
    }
    
    # Is job walltime big enough to allow extra time ?
    if ($moldable->{moldable_walltime} < $Walltime_min_for_change) {
        return (3, 403, "forbidden", "walltime change is not allowed for a job with walltime < $Walltime_min_for_change_hms");
    }
    
    my $now = OAR::IO::get_date($dbh);
    my $suspended = OAR::IO::get_job_suspended_sum_duration($dbh, $jobid, $now);

    # If job defines a deadline (-t deadline=...), enforce it
    my $jobtypes = OAR::IO::get_job_types_hash($dbh, $jobid);
    if (exists($jobtypes->{deadline})) {
        if (OAR::IO::sql_to_local($jobtypes->{deadline}) < $job->{start_time} + $moldable->{moldable_walltime} + $suspended + $new_walltime_delta_seconds) {
            return (3, 403, "forbidden", "the requested walltime change does not fit with the job deadline ($jobtypes->{deadline})");
        }
    }
    if (exists($jobtypes->{inner}) and $jobtypes->{inner} =~ /^\d+$/) {
        my $container_id = $jobtypes->{inner};
        my $container_job = OAR::IO::get_job($dbh, $container_id);
        if (not defined($container_job)) {
            return (3, 403, "forbidden", "could not find job container $container_id");
        }
        if ($container_job->{state} ne "Running") { 
            return (3, 403, "forbidden", "inner job container $container_id is not running");
        }
        my $container_moldable = OAR::IO::get_current_moldable_job($dbh, $container_job->{assigned_moldable_job});
        if ($container_job->{start_time} + $container_moldable->{moldable_walltime} + OAR::IO::get_job_suspended_sum_duration($dbh, $container_id, $now) < $job->{start_time} + $moldable->{moldable_walltime} + $suspended + $new_walltime_delta_seconds) {
            return (3, 403, "forbidden", "the requested walltime change does not fit in the job container $container_id");
        }
    }

    # For negative extratime, do not allow end time before now
    my $job_remaining_time = $job->{start_time} + $moldable->{moldable_walltime} + $suspended - $now;
    if ($job_remaining_time < - $new_walltime_delta_seconds) { 
        $new_walltime_delta_seconds = - $job_remaining_time;
    }

    OAR::IO::lock_table($dbh,['walltime_change']);
    my $current_walltime_change = OAR::IO::get_walltime_change_for_job($dbh, $job->{job_id}); # locked here
    if (defined($current_walltime_change)) { # Update a request
        if ($Walltime_max_increase != -1 and $current_walltime_change->{granted} + $new_walltime_delta_seconds > $Walltime_max_increase and not grep(/^$lusr$/,('root','oar'))) { 
            @result = (3, 403, "forbidden", "request cannot be updated because the walltime cannot increase by more than ".$Walltime_max_increase_hms);
        } else {
            OAR::IO::update_walltime_change_request(
                $dbh,
                $job->{job_id},
                $new_walltime_delta_seconds,
                ((defined($force) and $new_walltime_delta_seconds > 0)?'YES':'NO'),
                ((defined($delay_next_jobs) and $new_walltime_delta_seconds > 0)?'YES':'NO'),
                undef,
                undef,
                undef
                );
            @result = (0, 202, "accepted", "walltime change request updated for job ".$job->{job_id}.", it will be handled shortly");
        }
    } else { # New request
        if ($Walltime_max_increase != -1 and $new_walltime_delta_seconds > $Walltime_max_increase and not grep(/^$lusr$/,('root','oar'))) {
            @result = (3, 403, "forbidden", "request cannot be accepted because the walltime cannot increase by more than ".$Walltime_max_increase_hms);
        } else {
            OAR::IO::add_walltime_change_request(
                $dbh,
                $job->{job_id},
                $new_walltime_delta_seconds,
                ((defined($force) and $new_walltime_delta_seconds > 0)?'YES':'NO'),
                ((defined($delay_next_jobs) and $new_walltime_delta_seconds > 0)?'YES':'NO')
                );
            @result = (0, 202, "accepted", "walltime change request accepted for job ".$job->{job_id}.", it will be handled shortly");
        }
    }
    OAR::IO::unlock_table($dbh);

    if ($result[0] == 0) {
        OAR::Tools::notify_tcp_socket($Remote_host,$Remote_port,"Walltime");
    }
    return @result;
}

1;
