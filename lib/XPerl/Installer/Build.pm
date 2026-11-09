package XPerl::Installer::Build;

use strict;
use warnings;
use feature 'signatures';
use Archive::Tar;
use CPAN::Meta;
use Config;
use Cwd qw(abs_path getcwd);
use Digest::SHA;
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find qw(finddepth);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Select;
use IO::Uncompress::Unzip;
use IPC::Open3;
use JSON::PP;
use Symbol qw(gensym);
use Time::HiRes qw(time);
use XPerl::Installer::Agent;
use XPerl::Installer::Platform;
use XPerl::Installer::Proposal;
use XPerl::Installer::Publication;
use XPerl::Installer::Fetch;
use XPerl::Installer::Upstream;

sub new ($class, %args) {
    die "installation prefix is required\n"
        unless defined $args{prefix} && length $args{prefix};
    die "work directory is required\n"
        unless defined $args{workdir} && length $args{workdir};
    my $repair_command;
    die "choose a repair agent or a custom command, not both\n"
        if defined($args{repair_agent}) && defined($args{repair_command});
    my $repair_agent = defined $args{repair_agent}
        ? XPerl::Installer::Agent->prepare($args{repair_agent}) : undef;
    if (defined $args{repair_command}) {
        $repair_command = abs_path($args{repair_command});
        die "repair command must be an executable file\n"
            unless defined $repair_command && -f $repair_command
                && -x $repair_command;
    }
    my $repair_attempts = $args{repair_attempts}
        // ($repair_command || $repair_agent ? 16 : 0);
    die "repair attempts require a repair command or agent\n"
        if $repair_attempts && !$repair_command && !$repair_agent;
    die "repair attempts must be a non-negative integer\n"
        unless $repair_attempts =~ /\A\d+\z/;
    my $repair_timeout = $args{repair_timeout} // 600;
    die "repair timeout must be a positive integer\n"
        unless $repair_timeout =~ /\A[1-9]\d*\z/;
    my $repair_interval = $args{repair_interval} // 10;
    die "repair interval must be a non-negative integer\n"
        unless $repair_interval =~ /\A\d+\z/;
    # A configure, build or test phase that runs longer than this is stopped
    # with every process it started, so one hung test cannot stall a run.
    # 0 disables the limit.
    my $phase_timeout = $args{phase_timeout} // 3600;
    die "phase timeout must be a non-negative integer\n"
        unless $phase_timeout =~ /\A\d+\z/;
    # The per-release attempt count and call timeout always bound a repair.
    # A run-wide call cap is available when the caller explicitly requests it.
    my $repair_limit = $args{repair_limit};
    die "repair limit must be a non-negative integer\n"
        if defined($repair_limit) && $repair_limit !~ /\A\d+\z/;
    my $native_prefixes = $args{native_prefixes} // [];
    die "native prefixes must be a list of directories\n"
        unless ref $native_prefixes eq 'ARRAY';
    my $layout = $args{layout} // 'auto';
    die "layout must be auto, site or install_base\n"
        unless $layout =~ /\A(?:auto|site|install_base)\z/;
    make_path($args{prefix}, $args{workdir});
    my $prefix = abs_path($args{prefix});
    # Installing into the running interpreter's own prefix puts modules where
    # its @INC already looks, so they need no PERL5LIB. Any other prefix is a
    # separate library tree laid out with INSTALL_BASE.
    if ($layout eq 'auto') {
        my $own = $args{interpreter_prefix}
            // ($Config{siteprefixexp} || $Config{installprefix});
        my $own_path = defined $own && length $own ? abs_path($own) : undef;
        $layout = defined $own_path && $own_path eq $prefix
            ? 'site' : 'install_base';
    }
    my %site_dirs = (
        lib     => $Config{installsitelib},
        arch    => $Config{installsitearch},
        bin     => $Config{installsitebin},
        script  => $Config{installsitescript} || $Config{installsitebin},
        man1dir => $Config{installsiteman1dir},
        man3dir => $Config{installsiteman3dir},
        %{$args{site_dirs} // {}},
    );
    my $self = bless {
        native_prefixes => [@$native_prefixes],
        prefix  => $prefix,
        layout  => $layout,
        site_dirs => \%site_dirs,
        workdir => abs_path($args{workdir}),
        install_lock => $args{install_lock},
        registry => $args{registry},
        repair_command => $repair_command,
        repair_agent => $repair_agent,
        repair_attempts => $repair_attempts,
        repair_timeout => $repair_timeout,
        phase_timeout => $phase_timeout,
        repair_limit => $repair_limit,
        repair_interval => $repair_interval,
        repair_rate_file => $args{repair_rate_file} // File::Spec->catfile(
            File::Spec->tmpdir, "xperl-repair-$<.rate"),
        repair_calls => 0,
        # One repair worker per process uses this per-user lock. Parallel
        # runs with more than one repair worker opt out explicitly.
        repair_lock => exists $args{repair_lock} ? $args{repair_lock}
            : File::Spec->catfile(File::Spec->tmpdir,
                                  "xperl-repair-$<.lock"),
    }, $class;
    $self->enable_publication($args{publish}) if defined $args{publish};
    return $self;
}

sub enable_publication ($self, $mode = 'auto') {
    die "publication mode must be auto, direct, pr or off\n"
        unless $mode =~ /\A(?:auto|direct|pr|off)\z/;
    return if !$self->{registry} || $mode eq 'off';
    my $publisher = eval {
        XPerl::Installer::Publication->prepare($self, mode => $mode);
    };
    if ($@) {
        my $reason = $@;
        chomp $reason;
        warn "ports publication setup pending: $reason\n";
        $self->{publication} = XPerl::Installer::Publication->deferred($self, $reason);
        return;
    }
    return unless $publisher;
    $self->{publication} = $publisher;
    $self->{registry} = $publisher->registry;
    warn "ports publication: $publisher->{mode}, branch $publisher->{branch}; "
        . "checkout $publisher->{checkout}\n";
}

sub finish_publication ($self) {
    return {} unless $self->{publication};
    my $result = eval { $self->{publication}->finish($self) };
    return { publication => $result } if $result;
    my $reason = $@ || "publication did not finish\n";
    chomp $reason;
    warn "ports publication remains pending: $reason\n";
    return { publication => { status => 'pending', reason => $reason } };
}

sub repair_enabled ($self) {
    return ($self->{repair_command} || $self->{repair_agent})
        && $self->{repair_attempts};
}

# The directories this builder installs modules into: the library and its
# architecture-specific subdirectory.
sub library_dirs ($self) {
    return @{$self->{site_dirs}}{qw(lib arch)} if $self->{layout} eq 'site';
    my $site = File::Spec->catdir($self->{prefix}, 'lib', 'perl5');
    return ($site, File::Spec->catdir($site, $Config{archname}));
}

# Resolve dependencies from patched metadata when a registry patch changes
# META. Otherwise the scheduler can reject a requirement that the build will
# never see, or miss a prerequisite introduced by the patch.
sub planned_metadata ($self, $release) {
    require XPerl::Installer::Deps;
    my $meta = XPerl::Installer::Deps::_metadata($release->{archive});
    return $meta unless $self->{registry} && $meta;

    if (!defined $release->{distribution}) {
        ($release->{distribution}, $release->{distribution_version}) =
            XPerl::Installer::Deps::_distribution_identity(
                $meta, $release->{cpan_path});
    }
    my $selection = $self->{registry}->patches_for($release);
    my @patches = @{$selection->{patches}};
    return $meta unless grep { _changes_metadata($_->{path}) } @patches;

    my $temporary = File::Temp->newdir('metadata-XXXXXXXX',
                                       DIR => $self->{workdir}, CLEANUP => 1);
    my $work = "$temporary";
    my $source = _unpack($release->{archive}, $work);
    my $number = 0;
    for my $patch (@patches) {
        my $log = File::Spec->catfile($work, 'patch-' . ++$number . '.log');
        my $status = $self->_run($source, $log, 'patch', '--batch',
                                 '--forward', '-p1', '-i', $patch->{path});
        if ($status) {
            open my $input, '<', $log or die "cannot read $log: $!\n";
            my $detail = do { local $/; <$input> };
            close $input;
            die "metadata patch failed (exit $status): $detail\n";
        }
    }
    for my $name (qw(META.json META.yml)) {
        my $path = File::Spec->catfile($source, $name);
        return CPAN::Meta->load_file($path, { lazy_validation => 1 })
            if -f $path;
    }
    return;
}

sub _changes_metadata ($path) {
    open my $input, '<', $path or die "cannot read $path: $!\n";
    while (my $line = <$input>) {
        if ($line =~ m{\A\+\+\+ b/META\.(?:json|yml)(?:\s|\z)}) {
            close $input;
            return 1;
        }
    }
    close $input;
    return 0;
}

sub _makefile_pl_layout ($self) {
    return "INSTALL_BASE=$self->{prefix}" if $self->{layout} eq 'install_base';
    my $dirs = $self->{site_dirs};
    return ('INSTALLDIRS=site',
        "INSTALLSITELIB=$dirs->{lib}", "INSTALLSITEARCH=$dirs->{arch}",
        "INSTALLSITEBIN=$dirs->{bin}", "INSTALLSITESCRIPT=$dirs->{script}",
        'INSTALLSITEMAN1DIR=' . ($dirs->{man1dir} || 'none'),
        'INSTALLSITEMAN3DIR=' . ($dirs->{man3dir} || 'none'));
}

sub _build_pl_layout ($self) {
    return ('--install_base', $self->{prefix})
        if $self->{layout} eq 'install_base';
    my $dirs = $self->{site_dirs};
    my %paths = (lib => $dirs->{lib}, arch => $dirs->{arch},
                 bin => $dirs->{bin}, script => $dirs->{script},
                 ($dirs->{man1dir} ? (bindoc => $dirs->{man1dir}) : ()),
                 ($dirs->{man3dir} ? (libdoc => $dirs->{man3dir}) : ()));
    return ('--installdirs', 'site',
            map { ('--install_path', "$_=$paths{$_}") } sort keys %paths);
}

# Copies of a module that a site install leaves behind in the INSTALL_BASE
# tree under the same prefix. They come first in @INC when PERL5LIB names
# that tree, so they would hide the module just installed.
sub _shadowing_copies ($self, $module) {
    return () unless $self->{layout} eq 'site' && defined $module;
    my @parts = split /::/, $module;
    $parts[-1] .= '.pm';
    my $old = File::Spec->catdir($self->{prefix}, 'lib', 'perl5');
    return grep { -f $_ }
        File::Spec->catfile($old, @parts),
        File::Spec->catfile($old, $Config{archname}, @parts);
}

sub install ($self, $release, %options) {
    my $work = tempdir('release-XXXXXXXX', DIR => $self->{workdir},
                       CLEANUP => 0);
    my $record = {
        module        => $release->{module},
        version       => $release->{version},
        distribution  => $release->{distribution},
        distribution_version => $release->{distribution_version},
        cpan_path     => $release->{cpan_path},
        source_sha256 => $release->{sha256},
        prefix        => $self->{prefix},
        xperl         => abs_path($^X),
        xperl_version => "$^V",
        platform      => XPerl::Installer::Platform::current(),
        native_prefixes => [@{$self->{native_prefixes}}],
        layout        => $self->{layout},
        workdir       => $work,
        phases        => [],
    };

    my $error;
    eval {
        my $source = _unpack($release->{archive}, $work);
        my $original;
        if ($self->repair_enabled) {
            my $original_dir = File::Spec->catdir($work, 'original');
            make_path($original_dir);
            $original = _unpack($release->{archive}, $original_dir);
        }
        my (@recipes, @applied_patches);
        if ($self->{registry}) {
            my $selection = $self->{registry}->patches_for($release);
            @recipes = @{$selection->{recipes} // []};
            $record->{registry} = {
                patch_set => $selection->{patch_set},
                purpose => $selection->{purpose},
                advisories => $selection->{advisories},
                index_sha256 => $selection->{index_sha256},
                patches => [map { $_->{sha256} } @{$selection->{patches}}],
            };
            my $number = 0;
            for my $patch (@{$selection->{patches}}) {
                my $log = File::Spec->catfile($work, "patch-" . ++$number . ".log");
                my $saved = File::Spec->catfile($work, "registry-patch-$number.patch");
                copy($patch->{path}, $saved)
                    or die "cannot copy registry patch to $saved: $!\n";
                open my $patch_file, '<:raw', $saved
                    or die "cannot read copied patch $saved: $!\n";
                my $digest = Digest::SHA->new(256)->addfile($patch_file)->hexdigest;
                close $patch_file or die "cannot close copied patch $saved: $!\n";
                die "registry patch changed while copying: $patch->{path}\n"
                    unless $digest eq $patch->{sha256};
                push @applied_patches, { path => $saved, sha256 => $patch->{sha256} };
                my @command = ('patch', '--batch', '--forward', '-p1',
                               '-i', $saved);
                my $status = $self->_run($source, $log, @command);
                push @{$record->{phases}}, {
                    name => 'patch', command => \@command,
                    exit_status => $status, log => $log,
                };
                die "patch failed (exit $status); see $log\n" if $status;
            }
        }
        my %new_files;
        if ($original) {
            my $original_files = XPerl::Installer::Proposal::files($original);
            my $source_files = XPerl::Installer::Proposal::files($source);
            %new_files = map { $_ => 1 }
                grep { !$original_files->{$_} } keys %$source_files;
        }
        my $perl = abs_path($^X);
        my $make = $Config{make} || 'make';
        my $core = dirname($perl);
        my @make_command = ($make,
            (-f File::Spec->catfile($core, 'perl.h')
                 && -f File::Spec->catfile($core, 'config.h')
                ? ("PERL_INC=$core") : ()));
        my @steps;
        my $configured_target;
        if (-f File::Spec->catfile($source, 'Makefile.PL')) {
            $record->{build_system} = 'Makefile.PL';
            $configured_target = 'Makefile';
            @steps = (
                ['configure', $perl, 'Makefile.PL',
                    $self->_makefile_pl_layout],
                ['build', @make_command],
                ['test', @make_command, 'test'],
                ['install', @make_command, 'install'],
            );
        }
        elsif (-f File::Spec->catfile($source, 'Build.PL')) {
            $record->{build_system} = 'Build.PL';
            $configured_target = 'Build';
            @steps = (
                ['configure', $perl, 'Build.PL',
                    $self->_build_pl_layout],
                ['build', $perl, 'Build'],
                ['test', $perl, 'Build', 'test'],
                ['install', $perl, 'Build', 'install'],
            );
        }
        else {
            die "distribution has neither Makefile.PL nor Build.PL\n";
        }
        my $attempt = 0;
        my $repair_calls = 0;
        ATTEMPT: while (1) {
            ++$attempt;
            for my $step (@steps) {
                my ($phase, @command) = @$step;
                if ($phase eq 'install' && $repair_calls) {
                    my $path = File::Spec->catfile($work, 'proposal.patch');
                    my $proposal = XPerl::Installer::Proposal->write_patch(
                        original => $original, source => $source,
                        path => $path, new_files => \%new_files);
                    $record->{proposal} = $proposal;
                    if (@{$proposal->{files}}) {
                        my $log = File::Spec->catfile($work,
                                                      'proposal-check.log');
                        my @check = ('patch', '--dry-run', '--batch', '-p1',
                                     '-i', $path);
                        my $status = $self->_run($original, $log, @check);
                        push @{$record->{phases}}, {
                            name => 'proposal-check', command => \@check,
                            exit_status => $status, log => $log,
                        };
                        die "proposal patch failed (exit $status); see $log\n"
                            if $status;
                    }
                }
                my $log = File::Spec->catfile($work, "$phase-$attempt.log");
                # Concurrent installers sharing a prefix take turns to
                # install, so shared files such as perllocal.pod and the
                # directory tree are never written by two at once.
                my $lock = $phase eq 'install' && $self->{install_lock}
                    ? _lock($self->{install_lock}) : undef;
                my $started = time;
                my ($status, $timed_out) = $self->_run($source, $log,
                    { phase => $phase,
                      unsafe_inc => $release->{x_use_unsafe_inc},
                      ($self->{phase_timeout}
                          ? (timeout => $self->{phase_timeout}) : ()) },
                    @command);
                my $finished = time;
                undef $lock;
                my $configuration_error;
                if ($phase eq 'configure' && !$status
                    && !-f File::Spec->catfile($source, $configured_target)) {
                    $configuration_error =
                        "configure did not produce $configured_target";
                }
                push @{$record->{phases}}, {
                    name => $phase, attempt => $attempt, command => \@command,
                    exit_status => $status, log => $log,
                    started => $started, finished => $finished,
                    ($timed_out ? (timed_out => JSON::PP::true) : ()),
                    ($configuration_error
                        ? (validation_error => $configuration_error) : ()),
                };
                $options{after_configure}->($source)
                    if $phase eq 'configure' && !$status
                        && !$configuration_error && $options{after_configure};
                next unless $status || $configuration_error;
                my $failure = $configuration_error
                    ? "$configuration_error; see $log\n"
                    : $timed_out
                    ? "$phase timed out after $self->{phase_timeout} seconds; see $log\n"
                    : "$phase failed (exit $status); see $log\n";
                if (-f File::Spec->catfile($self->{workdir}, 'stop-requested')) {
                    $record->{repair_skipped} = 'stop requested';
                    die $failure;
                }
                die $failure
                    if $phase eq 'install' || !$self->repair_enabled
                        || $attempt > $self->{repair_attempts};
                if (defined $self->{repair_limit}
                    && $self->{repair_calls} >= $self->{repair_limit}) {
                    $record->{repair_skipped} =
                        "repair limit of $self->{repair_limit} calls reached";
                    chomp $failure;
                    die "$failure; repair skipped: $record->{repair_skipped}"
                        . " (raise it with --repair-limit)\n";
                }
                my $request_path = File::Spec->catfile($work,
                                                        "repair-$attempt.json");
                # Keep the protocol response with the source so a wrapper
                # needs no write access to the installer's work directory.
                my $response_path = File::Spec->catfile($source,
                                                        ".xperl-repair-$attempt-response.json");
                my $research_path = File::Spec->catfile($source,
                    ".xperl-repair-$attempt-upstream.json");
                my @known_patches;
                if ($self->{registry}) {
                    my $number = 0;
                    for my $patch (@{$self->{registry}->known_patches_for($release)}) {
                        my $saved = File::Spec->catfile($work,
                            'known-patch-' . ++$number . '.patch');
                        copy($patch->{path}, $saved)
                            or die "cannot copy registry patch to $saved: $!\n";
                        open my $file, '<:raw', $saved
                            or die "cannot read copied patch $saved: $!\n";
                        my $digest = Digest::SHA->new(256)->addfile($file)->hexdigest;
                        close $file or die "cannot close copied patch $saved: $!\n";
                        die "registry patch changed while copying: $patch->{path}\n"
                            unless $digest eq $patch->{sha256};
                        push @known_patches, { %$patch, path => $saved };
                    }
                }
                my $request = {
                    schema => 1,
                    attempt => $attempt,
                    source => $source,
                    module => $release->{module},
                    cpan_path => $release->{cpan_path},
                    source_sha256 => $release->{sha256},
                    xperl => $perl,
                    xperl_version => "$^V",
                    platform => $record->{platform},
                    applied_patches => \@applied_patches,
                    known_patches => \@known_patches,
                    failed_phase => $phase,
                    ($configuration_error
                        ? (validation_error => $configuration_error) : ()),
                    failed_command => \@command,
                    failed_log => $log,
                    response_path => $response_path,
                    upstream => XPerl::Installer::Upstream->resources($source),
                    upstream_research_path => $research_path,
                    recipes => \@recipes,
                    guidance => 'Check upstream repository issues, pull requests '
                        . 'and fixes before editing. Record findings in '
                        . 'upstream_research_path, or explain unavailable access. '
                        . 'Do not get stuck in a debug/change loop. '
                        . 'If you are not making progress, return '
                        . 'needs_user_action with kind manual_step and tell '
                        . 'the human what you tried and what to inspect.',
                    ($self->{repair_agent}
                        ? (agent => $self->{repair_agent}) : ()),
                    ($self->{registry}
                        ? (registry => $self->{registry}{path}) : ()),
                };
                open my $request_file, '>', $request_path
                    or die "cannot write $request_path: $!\n";
                print {$request_file} JSON::PP->new->canonical->pretty
                    ->encode($request);
                close $request_file
                    or die "cannot close $request_path: $!\n";
                my @repair_command = $self->{repair_agent}
                    ? XPerl::Installer::Agent->command($self->{repair_agent},
                                                       $request_path, $request)
                    : ($self->{repair_command}, $request_path);
                my $repair_log = File::Spec->catfile($work,
                                                     "repair-$attempt.log");
                my $before_files = XPerl::Installer::Proposal::files($source);
                my $before_source = XPerl::Installer::Proposal
                    ->source_fingerprint(original => $original,
                                         source => $source,
                                         new_files => \%new_files);
                ++$self->{repair_calls};
                my $repair_lock = $self->{repair_lock}
                    ? _lock($self->{repair_lock}) : undef;
                _space_repair_calls($self->{repair_rate_file},
                                    $self->{repair_interval});
                my ($repair_status, $repair_timed_out) = $self->_run($source, $repair_log,
                    { timeout => $self->{repair_timeout} }, @repair_command);
                undef $repair_lock;
                ++$repair_calls;
                push @{$record->{phases}}, {
                    name => 'repair', attempt => $attempt,
                    command => \@repair_command, request => $request_path,
                    exit_status => $repair_status, log => $repair_log,
                };
                # Keep research even when the agent hands the failure back
                # to a human. A malformed report must not discard a repair.
                my $research = eval {
                    XPerl::Installer::Upstream->read_research($research_path);
                };
                if (!$research) {
                    warn "upstream research was not recorded: $@";
                    $research = { status => 'not_reported', references => [] };
                }
                push @{$record->{upstream_research}}, $research;
                die "repair timed out after $self->{repair_timeout} seconds; see $repair_log\n"
                    if $repair_timed_out;
                die "repair failed (exit $repair_status); see $repair_log\n"
                    if $repair_status;
                if (-f $response_path) {
                    my $response = _read_repair_response($response_path);
                    $record->{phases}[-1]{response} = $response_path;
                    if ($response->{status} eq 'needs_user_action') {
                        $record->{user_action} = $response->{action};
                        die "user action required: $response->{action}{message}; see $response_path\n";
                    }
                    die { defer => [$response->{dependency}] };
                }
                my $after_files = XPerl::Installer::Proposal::files($source);
                my $manifest = XPerl::Installer::Proposal->manifest_files($source);
                $new_files{$_} = 1 for grep {
                    !$before_files->{$_}
                        && XPerl::Installer::Proposal
                            ->patchable_new_file($source, $_, $manifest)
                } keys %$after_files;
                my $after_source = XPerl::Installer::Proposal
                    ->source_fingerprint(original => $original,
                                         source => $source,
                                         new_files => \%new_files);
                if ($after_source eq $before_source) {
                    $record->{phases}[-1]{unchanged} = JSON::PP::true;
                    die "repair made no source changes; see $repair_log\n";
                }
                $record->{phases}[-1]{removed_build_files} =
                    _remove_build_products($source, $original, \%new_files);
                next ATTEMPT;
            }
            last;
        }
        $record->{status} = 'installed';
        if (my @old = $self->_shadowing_copies($release->{module})) {
            $record->{shadowed_by} = \@old;
            warn "warning: $_ hides the $release->{module} just installed "
                . "when PERL5LIB includes $self->{prefix}/lib/perl5\n"
                for @old;
        }
        1;
    } or $error = $@ || "installation failed\n";
    # An after_configure hook may stop the attempt because the configured
    # release needs prerequisites that are not available yet. That is not a
    # build result, so it is recorded apart from receipts.
    my $deferred = ref($error) eq 'HASH' && $error->{defer};
    $record->{status} = $deferred ? 'deferred' : 'failed' if $error;
    $record->{deferred_prerequisites} = $error->{defer} if $deferred;
    if (!$error && $self->{registry} && $record->{proposal}{sha256}) {
        my $registered = eval {
            $self->{registry}->register_repair($release, $record);
        };
        if ($@) {
            chomp(my $reason = $@);
            $record->{registration} = { status => 'failed', reason => $reason };
            warn "repair installed but registry registration failed: $reason\n";
        }
        else {
            $record->{registration} = { status => 'registered', %$registered };
        }
    }
    my $receipt = File::Spec->catfile($work,
        $deferred ? 'deferred.json' : 'receipt.json');
    open my $out, '>', $receipt or die "cannot write $receipt: $!\n";
    print {$out} JSON::PP->new->canonical->pretty->encode($record);
    close $out or die "cannot close $receipt: $!\n";
    # Publication records both successful builds and failures. Keep the
    # immutable build receipt separate from its retryable publication state.
    if (!$deferred && $self->{publication}) {
        my $publication = eval {
            my $result = $self->{publication}->complete($self, $release, $receipt);
            XPerl::Installer::Publication::_write_json(
                File::Spec->catfile($work, 'publication.json'), $result);
            $result;
        };
        if (!$publication) {
            chomp(my $reason = $@ || 'cannot save publication state');
            warn "ports publication pending; receipt $receipt: $reason\n";
            $publication = { status => 'pending', reason => $reason,
                             receipt => $receipt };
        }
        $record->{publication} = $publication;
    }
    die { %$error, receipt => $receipt } if $deferred;
    die "$error receipt: $receipt\n" if $error;
    $record->{receipt} = $receipt;
    return $record;
}

sub _read_repair_response ($path) {
    open my $input, '<', $path or die "cannot read repair response $path: $!\n";
    my $response = eval { JSON::PP->new->decode(do { local $/; <$input> }) };
    die "invalid repair response $path: $@\n" if $@;
    die "invalid repair response $path: expected schema 1\n"
        unless ref($response) eq 'HASH' && ($response->{schema} // '') eq '1';
    if (($response->{status} // '') eq 'needs_cpan_dependency') {
        my $module = $response->{module} // '';
        die "invalid repair response $path: expected CPAN module name\n"
            unless !ref($module)
                && $module =~ /\A[A-Za-z_][A-Za-z_0-9]*(?:::[A-Za-z_0-9]+)*\z/;
        return { status => 'needs_cpan_dependency',
                 dependency => { module => $module,
                                 range => $response->{range} // '0' } };
    }
    die "invalid repair response $path: expected needs_user_action or needs_cpan_dependency\n"
        unless ($response->{status} // '') eq 'needs_user_action';
    my $action = $response->{action};
    die "invalid repair response $path: action needs a kind and message\n"
        unless ref($action) eq 'HASH'
            && ($action->{kind} // '') =~ /\A(?:system_dependency|core_change|manual_step)\z/
            && !ref($action->{message}) && length($action->{message} // '');
    die "invalid repair response $path: message must be one line\n"
        if $action->{message} =~ /[\r\n]/;
    if (exists $action->{install_hint}) {
        die "invalid repair response $path: install_hint must be a string\n"
            if ref($action->{install_hint});
    }
    return { status => 'needs_user_action', action => {
        map { $_ => $action->{$_} }
        grep { exists $action->{$_} } qw(kind message install_hint)
    } };
}

# Make compares timestamps, and some make programs (GNU make 3.81, the
# macOS default) use one-second resolution. A repair that lands in the same
# second as the previous build can leave stale build products that make
# considers current. Remove every file that is neither from the original
# release nor added by a patch or repair, so the next attempt rebuilds from
# the repaired source.
sub _remove_build_products ($source, $original, $keep) {
    my $original_files = XPerl::Installer::Proposal::files($original);
    my $source_files = XPerl::Installer::Proposal::files($source);
    my $removed = 0;
    for my $relative (sort keys %$source_files) {
        next if $original_files->{$relative} || $keep->{$relative};
        next if XPerl::Installer::Proposal->work_product($relative);
        my $path = File::Spec->catfile($source, $relative);
        unlink $path or die "cannot remove build product $path: $!\n";
        ++$removed;
    }
    finddepth({
        no_chdir => 1,
        wanted => sub {
            my $path = $File::Find::name;
            return if $path eq $source || -l $path || !-d $path;
            my $relative = substr($path, length($source) + 1);
            return if -d File::Spec->catdir($original, $relative);
            rmdir $path;    # only succeeds once the directory is empty
        },
    }, $source);
    return $removed;
}

sub _lock ($path) {
    open my $handle, '>>', $path or die "cannot open install lock $path: $!\n";
    flock($handle, LOCK_EX) or die "cannot lock $path: $!\n";
    return $handle;    # released when the handle is closed
}

# A short agent call should not let the next worker start immediately. The
# timestamp is shared by installer processes owned by this user; the lock is
# held only while selecting and recording the next start time.
sub _space_repair_calls ($path, $interval) {
    return unless $interval;

    open my $gate, '+>>', $path
        or die "cannot open repair rate file $path: $!\n";
    flock($gate, LOCK_EX)
        or die "cannot lock repair rate file $path: $!\n";
    seek $gate, 0, 0 or die "cannot read repair rate file $path: $!\n";
    my $previous = <$gate>;
    if (defined $previous && $previous =~ /\A\d+(?:\.\d+)?\s*\z/) {
        my $wait = $previous + $interval - time;
        Time::HiRes::sleep($wait) if $wait > 0;
    }

    truncate($gate, 0) or die "cannot reset repair rate file $path: $!\n";
    printf {$gate} "%.6f\n", time
        or die "cannot write repair rate file $path: $!\n";
    close $gate or die "cannot close repair rate file $path: $!\n";
}

sub _unpack ($archive, $work) {
    return _unpack_zip($archive, $work) if $archive =~ /\.zip\z/i;

    my $tar = Archive::Tar->new;
    $tar->read($archive, 1) or die "cannot read $archive\n";
    my @files = $tar->get_files;
    die "empty archive: $archive\n" unless @files;
    my $root = XPerl::Installer::Fetch::_tar_root(@files);
    my $before = getcwd();
    chdir $work or die "cannot enter $work: $!\n";
    my $ok = $tar->extract;
    my $message = $Archive::Tar::error;
    chdir $before or die "cannot return to $before: $!\n";
    die "cannot extract $archive: $message\n" unless $ok;
    return File::Spec->catdir($work, $root);
}

sub _unpack_zip ($archive, $work) {
    my $modes = _zip_modes($archive);
    my $zip = IO::Uncompress::Unzip->new($archive)
        or die "cannot read $archive: $IO::Uncompress::Unzip::UnzipError\n";
    my %roots;
    my @permissions;
    my $next;
    do {
        my $name = $zip->getHeaderInfo->{Name};
        my ($root) = $name =~ m{\A([^/]+)};
        die "unsafe archive member: $name\n"
            unless defined $root && length $root
                && $name !~ m{\A/|(?:\A|/)\.\.?(?:/|\z)}
                && $name !~ /[\\:\0]/
                && ($name =~ m{/} || $name =~ m{/$});
        $roots{$root} = 1;

        my $target = File::Spec->catfile($work, split m{/}, $name);
        if ($name =~ m{/$}) {
            make_path($target);
        }
        else {
            make_path(dirname($target));
            open my $out, '>:raw', $target
                or die "cannot write $target: $!\n";
            my $buffer;
            while (my $size = $zip->read($buffer, 65536)) {
                die "cannot read $name: $IO::Uncompress::Unzip::UnzipError\n"
                    if $size < 0;
                print {$out} $buffer or die "cannot write $target: $!\n";
            }
            close $out or die "cannot close $target: $!\n";
        }
        push @permissions, [$target, $modes->{$name}]
            if defined $modes->{$name};
        $next = $zip->nextStream;
    } while ($next > 0);
    die "cannot read $archive: $IO::Uncompress::Unzip::UnzipError\n"
        if $next < 0;
    die "archive has multiple source roots\n" unless keys(%roots) == 1;
    for my $entry (@permissions) {
        my ($path, $mode) = @$entry;
        chmod($mode, $path) == 1
            or die "cannot set permissions on $path: $!\n";
    }
    my ($root) = keys %roots;
    return File::Spec->catdir($work, $root);
}

# ZIP local headers omit Unix modes. Read them from the central directory
# after extracting, so a script stays executable without an external unzip.
sub _zip_modes ($archive) {
    open my $input, '<:raw', $archive or die "cannot read $archive: $!\n";
    seek $input, 0, 2 or die "cannot seek $archive: $!\n";
    my $size = tell $input;
    my $tail_size = $size < 65557 ? $size : 65557;
    seek $input, -$tail_size, 2 or die "cannot seek $archive: $!\n";
    read($input, my $tail, $tail_size) == $tail_size
        or die "cannot read ZIP directory in $archive\n";
    my $end = rindex($tail, "PK\x05\x06");
    die "cannot find ZIP directory in $archive\n"
        if $end < 0 || length($tail) - $end < 22;
    my $count = unpack('v', substr($tail, $end + 10, 2));
    my $offset = unpack('V', substr($tail, $end + 16, 4));
    # ZIP64 archives can be extracted, but this small reader cannot recover
    # their Unix modes from the extended directory offset.
    return {} if $count == 0xffff || $offset == 0xffffffff;
    seek $input, $offset, 0 or die "cannot seek ZIP directory: $!\n";

    my %modes;
    for (1 .. $count) {
        my $header;
        read($input, $header, 46) == 46
            && substr($header, 0, 4) eq "PK\x01\x02"
            or die "invalid ZIP directory in $archive\n";
        my $host = ord(substr($header, 5, 1));
        my ($name_size, $extra_size, $comment_size) =
            unpack('v3', substr($header, 28, 6));
        read($input, my $name, $name_size) == $name_size
            or die "invalid ZIP filename in $archive\n";
        seek $input, $extra_size + $comment_size, 1
            or die "cannot seek ZIP directory: $!\n";
        next unless $host == 3 || $host == 19;
        my $attributes = unpack('V', substr($header, 38, 4));
        $modes{$name} = ($attributes >> 16) & 0777;
    }
    close $input or die "cannot close $archive: $!\n";
    return \%modes;
}

sub _run ($self, $source, $log_path, @command) {
    my $options = ref $command[0] eq 'HASH' ? shift @command : {};
    my $deadline = defined $options->{timeout}
        ? time + $options->{timeout} : undef;
    open my $log, '>', $log_path or die "cannot write $log_path: $!\n";
    my $before = getcwd();
    my @include = grep { length $_ && -d $_ }
        split /\Q$Config{path_sep}\E/, $ENV{PERL5LIB} // '';
    @include = map { abs_path($_) } @include;
    my ($site, $arch) = $self->library_dirs;
    local %ENV = %ENV;
    delete @ENV{qw(MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKELEVEL)};
    # A caller's local::lib settings would send a site install elsewhere.
    delete @ENV{qw(PERL_MM_OPT PERL_MB_OPT)} if $self->{layout} eq 'site';
    $ENV{PERL5LIB} = join($Config{path_sep}, $site, $arch, @include);
    # Native library prefixes come after anything the caller already set.
    for my $prefix (@{$self->{native_prefixes}}) {
        for my $entry ([CPATH => 'include'], [LIBRARY_PATH => 'lib'],
                       [PKG_CONFIG_PATH => 'lib', 'pkgconfig']) {
            my ($name, @parts) = @$entry;
            my $dir = File::Spec->catdir($prefix, @parts);
            next unless -d $dir;
            $ENV{$name} = join $Config{path_sep},
                grep { defined && length } $ENV{$name}, $dir;
        }
    }
    if (my $phase = $options->{phase}) {
        $ENV{PERL} = abs_path($^X);
        $ENV{PERL_USE_UNSAFE_INC} =
            defined($options->{unsafe_inc}) ? $options->{unsafe_inc} : 1
            unless exists $ENV{PERL_USE_UNSAFE_INC};
        if ($phase eq 'configure') {
            $ENV{PERL5_CPAN_IS_RUNNING} = $$;
            $ENV{PERL5_CPANPLUS_IS_RUNNING} = $$;
            $ENV{PERL5_CPANM_IS_RUNNING} = $$;
            $ENV{PERL5_CPAN_IS_EXECUTING} =
                File::Spec->catfile($source, 'Makefile.PL')
                if defined($command[1]) && $command[1] eq 'Makefile.PL';
        }
        if ($phase eq 'configure' || $phase eq 'build' || $phase eq 'test') {
            $ENV{PERL_MM_USE_DEFAULT} = 1;
        }
        $ENV{NONINTERACTIVE_TESTING} = 1 if $phase eq 'test';
    }
    chdir $source or die "cannot enter $source: $!\n";
    # A command with a deadline runs in its own process group, so that on
    # timeout everything it started can be stopped, not just the command.
    my $group = defined $deadline && $^O ne 'MSWin32';
    @command = ($^X, '-e',
        'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "cannot exec $ARGV[0]: $!\\n"',
        '--', @command) if $group;
    my ($input, $output, $error) = (gensym, gensym, gensym);
    my $pid = eval { open3($input, $output, $error, @command) };
    my $start_error = $@;
    if (!$pid) {
        chdir $before or die "cannot return to $before: $!\n";
        die "cannot start @command: $start_error\n";
    }
    close $input;
    my $select = IO::Select->new($output, $error);
    my $timed_out = 0;
    while ($select->count) {
        my $remaining = defined $deadline ? $deadline - time : undef;
        if (defined $remaining && $remaining <= 0) {
            $timed_out = 1;
            last;
        }
        my @ready = $select->can_read($remaining);
        if (!@ready) {
            if (defined $deadline && time >= $deadline) {
                $timed_out = 1;
                last;
            }
            next;
        }
        for my $fh (@ready) {
            my $length = sysread($fh, my $buffer, 8192);
            die "cannot read command output: $!\n" unless defined $length;
            if ($length) { print {$log} $buffer }
            else { $select->remove($fh); close $fh }
        }
    }
    if ($timed_out) {
        kill 9, -$pid if $group;
        kill 9, $pid;
        for my $fh ($select->handles) { close $fh }
    }
    waitpid($pid, 0);
    my $status = $?;
    chdir $before or die "cannot return to $before: $!\n";
    close $log or die "cannot close $log_path: $!\n";
    my $exit = $timed_out ? 124
        : $status & 127 ? 128 + ($status & 127) : $status >> 8;
    return wantarray ? ($exit, $timed_out) : $exit;
}

1;
