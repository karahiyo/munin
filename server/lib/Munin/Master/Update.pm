package Munin::Master::Update;

use warnings;
use strict;

use Carp;
use Munin::Master::Config;
use Munin::Master::GroupRepository;
use Munin::Master::Logger;
use Munin::Master::UpdateWorker;
use Munin::Master::ProcessManager;
use Munin::Master::Utils;
use Time::HiRes;


my $config = Munin::Master::Config->instance();

sub new {
    my ($class) = @_;

    my %gah = $config->get_groups_and_hosts();

    return bless {
        STATS               => undef,
        old_service_configs => {},
        service_configs     => {},
        workers             => [],
        failed_workers      => {},
        group_repository    => Munin::Master::GroupRepository->new(\%gah),
        config_dump_file    => "$config->{dbdir}/datafile",
    }, $class;
}


sub run {
    my ($self) = @_;
    
    $self->_create_rundir_if_missing();

    $self->_do_with_lock_and_timing(sub {
        logger("Starting munin-update");

        $self->{workers} = $self->_create_workers();
        $self->_run_workers();
        $self->{old_service_configs} = $self->_read_old_service_configs();
        $self->_compare_and_act_on_config_changes();
        $self->_write_new_service_configs();
    });
}


sub _create_rundir_if_missing {
    my ($self) = @_;

    unless (-d $config->{rundir}) {
	mkdir $config->{rundir}, oct(700)
            or croak "Failed to create rundir: $!";
        
    }
}


sub _create_workers {
    my ($self) = @_;

    my @hosts = $self->{group_repository}->get_all_hosts();

    if (%{$config->{limit_hosts}}) {
        @hosts = grep { $config->{limit_hosts}{$_->{host_name}} } @hosts
    }

    @hosts = grep { $_->{update} } @hosts;

    return [ map { Munin::Master::UpdateWorker->new($_) } @hosts ];
}


sub _do_with_lock_and_timing {
    my ($self, $block) = @_;

    my $lock = "$config->{rundir}/munin-update.lock";
    munin_runlock($lock);

    my $update_time = Time::HiRes::time;
    if (!open ($self->{STATS}, '>', "$config->{dbdir}/munin-update.stats.tmp")) {
        logger("[WARNING] Unable to open $config->{dbdir}/munin-update.stats");
        # Use /dev/null instead - if the admin won't fix he won't care
        open($self->{STATS}, '>', "/dev/null") or die "Could not open STATS to /dev/null: $?";
    }

    my $retval = $block->();

    $update_time = sprintf("%.2f", (Time::HiRes::time - $update_time));
    print { $self->{STATS} } "UT|$update_time\n";
    close ($self->{STATS});
    $self->{STATS} = undef;
    rename ("$config->{dbdir}/munin-update.stats.tmp", "$config->{dbdir}/munin-update.stats");
    logger("Munin-update finished ($update_time sec)");

    munin_removelock($lock);

    return $retval;
}


sub _run_workers {
    my ($self) = @_;

    if ($config->{fork}) {
        my $pm = Munin::Master::ProcessManager
            ->new($self->_create_self_aware_worker_result_handler());
        $pm->add_workers(@{$self->{workers}});
        $pm->start_work();
    }
    else {
        for my $worker (@{$self->{workers}}) {
            my $res = $worker->do_work();
            $self->_handle_worker_result([$worker->{ID}, $res]);
        }
    }
}


sub _create_self_aware_worker_result_handler {
    my ($self) = @_;

    return sub { $self->_handle_worker_result(@_); };
}


sub _handle_worker_result {
    my ($self, $res) = @_;

    my ($worker_id, $time_used, $service_configs) 
        = ($res->[0], $res->[1]{time_used}, $res->[1]{service_configs});

    printf { $self->{STATS} } "UD|%s|%.2f\n", $worker_id, $time_used;

    $self->{service_configs}{$worker_id} = $service_configs;
}


sub _read_old_service_configs {
    my ($self) = @_;

    return {} unless -e $self->{config_dump_file};

    my %service_configs = ();

    open my $dump, '<', $self->{config_dump_file}
        or croak "Fatal error: Could not open '$self->{config_dump_file}' for reading: $!";

    while (my $line = <$dump>) {
        $line =~ /^([^:]+):([^ ]+) (.*)$/;
        my ($host, $value) = ($1, $3);
        my $t = $2;
        my ($service, @attribute) = split /\./, $t;

        #use Data::Dumper; warn Dumper([$host, $value, \@attribute]);
        

        $service_configs{$host} ||= {};
        $service_configs{$host}{$service} ||= {global => [], data_source => {}};

        if (@attribute == 2) {
            $service_configs{$host}{$service}{data_source}{$attribute[0]} ||= {};
            $service_configs{$host}{$service}{data_source}{$attribute[0]}{$attribute[1]}
                = $value;
        }
        else {
            push @{$service_configs{$host}{$service}{global}}, [@attribute, $value];
        }
    }

    close $dump
        or croak "Fatal error: Could not close '$self->{config_dump_file}': $!";

    use Data::Dumper; warn Dumper(\%service_configs);

    return \%service_configs;
    
}


sub _compare_and_act_on_config_changes {
    my ($self) = @_;
}


sub _write_new_service_configs {
    my ($self) = @_;

    my $lock_file = "$config->{rundir}/munin-datafile.lock";
    munin_runlock($lock_file);

    open my $dump, '>', $self->{config_dump_file}
        or croak "Fatal error: Could not open '$self->{config_dump_file}' for writing: $!";

    for my $host (keys %{$self->{service_configs}}) {
        for my $service (keys %{$self->{service_configs}{$host}}) {
            for my $attr (@{$self->{service_configs}{$host}{$service}{global}}) {
                print $dump "$host:$service.$attr->[0] $attr->[1]\n";
            }
            for my $data_source (keys %{$self->{service_configs}{$host}{$service}{data_source}}) {
                for my $attr (keys %{$self->{service_configs}{$host}{$service}{data_source}{$data_source}}) {
                    print $dump "$host:$service.$data_source.$attr $self->{service_configs}{$host}{$service}{data_source}{$data_source}{$attr}\n";
                }
            }
        }
    }

    close $dump
        or croak "Fatal error: Could not close '$self->{config_dump_file}': $!";

    munin_removelock($lock_file);
}


1;


__END__

=head1 NAME

Munin::Master::Update - Contacts Munin Nodes, gathers data from their
service data sources, and stores this information in RRD files.

=head1 SYNOPSIS

 my $update = Munin::Master::Update->new();
 $update->run();

=head1 METHODS

=over

=item B<new>

 my $update = Munin::Master::Update->new();

Constructor.

=item B<run>

 $update->run();

This is where all the work gets done.

=back
