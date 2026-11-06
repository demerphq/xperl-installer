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
# Repairs, when configured, run sequentially after the parallel pass.

my $JSON = JSON::PP->new->canonical;

# Options:
#   fetcher, builder   required; the builder's repair settings are used only
#                      in the sequential repair pass
#   jobs               worker count (at least 1)
#   prefer             optional code reference, as for XPerl::Installer::Deps
#   progress           optional code reference called with each finished node
sub new ($class, %args) {
    die "fetcher and builder are required\n"
        unless $args{fetcher} && $args{builder};
    my $jobs = $args{jobs} // 1;
    die "jobs must be a positive integer\n" unless $jobs =~ /\A[1-9]\d*\z/;
    my $builder = $args{builder};
    $builder->{install_lock} //= File::Spec->catfile($builder->{prefix},
                                                     '.xperl-install.lock');
    return bless {
        fetcher => $args{fetcher},
        builder => $builder,
        jobs => $jobs,
        prefer => $args{prefer},
        progress => $args{progress},
        needed => CPAN::Meta::Requirements->new,
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

    while (1) {
        $self->_schedule;
        last unless $self->_repair_pass;
    }
    return {
        requests => \@requests,
        nodes => [map { $self->_public($_) }
                  sort { $a->{path} cmp $b->{path} } values %{$self->{nodes}}],
    };
}

sub node ($self, $path) { return $self->{nodes}{$path} }

# ---------------------------------------------------------------- graph

sub _add_module ($self, $module, $constraint, $from) {
    $self->{needed}->add_string_requirement($module, $constraint);
    return if $self->_satisfied($module);
    my $path = $self->{modules}{$module};
    if (!defined $path) {
        my $release = $self->{prefer} ? $self->{prefer}->($module) : undef;
        if (!$release) {
            $release = $self->{fetcher}->fetch($module);
            die "CPAN index version $release->{version} does not satisfy $module $constraint\n"
                unless $self->{needed}->accepts_module($module, $release->{version});
        }
        $release->{module} //= $module;
        $path = $self->_add_release($release);
        $self->{modules}{$module} = $path;
    }
    if ($from) {
        $from->{prereqs}{$path} = 1;
        $self->{nodes}{$path}{dependents}{$from->{path}} = 1;
    }
    return $path;
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
            my $meta = eval { XPerl::Installer::Deps::_metadata($release->{archive}) };
            if ($@) {
                $self->_fail($node, "invalid CPAN metadata for $release->{cpan_path}: $@");
                next;
            }
            if ($meta) {
                $release->{distribution} //= $meta->name;
                $release->{distribution_version} //= $meta->version;
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
    $self->{progress}->($self->_public($node)) if $self->{progress};
}

# ------------------------------------------------------------ scheduling

sub _schedule ($self) {
    my %running;    # pid => [node, result file]
    while (1) {
        $self->_block_descendants;
        for my $node ($self->_ready) {
            last if keys(%running) >= $self->{jobs};
            $node->{state} = 'running';
            ++$node->{attempts};
            my ($fh, $result) = tempfile('result-XXXXXXXX',
                DIR => $self->{builder}{workdir}, UNLINK => 0);
            close $fh;
            my $pid = fork // die "cannot fork: $!\n";
            if (!$pid) {
                $self->_worker($node, $result);
                POSIX::_exit(0);
            }
            $running{$pid} = [$node, $result];
        }
        last unless %running;
        my $pid = waitpid(-1, 0);
        next unless $pid > 0 && $running{$pid};
        my ($node, $result) = @{delete $running{$pid}};
        my $outcome = eval {
            open my $in, '<', $result or die "no result: $!\n";
            $JSON->decode(do { local $/; <$in> });
        } // { status => 'failed', reason => "worker ended without a result (wait status $?)" };
        unlink $result;
        $self->_record($node, $outcome);
    }
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
    $self->_fail($node, $outcome->{reason} // 'installation failed', $outcome->{receipt});
}

# Failed builds (not dependency failures) are retried one at a time with the
# configured repair command. A success releases blocked descendants for
# another parallel pass. Returns true when that pass is needed.
sub _repair_pass ($self) {
    my $builder = $self->{builder};
    return 0 unless $builder->{repair_command} && $builder->{repair_attempts};
    my $progress = 0;
    for my $node (sort { $a->{path} cmp $b->{path} } values %{$self->{nodes}}) {
        next unless $node->{state} eq 'failed' && $node->{receipt}
            && !$node->{repair_tried}++;
        my $record = eval { $builder->install($node->{release}) } or next;
        @{$node}{qw(state receipt reason)} = ('installed', $record->{receipt}, undef);
        $self->{progress}->($self->_public($node)) if $self->{progress};
        $progress = 1;
    }
    return 0 unless $progress;
    for my $node (values %{$self->{nodes}}) {
        @{$node}{qw(state reason root)} = ('pending', undef, undef)
            if $node->{state} eq 'blocked';
    }
    return 1;
}

# ---------------------------------------------------------- availability

sub _satisfied ($self, $module) {
    return $self->_available($module,
        $self->{needed}->requirements_for_module($module) // '0');
}

sub _available ($self, $module, $range) {
    my $prefix = $self->{builder}{prefix};
    my $site = File::Spec->catdir($prefix, 'lib', 'perl5');
    my @inc = ($site, File::Spec->catdir($site, $Config{archname}), @INC);
    my $metadata = Module::Metadata->new_from_module($module, inc => \@inc)
        or return 0;
    my $requirements = CPAN::Meta::Requirements->new;
    $requirements->add_string_requirement($module, $range // '0');
    return $requirements->accepts_module($module, $metadata->version // '0');
}

sub _public ($self, $node) {
    my %public = (
        cpan_path => $node->{path},
        status => $node->{state},
        (map { defined $node->{$_} ? ($_ => $node->{$_}) : () }
         qw(reason receipt)),
        prerequisites => [sort keys %{$node->{prereqs}}],
    );
    $public{resumed} = JSON::PP::true if $node->{resumed};
    $public{deferred_attempts} = $node->{deferred} if $node->{deferred};
    return \%public;
}

1;
