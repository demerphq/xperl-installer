package XPerl::Installer::Ported;

use strict;
use warnings;
use feature 'signatures';
use Config;
use Cwd qw(abs_path);
use File::Basename qw(basename);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP;
use POSIX qw(strftime);
use version;
use XPerl::Installer::Deps;
use XPerl::Installer::Parallel;
use XPerl::Installer::Platform;
use XPerl::Installer::Registry;

# Batch validation of recorded ports: select one recorded release for every
# author and distribution with a successful observation in the registry,
# then build each through the ordinary dependency, patch, build, test and
# install code paths. See README.md ("Validating recorded ports") for the
# selection rules.

my $JSON = JSON::PP->new->canonical->pretty;

sub select_entries ($class, %args) {
    my $registry = $args{registry} // die "registry is required\n";
    my %only = map { _check_key($_) => 1 } @{$args{only} // []};
    my %exclude = map { _check_key($_) => 1 } @{$args{exclude} // []};
    my $records = $registry->status_records;
    my (@entries, @excluded);
    for my $record (@{$records->{records}}) {
        my $entry = _select_release($record) or next;
        if ((%only && !$only{$entry->{key}}) || $exclude{$entry->{key}}) {
            push @excluded, $entry->{key};
            next;
        }
        $entry->{plan} = _plan_patches($registry, $entry);
        push @entries, $entry;
    }
    for my $key (sort keys %only) {
        die "--only $key matches no recorded success\n"
            unless grep { $_->{key} eq $key } @entries;
    }
    @entries = sort { $a->{key} cmp $b->{key} } @entries;
    return {
        entries => \@entries,
        invalid => $records->{invalid},
        excluded => [sort @excluded],
    };
}

sub _check_key ($key) {
    die "expected AUTHOR/Distribution, got $key\n"
        unless $key =~ m{\A[A-Z0-9_-]+/[A-Za-z0-9][A-Za-z0-9_.-]*\z};
    return $key;
}

# One release per author and distribution, chosen deterministically:
# successes under the running XPerl version first, then the highest release
# version, then the newest success, then the archive path.
sub _select_release ($record) {
    my %releases;
    for my $observation (@{$record->{observations}}) {
        my $id = join "\0", $observation->{cpan_path} // '',
                            $observation->{source_sha256} // '';
        push @{$releases{$id}}, $observation;
    }
    my @candidates;
    for my $observations (values %releases) {
        my @ordered = sort {
            ($a->{observed_at} // '') cmp ($b->{observed_at} // '')
                || ($a->{id} // '') cmp ($b->{id} // '')
        } @$observations;
        my @successes = grep { ($_->{status} // '') eq 'installed' } @ordered;
        next unless @successes;
        push @candidates, {
            latest => $ordered[-1],
            success => $successes[-1],
            current => (grep { ($_->{xperl_version} // '') eq "$^V" }
                        @successes) ? 1 : 0,
        };
    }
    return unless @candidates;
    my ($chosen) = sort {
        $b->{current} <=> $a->{current}
            || _version_cmp($b->{success}{version}, $a->{success}{version})
            || ($b->{success}{observed_at} // '') cmp ($a->{success}{observed_at} // '')
            || $a->{success}{cpan_path} cmp $b->{success}{cpan_path}
    } @candidates;
    my $success = $chosen->{success};
    return {
        key => $record->{key},
        author => $record->{author},
        distribution => $record->{distribution},
        version => $success->{version},
        module => $success->{module},
        (defined $success->{module_version}
            ? (module_version => $success->{module_version}) : ()),
        cpan_path => $success->{cpan_path},
        source_sha256 => $success->{source_sha256},
        status_record => $record->{path},
        recorded => {
            observed_at => $success->{observed_at},
            xperl_version => $success->{xperl_version},
            platform => ref($success->{platform}) eq 'HASH'
                ? $success->{platform}{key} : 'unrecorded',
            patch_set => $success->{patch_set},
            patch_sha256 => $success->{patch_sha256} // [],
            test_summary => $success->{test_summary},
            latest_status => $chosen->{latest}{status},
            successful_releases => scalar @candidates,
        },
    };
}

sub _version_cmp ($left, $right) {
    my $result = eval {
        version->parse($left // 0) <=> version->parse($right // 0)
    };
    return $result // (($left // '') cmp ($right // ''));
}

# The patch set the registry selects now for the running XPerl.
sub _plan_patches ($registry, $entry) {
    my $selection = eval {
        $registry->patches_for(_release_identity($entry));
    };
    if (!$selection) {
        chomp(my $error = $@);
        return { error => $error };
    }
    return {
        patch_set => $selection->{patch_set},
        patch_sha256 => [map { $_->{sha256} } @{$selection->{patches}}],
        index_sha256 => $selection->{index_sha256},
    };
}

sub _release_identity ($entry) {
    return {
        module => $entry->{module},
        version => $entry->{module_version} // $entry->{version},
        distribution => $entry->{distribution},
        distribution_version => $entry->{version},
        cpan_path => $entry->{cpan_path},
        sha256 => $entry->{source_sha256},
    };
}

# Fetch the recorded archive itself, never the current CPAN index answer.
sub _fetch_recorded ($fetcher, $entry) {
    my $fetched = $fetcher->fetch_path($entry->{cpan_path});
    die "source changed: recorded $entry->{source_sha256}, archive has $fetched->{sha256}\n"
        unless $fetched->{sha256} eq $entry->{source_sha256};
    return { %$fetched, %{_release_identity($entry)} };
}

sub run ($class, %args) {
    my ($registry, $fetcher, $builder, $selection) =
        @args{qw(registry fetcher builder selection)};
    my $workdir = $builder->{workdir};
    my $dir = File::Spec->catdir($workdir, 'install-ported');
    my $state_path = File::Spec->catfile($dir, 'state.json');
    my $identity = {
        xperl => abs_path($^X),
        xperl_version => "$^V",
        prefix => $builder->{prefix},
    };
    my $state;
    if (-f $state_path) {
        die "$workdir already holds an install-ported run; pass --resume or use a fresh --workdir\n"
            unless $args{resume};
        $state = _read_json($state_path);
        for my $field (sort keys %$identity) {
            die "cannot resume: the earlier run used $field $state->{$field}, "
                . "this run uses $identity->{$field}\n"
                unless ($state->{$field} // '') eq $identity->{$field};
        }
    }
    $state //= { schema => 1, %$identity, entries => {}, built => {} };
    make_path($dir);

    my %selected = map { $_->{key} => $_ } @{$selection->{entries}};
    my $deps;
    $deps = XPerl::Installer::Deps->new(
        fetcher => $fetcher, builder => $builder,
        prefer => sub ($module) {
            my $resolved = eval { $fetcher->resolve($module) } or return;
            my $entry = $selected{_key_for_path($resolved->{cpan_path}) // ''}
                or return;
            return _fetch_recorded($fetcher, $entry);
        });
    for my $path (sort keys %{$state->{built}}) {
        my $receipt = $state->{built}{$path};
        $deps->mark_installed($path, $receipt) if defined $receipt && -f $receipt;
    }

    my $started = time;
    my @results;
    my $total = @{$selection->{entries}};
    my $number = 0;
    if (($args{jobs} // 1) > 1) {
        @results = _run_parallel($fetcher, $builder, $selection, $state,
                                 $state_path, $deps->{prefer}, %args);
    }
    else { for my $entry (@{$selection->{entries}}) {
        ++$number;
        my $result = _run_entry($deps, $fetcher, $entry,
                                $state->{entries}{$entry->{key}});
        push @results, $result;
        printf STDERR "[%*d/%d] %-9s %s %s%s\n", length($total), $number,
            $total, $result->{status}, $entry->{key}, $entry->{version},
            ($result->{resumed} ? ' (resumed)'
             : $result->{reason} ? " ($result->{reason})" : '')
            if $args{progress};
        _save_entry($state, $result);
        $state->{built} = { %{$deps->{installed}} };
        _write_json($state_path, $state);
    } }

    my %counts = map { $_ => 0 } qw(installed satisfied failed skipped);
    ++$counts{$_->{status}} for @results;
    my $report = {
        schema => 1,
        started => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $started),
        finished => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        platform => XPerl::Installer::Platform::current(),
        xperl => {
            path => abs_path($^X),
            version => "$^V",
            config => { map { $_ => $Config{$_} } grep { defined $Config{$_} }
                        qw(archname osname osvers cc ccflags optimize
                           usethreads use64bitall uselongdouble usequadmath
                           git_commit_id) },
        },
        registry => { path => $registry->{path}, %{$registry->revision} },
        prefix => $builder->{prefix},
        workdir => $workdir,
        resumed_run => $args{resume} ? JSON::PP::true : JSON::PP::false,
        counts => \%counts,
        selected => $total,
        excluded => $selection->{excluded},
        invalid => $selection->{invalid},
        entries => \@results,
    };
    $report->{report} = File::Spec->catfile($dir, 'report.json');
    $report->{summary} = File::Spec->catfile($dir, 'summary.txt');
    _write_json($report->{report}, $report);
    _write_text($report->{summary}, summary($report));
    return $report;
}

sub _save_entry ($state, $result) {
    $state->{entries}{$result->{key}} = {
        map { $_ => $result->{$_} }
        grep { defined $result->{$_} }
        qw(status reason receipt cpan_path source_sha256 patch_set patch_sha256)
    };
}

# The same entries built by the parallel scheduler: recorded releases are
# forced nodes, their prerequisites prefer recorded releases too, and every
# release is built at most once.
sub _run_parallel ($fetcher, $builder, $selection, $state, $state_path,
                   $prefer, %args) {
    my $parallel = XPerl::Installer::Parallel->new(
        fetcher => $fetcher, builder => $builder, jobs => $args{jobs},
        prefer => $prefer,
        ($args{progress} ? (progress => sub ($node) {
            printf STDERR "%-9s %s%s\n", $node->{status}, $node->{cpan_path},
                ($node->{reason} ? " ($node->{reason})" : '');
        }) : ()));
    for my $path (sort keys %{$state->{built}}) {
        my $receipt = $state->{built}{$path};
        $parallel->mark_installed($path, $receipt) if defined $receipt && -f $receipt;
    }
    my (%results, @build);
    for my $entry (@{$selection->{entries}}) {
        my %result = _entry_fields($entry);
        my $previous = $state->{entries}{$entry->{key}};
        if (_resumable($previous, $entry)) {
            $parallel->mark_installed($entry->{cpan_path}, $previous->{receipt})
                if $previous->{status} eq 'installed';
            $results{$entry->{key}} = { %result, %$previous,
                resumed => JSON::PP::true, _receipt_details($previous->{receipt}) };
            next;
        }
        my ($release, $skipped) = _fetch_or_skip($fetcher, $entry, \%result);
        if ($skipped) { $results{$entry->{key}} = $skipped; next }
        push @build, [$entry, $release];
    }
    my $run = $parallel->run(map { { release => $_->[1] } } @build);
    for my $request (@{$run->{requests}}) {
        my ($pair) = grep { $_->[1] == $request->{release} } @build;
        my $entry = $pair->[0];
        my %result = _entry_fields($entry);
        my $node = defined $request->{node} ? $parallel->node($request->{node}) : undef;
        if (!$node) {
            $results{$entry->{key}} = { %result, status => 'failed',
                reason => $request->{error} // 'not scheduled' };
            next;
        }
        my $receipt = $node->{receipt};
        $results{$entry->{key}} = {
            %result,
            status => $node->{state} eq 'installed' ? 'installed' : 'failed',
            ($node->{reason} ? (reason => $node->{reason}) : ()),
            ($receipt ? (receipt => $receipt, _receipt_details($receipt)) : ()),
            dependency_receipts => [],
        };
    }
    my @results = map { $results{$_->{key}} } @{$selection->{entries}};
    _save_entry($state, $_) for @results;
    $state->{built} = { %{$state->{built}},
        map { ($_->{path} => $_->{receipt}) }
        grep { $_->{state} eq 'installed' && $_->{receipt} }
        values %{$parallel->{nodes}} };
    _write_json($state_path, $state);
    return @results;
}

sub _entry_fields ($entry) {
    return (
        (map { $_ => $entry->{$_} }
         grep { defined $entry->{$_} }
         qw(key author distribution version module cpan_path source_sha256
            recorded)),
        planned_patch_set => $entry->{plan}{patch_set},
    );
}

# A resumed success must still describe exactly this release and patch
# selection; a failure is always retried.
sub _resumable ($previous, $entry) {
    return $previous && ($previous->{status} // '') =~ /\A(?:installed|satisfied)\z/
        && defined $previous->{receipt} && -f $previous->{receipt}
        && ($previous->{cpan_path} // '') eq $entry->{cpan_path}
        && ($previous->{source_sha256} // '') eq $entry->{source_sha256}
        && _same_patches($previous, $entry->{plan});
}

# The fetch step shared by both modes: the recorded archive, or a skipped
# or failed result.
sub _fetch_or_skip ($fetcher, $entry, $result) {
    my $release = eval { _fetch_recorded($fetcher, $entry) };
    return ($release, undef) if $release;
    chomp(my $error = $@);
    my $skip = $error =~ /\A(?:archive unavailable|source changed)/;
    return (undef, { %$result, status => $skip ? 'skipped' : 'failed',
                     reason => (split /\n/, $error)[0] });
}

sub _run_entry ($deps, $fetcher, $entry, $previous) {
    my %result = _entry_fields($entry);
    my $path = $entry->{cpan_path};

    if (_resumable($previous, $entry)) {
        $deps->mark_installed($path, $previous->{receipt})
            if $previous->{status} eq 'installed';
        return { %result, %$previous, resumed => JSON::PP::true,
                 _receipt_details($previous->{receipt}) };
    }
    if (my $receipt = $deps->{installed}{$path}) {
        return { %result, status => 'satisfied', receipt => $receipt,
                 reason => 'built earlier in this run as a dependency',
                 _receipt_details($receipt) };
    }
    if (defined(my $reason = $deps->{failed}{$path})) {
        return { %result, status => 'failed',
                 reason => "failed earlier in this run: $reason" };
    }

    my ($release, $skipped) = _fetch_or_skip($fetcher, $entry, \%result);
    return $skipped if $skipped;

    $deps->reset_request;
    my $first = @{$deps->{receipts}};
    my $ok = eval { $deps->install_release($release); 1 };
    my $error = $@;
    my @receipts = @{$deps->{receipts}}[$first .. $#{$deps->{receipts}}];
    my $receipt = $deps->{installed}{$path};
    ($receipt) = $error =~ /^ receipt: (\S+)$/m if !$receipt && $error;
    $result{dependency_receipts} = [grep { !defined($receipt) || $_ ne $receipt }
                                    @receipts];
    $result{receipt} = $receipt if defined $receipt;
    if ($ok) {
        return { %result, status => 'installed', _receipt_details($receipt) };
    }
    (my $reason = $error) =~ s/\s*\n receipt: .*//s;
    $reason = (split /\n/, $reason)[0];
    return { %result, status => 'failed', reason => $reason,
             (defined $receipt ? _receipt_details($receipt) : ()) };
}

sub _same_patches ($previous, $plan) {
    return 0 if $plan->{error};
    return 0 unless ($previous->{patch_set} // '') eq ($plan->{patch_set} // '');
    return join(',', @{$previous->{patch_sha256} // []})
        eq join(',', @{$plan->{patch_sha256} // []});
}

# Phase, patch and test details taken from a build receipt.
sub _receipt_details ($path) {
    return () unless defined $path && -f $path;
    my $receipt = eval { _read_json($path) } or return ();
    my @phases = @{$receipt->{phases} // []};
    my ($failed) = reverse grep {
        $_->{exit_status} || $_->{validation_error}
    } @phases;
    my %details = (
        patch_set => $receipt->{registry}{patch_set},
        patch_sha256 => $receipt->{registry}{patches} // [],
    );
    $details{failed_phase} = $failed->{name}
        if $failed && ($receipt->{status} // '') ne 'installed';
    my ($test) = reverse grep { $_->{name} eq 'test' } @phases;
    if ($test && defined $test->{log} && open my $log, '<', $test->{log}) {
        my $text = do { local $/; <$log> };
        if (my ($files, $tests) = $text =~ /^Files=(\d+), Tests=(\d+)/m) {
            $details{test_summary} = "Files=$files, Tests=$tests";
            $details{test_summary} .= ", $1"
                if $text =~ /^(Failed \d+\/\d+ test programs\.[^\n]*)/m;
        }
        $details{test_log} = $test->{log};
    }
    return %details;
}

sub _key_for_path ($cpan_path) {
    my $author = eval { XPerl::Installer::Registry::author_from_path($cpan_path) }
        or return;
    my $archive = basename($cpan_path);
    $archive =~ s/\.(?:tar\.gz|tar\.bz2|tar\.xz|tgz|zip)\z// or return;
    my ($distribution) = $archive =~ /\A(.+)-[vV]?\d[0-9A-Za-z._-]*\z/
        or return;
    return "$author/$distribution";
}

sub summary ($report) {
    my $counts = $report->{counts};
    my $platform = $report->{platform};
    my $registry = $report->{registry};
    my @lines = (
        sprintf('install-ported: %d selected; %d installed, %d satisfied, %d failed, %d skipped',
                $report->{selected}, @{$counts}{qw(installed satisfied failed skipped)}),
        "platform: $platform->{key} ($platform->{cc} $platform->{cc_version}; "
            . 'threads ' . ($platform->{usethreads} ? 'yes' : 'no') . ')',
        "xperl: $report->{xperl}{version} $report->{xperl}{path}"
            . ($platform->{xperl_commit} ? " ($platform->{xperl_commit})" : ''),
        "registry: $registry->{path}"
            . ($registry->{commit} ? " at $registry->{commit}"
               . ($registry->{dirty} ? ' (uncommitted changes)' : '') : ''),
        "prefix: $report->{prefix}",
        "workdir: $report->{workdir}",
    );
    my $excluded = scalar @{$report->{excluded} // []};
    push @lines, "excluded: $excluded "
        . ($excluded == 1 ? 'entry' : 'entries') . ' (listed in report.json)'
        if $excluded;
    push @lines, "invalid status record: $_->{path}: $_->{reason}"
        for @{$report->{invalid} // []};
    push @lines, '';
    for my $entry (@{$report->{entries}}) {
        my $patch = $entry->{patch_set} // $entry->{planned_patch_set};
        my @notes;
        push @notes, 'resumed' if $entry->{resumed};
        push @notes, "patch $patch" if defined $patch;
        push @notes, "recorded patch $entry->{recorded}{patch_set}"
            if defined $entry->{recorded}{patch_set}
                && ($patch // '') ne $entry->{recorded}{patch_set};
        push @notes, 'latest recorded result failed'
            if ($entry->{recorded}{latest_status} // '') eq 'failed';
        push @notes, "$entry->{failed_phase} phase" if $entry->{failed_phase};
        push @notes, $entry->{reason} if $entry->{reason}
            && $entry->{status} ne 'satisfied';
        push @notes, $entry->{test_summary} if $entry->{test_summary};
        push @lines, sprintf('%-9s %s %s%s', $entry->{status}, $entry->{key},
                             $entry->{version},
                             @notes ? ' - ' . join('; ', @notes) : '');
        push @lines, "          receipt: $entry->{receipt}"
            if $entry->{receipt} && $entry->{status} eq 'failed';
    }
    return join("\n", @lines) . "\n";
}

sub plan_summary ($selection) {
    my @lines = (sprintf('install-ported dry run: %d selected, %d excluded, %d invalid records',
                         scalar @{$selection->{entries}},
                         scalar @{$selection->{excluded}},
                         scalar @{$selection->{invalid}}));
    push @lines, "invalid status record: $_->{path}: $_->{reason}"
        for @{$selection->{invalid}};
    push @lines, '';
    for my $entry (@{$selection->{entries}}) {
        my $plan = $entry->{plan};
        my @notes;
        push @notes, $plan->{error} ? "patch lookup error: $plan->{error}"
            : defined $plan->{patch_set} ? "patch $plan->{patch_set}" : 'no patch';
        push @notes, "recorded patch $entry->{recorded}{patch_set}"
            if defined $entry->{recorded}{patch_set}
                && ($plan->{patch_set} // '') ne $entry->{recorded}{patch_set};
        push @notes, "recorded with $entry->{recorded}{xperl_version}"
            if ($entry->{recorded}{xperl_version} // '') ne "$^V";
        push @notes, 'latest recorded result failed'
            if ($entry->{recorded}{latest_status} // '') eq 'failed';
        push @lines, sprintf('%s %s %s - %s', $entry->{key}, $entry->{version},
                             $entry->{cpan_path}, join('; ', @notes));
    }
    return join("\n", @lines) . "\n";
}

# The machine-readable dry-run plan: the selection with planned patches.
sub plan ($selection) {
    return {
        schema => 1,
        platform => XPerl::Installer::Platform::current(),
        xperl => { path => abs_path($^X), version => "$^V" },
        selected => scalar @{$selection->{entries}},
        excluded => $selection->{excluded},
        invalid => $selection->{invalid},
        entries => [map {
            my $entry = $_;
            +{ (map { $_ => $entry->{$_} } grep { defined $entry->{$_} }
                qw(key author distribution version module module_version
                   cpan_path source_sha256 recorded status_record)),
               patch_set => $entry->{plan}{patch_set},
               ($entry->{plan}{error} ? (patch_error => $entry->{plan}{error}) : ()),
               patch_sha256 => $entry->{plan}{patch_sha256} // [] }
        } @{$selection->{entries}}],
    };
}

sub _read_json ($path) {
    open my $input, '<:raw', $path or die "cannot read $path: $!\n";
    return JSON::PP->new->decode(do { local $/; <$input> });
}

sub _write_json ($path, $data) {
    _write_text($path, $JSON->encode($data));
}

sub _write_text ($path, $text) {
    my $partial = "$path.part.$$";
    open my $output, '>', $partial or die "cannot write $partial: $!\n";
    print {$output} $text;
    close $output or die "cannot close $partial: $!\n";
    rename $partial, $path or die "cannot save $path: $!\n";
}

1;
