package XPerl::Installer::Parallel;

use strict;
use warnings;
use feature 'signatures';
use Config;
use CPAN::Meta;
use CPAN::Meta::Requirements;
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP;
use Module::Metadata;
use POSIX ();
use XPerl::Installer::Deps;

# Opt-in parallel installation. The release graph is resolved breadth-first
# from static metadata, then up to K forked workers build releases whose
# prerequisites are installed. A failure blocks only its descendants. When a
# release's configured metadata (MYMETA) names prerequisites the static
# metadata did not, its worker stops after configure; the scheduler adds the
# new releases to the graph and builds the release again from a clean copy.
# Failed releases enter a repair queue while independent builds continue.

my $JSON = JSON::PP->new->canonical;

# Options:
#   fetcher, builder   required; the builder supplies repair settings
#   jobs               build worker count (at least 1)
#   repair_jobs        repair worker count (at least 1)
#   prefer             optional code reference, as for XPerl::Installer::Deps
#   progress           optional code reference called with each finished node
sub new ($class, %args) {
    die "fetcher and builder are required\n"
        unless $args{fetcher} && $args{builder};
    my $jobs = $args{jobs} // 1;
    die "jobs must be a positive integer\n" unless $jobs =~ /\A[1-9]\d*\z/;
    my $repair_jobs = $args{repair_jobs} // 1;
    die "repair jobs must be a positive integer\n"
        unless $repair_jobs =~ /\A[1-9]\d*\z/;
    my $builder = $args{builder};
    $builder->{install_lock} //= File::Spec->catfile($builder->{prefix},
                                                     '.xperl-install.lock');
    return bless {
        fetcher => $args{fetcher},
        builder => $builder,
        jobs => $jobs,
        repair_jobs => $repair_jobs,
        prefer => $args{prefer},
        progress => $args{progress},
        nodes => {},        # cpan_path => node
        modules => {},      # module => cpan_path of the release providing it
        installed => {},    # cpan_path => receipt, from earlier runs
    }, $class;
}

sub mark_installed ($self, $cpan_path, $receipt) {
    $self->{installed}{$cpan_path} = $receipt;
    return;
}

# Requests are { module => NAME } (resolved like an ordinary install) or
# { release => FETCHED_RELEASE } (built even when the module is already
# available). Returns the requests with their node paths and every node.
sub run ($self, @requests) {
    for my $request (@requests) {
        my $path = eval {
            $request->{release}
                ? $self->_add_release($request->{release}, force => 1)
                : $self->_add_module($request->{module}, '0', undef);
        };
        if (!defined $path && $@) {
            chomp(my $error = $@);
            $request->{error} = $error;
            next;
        }
        $request->{node} = $path;    # undef: already satisfied
    }
    $self->_expand;
    $self->_mark_cycles;

    $self->_schedule;
    return {
        requests => \@requests,
        nodes => [map { $self->_public($_) }
                  sort { $a->{path} cmp $b->{path} } values %{$self->{nodes}}],
    };
}

sub node ($self, $path) { return $self->{nodes}{$path} }

# ---------------------------------------------------------------- graph

# Requirements belong to the dependent that states them: one dependent's
# constraint never changes what satisfies another. A module maps to one
# release; every dependent's range is checked against the version that
# release provides, when known now, and again against the installed version
# before the dependent is built.
sub _add_module ($self, $module, $range, $from) {
    return if $self->_available($module, $range);
    my $path = $self->{modules}{$module};
    if (!defined $path) {
        my $release = $self->{prefer} ? $self->{prefer}->($module) : undef;
        my $index = eval { $self->{fetcher}->resolve($module) };
        if (!$release) {
            die "CPAN module not found: $module\n" unless $index;
            # A rejected index version cannot fix this requirement. Do not
            # download its archive or leave an orphan node in the graph.
            my $version = $index->{version};
            die "CPAN index version $version does not satisfy $module $range\n"
                if defined $version && $version ne 'undef'
                    && !_accepts($module, $range, $version);
            $release = $self->{fetcher}->fetch($module);
        }
        $release->{module} //= $module;
        $path = $self->_add_release($release);
        $self->{modules}{$module} = $path;
        $self->{nodes}{$path}{provides}{$module} //= $index->{version}
            if $index && $index->{cpan_path} eq $path
                && defined $index->{version} && $index->{version} ne 'undef';
    }
    my $node = $self->{nodes}{$path};
    my $provided = $node->{provides}{$module};
    die "$module $provided from " . _name($node) . " does not satisfy $module $range\n"
        if defined $provided && !_accepts($module, $range, $provided);
    if ($from) {
        $from->{prereqs}{$path} = 1;
        $from->{needs}{$module} = _merge($from->{needs}{$module}, $module, $range);
        $node->{dependents}{$from->{path}} = 1;
    }
    return $path;
}

sub _accepts ($module, $range, $version) {
    my $requirements = CPAN::Meta::Requirements->new;
    $requirements->add_string_requirement($module, $range // '0');
    return $requirements->accepts_module($module, $version);
}

sub _merge ($existing, $module, $range) {
    my $requirements = CPAN::Meta::Requirements->new;
    $requirements->add_string_requirement($module, $existing) if defined $existing;
    $requirements->add_string_requirement($module, $range // '0');
    return $requirements->requirements_for_module($module);
}

sub _add_release ($self, $release, %options) {
    my $path = $release->{cpan_path};
    my $node = $self->{nodes}{$path} //= {
        path => $path, release => $release, prereqs => {}, dependents => {},
        state => 'new', attempts => 0,
    };
    $node->{force} = 1 if $options{force};
    if (my $receipt = $self->{installed}{$path}) {
        @{$node}{qw(state receipt resumed)} = ('installed', $receipt, 1);
    }
    return $path;
}

# Breadth-first: each new node's static prerequisites are resolved before
# any node is built.
sub _expand ($self) {
    while (my @new = sort { $a->{path} cmp $b->{path} }
                     grep { $_->{state} eq 'new' } values %{$self->{nodes}}) {
        for my $node (@new) {
            $node->{state} = 'pending';
            my $release = $node->{release};
            my $meta = eval { $self->{builder}->planned_metadata($release) };
            if ($@) {
                $self->_fail($node, "invalid CPAN metadata for $release->{cpan_path}: $@");
                next;
            }
            if ($meta) {
                if (!defined $release->{distribution}) {
                    ($release->{distribution}, $release->{distribution_version}) =
                        XPerl::Installer::Deps::_distribution_identity($meta, $release->{cpan_path});
                }
                my $provides = $meta->provides // {};
                $node->{declared}{$_} = $provides->{$_}
                    for grep { ($provides->{$_}{file} // '') =~ m{\Alib/} } keys %$provides;
                $node->{provides}{$_} //= $provides->{$_}{version}
                    for grep { defined $provides->{$_}{version} } keys %$provides;
                my $structure = $meta->as_struct;
                $release->{x_use_unsafe_inc} = $structure->{x_use_unsafe_inc} ? 1 : 0
                    if exists $structure->{x_use_unsafe_inc};
                $self->_add_requirements($node, $meta);
            }
            else {
                ($release->{distribution}, $release->{distribution_version}) =
                    XPerl::Installer::Deps::_identity_from_path($release->{cpan_path});
            }
        }
    }
}

sub _add_requirements ($self, $node, $meta) {
    my $required = $meta->effective_prereqs->merged_requirements(
        [qw(configure build test runtime)], ['requires']);
    for my $module (sort $required->required_modules) {
        my $range = $required->requirements_for_module($module);
        if ($module eq 'perl') {
            $self->_fail($node, "XPerl $^V does not satisfy perl $range")
                unless $required->accepts_module('perl', $^V);
            next;
        }
        $node->{static}{$module} = 1;
        eval { $self->_add_module($module, $range, $node); 1 } or do {
            chomp(my $error = $@);
            $self->_fail($node, "cannot resolve prerequisite $module: $error");
        };
    }
}

sub _mark_cycles ($self) {
    my (%colour, @stack);
    my $visit;
    $visit = sub ($node) {
        $colour{$node->{path}} = 'grey';
        push @stack, $node;
        for my $path (sort keys %{$node->{prereqs}}) {
            my $next = $self->{nodes}{$path};
            my $seen = $colour{$path} // 'white';
            if ($seen eq 'grey') {
                my ($start) = grep { $stack[$_]{path} eq $path } 0 .. $#stack;
                my @cycle = (@stack[$start .. $#stack], $next);
                my $text = join ' -> ', map { _name($_) } @cycle;
                $self->_fail($_, "dependency cycle: $text")
                    for @stack[$start .. $#stack];
            }
            elsif ($seen eq 'white') {
                $visit->($next);
            }
        }
        pop @stack;
        $colour{$node->{path}} = 'black';
    };
    for my $node (sort { $a->{path} cmp $b->{path} } values %{$self->{nodes}}) {
        $visit->($node) unless $colour{$node->{path}};
    }
    undef $visit;
}

sub _name ($node) {
    my $release = $node->{release};
    return $release->{distribution}
        ? "$release->{distribution}-$release->{distribution_version}"
        : $node->{path};
}

sub _fail ($self, $node, $reason, $receipt = undef) {
    return if $node->{state} eq 'failed';
    $node->{state} = 'failed';
    $node->{reason} = (split /\n/, $reason)[0];
    $node->{receipt} = $receipt if defined $receipt;
    if (defined $receipt && -f $receipt) {
        my $record = eval {
            open my $input, '<', $receipt or die $!;
            $JSON->decode(do { local $/; <$input> });
        };
        $node->{user_action} = $record->{user_action}
            if ref($record) eq 'HASH' && ref($record->{user_action}) eq 'HASH';
    }
    $self->{progress}->($self->_public($node)) if $self->{progress};
}

# ------------------------------------------------------------ scheduling

sub _schedule ($self) {
    my %running;
    my $repair = { calls => 0, reserved => 0 };

    while (1) {
        # A failed repair is final. While repair is pending, its dependents
        # remain pending too, so they can run as soon as it succeeds.
        $self->_block_descendants;

        $self->_start_builds(\%running);
        $self->_start_repairs(\%running, $repair);

        unless (%running) {
            $self->_block_descendants;
            last;
        }

        $self->_finish_worker(\%running, $repair);
    }
}

# Build slots are separate from repair slots. Filling one pool never waits
# for space in the other.
sub _start_builds ($self, $running) {
    my $active = grep { $_->{kind} eq 'build' } values %$running;

    for my $node ($self->_ready) {
        last if $active >= $self->{jobs};
        next unless $self->_needs_met($node);

        $node->{state} = 'running';
        ++$node->{attempts};
        my ($pid, $worker) = $self->_start_worker('build', $node);
        $running->{$pid} = $worker;
        ++$active;
    }
}

# Reserve the maximum agent calls a repair may make. When it finishes, return
# any unused calls to the run's budget before starting another repair.
sub _start_repairs ($self, $running, $repair) {
    my $active = grep { $_->{kind} eq 'repair' } values %$running;

    for my $node (sort { $a->{path} cmp $b->{path} }
                  grep { $_->{state} eq 'repair_pending' }
                  values %{$self->{nodes}}) {
        last if $active >= $self->{repair_jobs};

        my $budget = $self->{builder}{repair_attempts};
        if (defined $self->{builder}{repair_limit}) {
            my $remaining = $self->{builder}{repair_limit}
                - $repair->{calls} - $repair->{reserved};
            if ($remaining <= 0) {
                # An active repair may return unused calls. Wait for it
                # before treating another failure as beyond the run's cap.
                last if $active;
                $self->_fail($node, "$node->{reason}; repair limit reached",
                             $node->{receipt});
                next;
            }
            $budget = $remaining if $remaining < $budget;
        }
        $node->{state} = 'repairing';
        my ($pid, $worker) = $self->_start_worker('repair', $node, $budget);
        $running->{$pid} = $worker;
        $repair->{reserved} += $budget;
        ++$active;
    }
}

sub _start_worker ($self, $kind, $node, $budget = 0) {
    my ($fh, $result) = tempfile('result-XXXXXXXX',
        DIR => $self->{builder}{workdir}, UNLINK => 0);
    close $fh;

    my $pid = fork // die "cannot fork $kind worker: $!\n";
    unless ($pid) {
        if ($kind eq 'repair') {
            $self->_repair_worker($node, $result, $budget);
        }
        else {
            $self->_worker($node, $result);
        }
        POSIX::_exit(0);
    }

    return ($pid, { kind => $kind, node => $node,
                    result => $result, budget => $budget });
}

sub _finish_worker ($self, $running, $repair) {
    my $pid = waitpid(-1, 0);
    return unless $pid > 0 && $running->{$pid};

    my $worker = delete $running->{$pid};
    my $outcome = eval {
        open my $input, '<', $worker->{result}
            or die "cannot read worker result: $!\n";
        $JSON->decode(do { local $/; <$input> });
    } // { status => 'failed',
           reason => "worker ended without a result (wait status $?)" };
    unlink $worker->{result};

    if ($worker->{kind} eq 'repair') {
        $repair->{reserved} -= $worker->{budget};
        $repair->{calls} += $outcome->{repair_calls} // $worker->{budget};
        $self->_record_repair($worker->{node}, $outcome);
    }
    else {
        $self->_record($worker->{node}, $outcome);
    }
}

# A dependent is built only if every installed prerequisite satisfies the
# version range it stated.
sub _needs_met ($self, $node) {
    for my $module (sort keys %{$node->{needs} // {}}) {
        my $range = $node->{needs}{$module};
        next if $self->_available($module, $range);
        my $path = $self->{modules}{$module};
        my $installed = $path ? _name($self->{nodes}{$path}) : 'the installed prerequisite';
        $self->_fail($node, "$installed does not provide $module $range");
        return 0;
    }
    return 1;
}

sub _ready ($self) {
    return sort { $a->{path} cmp $b->{path} } grep {
        my $node = $_;
        $node->{state} eq 'pending'
            && !grep { $self->{nodes}{$_}{state} ne 'installed' }
                    keys %{$node->{prereqs}}
    } values %{$self->{nodes}};
}

# A pending node with a failed or blocked prerequisite is blocked, and names
# the release whose own failure is the cause.
sub _block_descendants ($self) {
    my $changed = 1;
    while ($changed) {
        $changed = 0;
        for my $node (sort { $a->{path} cmp $b->{path} } values %{$self->{nodes}}) {
            next unless $node->{state} eq 'pending';
            my ($cause) = map { $self->{nodes}{$_} }
                          grep { $self->{nodes}{$_}{state} =~ /\A(?:failed|blocked)\z/ }
                          sort keys %{$node->{prereqs}};
            next unless $cause;
            my $root = $cause->{state} eq 'failed' ? $cause : $cause->{root};
            $node->{state} = 'blocked';
            $node->{root} = $root;
            $node->{reason} = "dependency failed: $root->{path}: $root->{reason}";
            $self->{progress}->($self->_public($node)) if $self->{progress};
            $changed = 1;
        }
    }
}

sub _worker ($self, $node, $result_path) {
    my $outcome = eval {
        my $builder = bless { %{$self->{builder}},
                              repair_command => undef, repair_attempts => 0 },
                            ref $self->{builder};
        my $record = $builder->install($node->{release},
            after_configure => sub ($source) {
                my @new = $self->_unknown_requirements($node, $source);
                die { defer => \@new } if @new;
            });
        { status => 'installed', receipt => $record->{receipt} };
    };
    if (!$outcome) {
        my $error = $@;
        if (ref($error) eq 'HASH' && $error->{defer}) {
            $outcome = { status => 'deferred', modules => $error->{defer},
                         attempt => $error->{receipt} };
        }
        else {
            my ($receipt) = "$error" =~ /^ receipt: (\S+)$/m;
            (my $reason = "$error") =~ s/\s*\n receipt: .*//s;
            $outcome = { status => 'failed', reason => (split /\n/, $reason)[0],
                         (defined $receipt ? (receipt => $receipt) : ()) };
        }
    }
    open my $out, '>', $result_path or POSIX::_exit(2);
    print {$out} $JSON->encode($outcome);
    close $out or POSIX::_exit(2);
}

sub _repair_worker ($self, $node, $result_path, $budget) {
    my $builder = bless { %{$self->{builder}}, repair_calls => 0,
        repair_attempts => $budget, repair_limit => $budget,
        ($self->{repair_jobs} > 1 ? (repair_lock => undef) : ()) },
        ref $self->{builder};
    my $record = eval { $builder->install($node->{release}) };
    my $error = $@;
    my $outcome;
    if ($record) {
        $outcome = { status => 'installed', receipt => $record->{receipt} };
    }
    elsif (ref($error) eq 'HASH' && $error->{defer}) {
        $outcome = { status => 'deferred', modules => $error->{defer},
                     attempt => $error->{receipt} };
    }
    else {
        my ($receipt) = "$error" =~ /^ receipt: (\S+)$/m;
        (my $reason = "$error") =~ s/\s*\n receipt: .*//s;
        $outcome = { status => 'failed', reason => (split /\n/, $reason)[0],
                     (defined $receipt ? (receipt => $receipt) : ()) };
    }
    $outcome->{repair_calls} = $builder->{repair_calls};
    open my $out, '>', $result_path or POSIX::_exit(2);
    print {$out} $JSON->encode($outcome);
    close $out or POSIX::_exit(2);
}

# Configured prerequisites (MYMETA) that the static metadata did not name
# and that are not available yet.
sub _unknown_requirements ($self, $node, $source) {
    for my $name (qw(MYMETA.json MYMETA.yml)) {
        my $path = File::Spec->catfile($source, $name);
        next unless -f $path;
        my $meta = CPAN::Meta->load_file($path, { lazy_validation => 1 });
        my $required = $meta->effective_prereqs->merged_requirements(
            [qw(configure build test runtime)], ['requires']);
        my @new;
        for my $module (sort $required->required_modules) {
            next if $module eq 'perl';
            next if $self->_available($module,
                $required->requirements_for_module($module));
            push @new, { module => $module,
                         range => $required->requirements_for_module($module) };
        }
        return @new;
    }
    return;
}

sub _record ($self, $node, $outcome) {
    my $status = $outcome->{status} // 'failed';
    if ($status eq 'installed') {
        $node->{state} = 'installed';
        $node->{receipt} = $outcome->{receipt};
        $self->{progress}->($self->_public($node)) if $self->{progress};
        return;
    }
    if ($status eq 'deferred') {
        push @{$node->{deferred}}, $outcome->{attempt};
        if ($node->{attempts} > 3) {
            $self->_fail($node, 'configure-time prerequisites still missing after '
                . "$node->{attempts} attempts");
            return;
        }
        for my $requirement (@{$outcome->{modules}}) {
            eval {
                $node->{static}{$requirement->{module}} = 1;
                $self->_add_module($requirement->{module}, $requirement->{range}, $node);
                1;
            } or do {
                chomp(my $error = $@);
                $self->_fail($node, "cannot resolve prerequisite $requirement->{module}: $error");
                return;
            };
        }
        $node->{state} = 'pending';
        $self->_expand;
        $self->_mark_cycles;
        return;
    }
    if ($self->{builder}{repair_command} && $self->{builder}{repair_attempts}
        && $outcome->{receipt}) {
        $node->{state} = 'repair_pending';
        $node->{reason} = $outcome->{reason} // 'installation failed';
        $node->{receipt} = $outcome->{receipt};
        $self->{progress}->($self->_public($node)) if $self->{progress};
        return;
    }
    $self->_fail($node, $outcome->{reason} // 'installation failed', $outcome->{receipt});
}

sub _record_repair ($self, $node, $outcome) {
    if (($outcome->{status} // '') eq 'deferred') {
        $self->_record($node, $outcome);
        return;
    }
    if (($outcome->{status} // '') eq 'installed') {
        @{$node}{qw(state receipt reason)} =
            ('installed', $outcome->{receipt}, undef);
        $self->{progress}->($self->_public($node)) if $self->{progress};
        return;
    }
    $self->_fail($node, $outcome->{reason} // 'repair failed',
                 $outcome->{receipt} // $node->{receipt});
}

# ---------------------------------------------------------- availability

sub _available ($self, $module, $range) {
    my ($site, $arch) = $self->{builder}->library_dirs;
    my @inc = ($site, $arch, @INC);
    my $version = XPerl::Installer::Deps::_installed_version($module, \@inc)
        // $self->_declared_version($module, $site, $arch);
    return 0 unless defined $version;
    return _accepts($module, $range, $version);
}

# A package declared in META provides inside another module's file has no
# file of its own, so Module::Metadata cannot find it. It counts as
# installed once the release declaring it is installed and the declaring
# file is in the prefix.
sub _declared_version ($self, $module, $site, $arch) {
    my $path = $self->{modules}{$module} // return;
    my $node = $self->{nodes}{$path};
    return unless $node && $node->{state} eq 'installed';
    my $entry = $node->{declared}{$module} or return;
    my ($file) = $entry->{file} =~ m{\Alib/(.+)\z} or return;
    my @parts = split m{/}, $file;
    return unless -f File::Spec->catfile($site, @parts)
        || -f File::Spec->catfile($arch, @parts);
    return $entry->{version} // '0';
}

sub _public ($self, $node) {
    my %public = (
        cpan_path => $node->{path},
        status => $node->{state},
        (map { defined $node->{$_} ? ($_ => $node->{$_}) : () }
         qw(reason receipt user_action)),
        prerequisites => [sort keys %{$node->{prereqs}}],
    );
    $public{resumed} = JSON::PP::true if $node->{resumed};
    $public{deferred_attempts} = $node->{deferred} if $node->{deferred};
    return \%public;
}

1;

=pod

=head1 NAME

XPerl::Installer::Parallel - schedule CPAN builds and repairs

=head1 DESCRIPTION

The scheduler resolves the dependency graph before building releases. It
starts a release when its prerequisites are installed and keeps independent
builds moving when another release fails.

With a configured repair command, a failed release enters the repair queue.
Its dependents wait while repair runs. A successful repair installs the
release and makes those dependents eligible in the same run. A final repair
failure blocks only its dependents.

=head1 WORKER LIMITS

C<jobs> controls the number of build workers. C<repair_jobs> controls the
number of repair workers. The two limits are independent. An explicit
C<repair_limit> caps calls for the whole run. The scheduler reserves each
worker's possible calls and returns unused calls when it finishes.

=cut
