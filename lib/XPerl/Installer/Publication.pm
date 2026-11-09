package XPerl::Installer::Publication;

use strict;
use warnings;
use feature 'signatures';
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Compare ();
use File::Copy qw(copy);
use File::Find ();
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use XPerl::Installer::Registry;

my $JSON = JSON::PP->new->canonical->pretty;

# Publication uses its own checkout. Git retries must never stash, rebase,
# or stage unrelated work in the registry supplied by the caller.
sub prepare ($class, $builder, %args) {
    my $registry = $builder->{registry} or return;
    my $source = $registry->{path};
    return unless -e File::Spec->catfile($source, '.git');
    my $base = File::Spec->catdir($builder->{workdir}, 'publication');
    make_path($base);
    my $self = bless {
        source => $source, base => $base, sequence => 0,
        mode => $args{mode} // 'auto',
    }, $class;
    return if $self->{mode} eq 'off';

    my ($status, $top) = $self->_git_at($builder, $source,
                                       'rev-parse', '--show-toplevel');
    return if $status || abs_path(_line($top)) ne $source;
    my $config = File::Spec->catfile($base, 'config.json');
    if (-f $config) {
        my $saved = _read_json($config);
        die "publication source changed for $base\n"
            unless $saved->{source} eq $source;
        @{$self}{qw(remote branch pr_url checkout)} =
            @{$saved}{qw(remote branch pr_url checkout)};
        $self->{mode} = $saved->{mode} // $self->{mode}
            if $self->{mode} eq 'auto';
        return $self;
    }

    my ($remote_status, $remote) = $self->_git_at($builder, $source,
        'config', '--get', 'branch.main.remote');
    my ($branch_status, $branch) = $self->_git_at($builder, $source,
        'config', '--get', 'branch.main.merge');
    die "ports main has no configured publication upstream\n"
        if $remote_status || $branch_status;
    $remote = _line($remote);
    $branch = _line($branch);
    die "invalid ports publication branch\n" unless $branch =~ s{\Arefs/heads/}{};
    my ($url_status, $url) = $self->_git_at($builder, $source,
        'remote', 'get-url', '--push', $remote);
    die "cannot identify ports publication remote\n" if $url_status;
    my ($ref_status, $ref) = $self->_git_at($builder, $source,
        'rev-parse', "refs/remotes/$remote/$branch");
    die "ports upstream is not available locally; fetch $remote first\n" if $ref_status;

    # An interrupted setup can leave a partial checkout. Give each new
    # setup its own directory and save its location only after it is ready.
    $self->{checkout} = tempdir('ports-XXXXXXXX', DIR => $base);
    $self->_must($builder, $source, 'git', 'clone', '--quiet', '--shared',
                '--no-checkout', $source, $self->{checkout});
    $self->_must_git($builder, 'remote', 'set-url', 'origin', _line($url));
    $self->_must_git($builder, 'checkout', '--quiet', '--detach', _line($ref));
    $self->_must_git($builder, 'update-ref',
        "refs/remotes/origin/$branch", _line($ref));
    for my $key (qw(user.name user.email)) {
        my ($code, $value) = $self->_git_at($builder, $source, 'config', '--get', $key);
        $self->_must_git($builder, 'config', $key, _line($value)) unless $code;
    }
    @{$self}{qw(remote branch)} = ('origin', $branch);
    $self->{initial_ref} = _line($ref);
    $self->_overlay($builder);
    $self->_save_config;
    return $self;
}

sub deferred ($class, $builder, $reason) {
    my $base = File::Spec->catdir($builder->{workdir}, 'publication');
    make_path($base);
    return bless { base => $base, setup_error => $reason }, $class;
}

sub registry ($self) {
    return XPerl::Installer::Registry->new(path => $self->{checkout});
}

sub enqueue ($self, $release, $receipt) {
    my $id = sha256_hex($release->{cpan_path} . "\0" . $receipt);
    my $pending = File::Spec->catdir($self->{base}, 'pending');
    make_path($pending);
    my $path = File::Spec->catfile($pending, "$id.json");
    my %identity = map { $_ => $release->{$_} }
        grep { exists $release->{$_} }
        qw(module distribution distribution_version cpan_path sha256);
    _write_json($path, { schema => 1, release => \%identity, receipt => $receipt });
    return $path;
}

sub complete ($self, $builder, $release, $receipt) {
    my $path = $self->enqueue($release, $receipt);
    return $self->_try_publish($builder, $path);
}

sub retry ($self, $builder) {
    my $directory = File::Spec->catdir($self->{base}, 'pending');
    return [] unless -d $directory;
    opendir my $entries, $directory or die "cannot read $directory: $!\n";
    my @paths = map { File::Spec->catfile($directory, $_) }
        sort grep { /\A[0-9a-f]+\.json\z/ } readdir $entries;
    closedir $entries or die "cannot close $directory: $!\n";
    return [map { $self->_try_publish($builder, $_) } @paths];
}

sub _try_publish ($self, $builder, $path) {
    my $queued = _read_json($path);
    my $result = eval {
        die $self->{setup_error} if $self->{setup_error};
        my $published = $self->_publish_one($builder, $path);
        _write_json(File::Spec->catfile(dirname($queued->{receipt}),
                                       'publication.json'), $published);
        $published;
    };
    return $result if $result;
    my $error = $@ || "publication did not complete\n";
    chomp $error;
    warn "ports publication pending for $queued->{release}{cpan_path}: $error\n";
    return { status => 'pending', reason => $error, queue => $path };
}

sub _save_config ($self) {
    _write_json(File::Spec->catfile($self->{base}, 'config.json'), {
        schema => 1, map { $_ => $self->{$_} }
            qw(source remote branch mode pr_url checkout),
    });
}

# Carry the caller's own registry work (e.g. a prepared repair) into the
# publication checkout. Local work is measured from the merge base with
# upstream, so a checkout that is merely older than upstream contributes
# nothing for files only upstream changed. A file both sides changed is
# merged when it is a status record and refused otherwise.
sub _overlay ($self, $builder) {
    my @scope = ('--', 'data', 'recipes', 'registry.json');
    my ($base_status, $base) = $self->_git_at($builder, $self->{source},
        'merge-base', 'HEAD', $self->{initial_ref});
    die "registry checkout shares no history with the ports upstream\n"
        if $base_status;
    $base = _line($base);
    my $changed = $self->_must($builder, $self->{source}, 'git',
        'diff', '--name-only', '--no-renames', '-z', $base, @scope);
    my $untracked = $self->_must($builder, $self->{source}, 'git',
        'ls-files', '--others', '--exclude-standard', '-z', @scope);
    my %upstream = map { $_ => 1 } grep { length } split /\0/,
        $self->_must($builder, $self->{source}, 'git', 'diff', '--name-only',
                     '--no-renames', '-z', $base, $self->{initial_ref}, @scope);
    my %seen;
    for my $relative (grep { length && !$seen{$_}++ }
                      split /\0/, $changed . $untracked) {
        my $from = File::Spec->catfile($self->{source}, $relative);
        my $to = File::Spec->catfile($self->{checkout}, $relative);
        die "cannot publish a symlink overlay: $relative\n" if -l $from;
        if ($upstream{$relative}) {
            next if _same_file($from, $to);
            die "registry overlay conflicts with newer upstream data: $relative; "
                . "update the registry checkout and retry\n"
                unless -f $from && -f $to && $relative =~ m{\Adata/.+/status\.json\z};
            _write_json($to, _merge_observations($relative,
                _read_json($to), _read_json($from)));
        }
        elsif (-f $from) {
            make_path(dirname($to));
            copy($from, $to) or die "cannot copy registry overlay $relative: $!\n";
        }
        elsif (-f $to) {
            unlink $to or die "cannot remove deleted overlay $relative: $!\n";
        }
    }
}

sub _same_file ($left, $right) {
    return !-e $left && !-e $right unless -f $left && -f $right;
    return File::Compare::compare($left, $right) == 0;
}

sub _publish_one ($self, $builder, $queue_path) {
    my $queued = _read_json($queue_path);
    my $release = $queued->{release};
    my $receipt = _read_json($queued->{receipt});
    die "repair registration needs retry before publication: "
        . "$receipt->{registration}{reason}\n"
        if ($receipt->{registration}{status} // '') eq 'failed';
    my $registry = $builder->{registry};
    my $root = $registry->{path};
    die "publication checkout does not match the builder registry\n"
        unless $root eq $self->{checkout};
    open my $lock, '>>', File::Spec->catfile($root, '.registration.lock')
        or die "cannot open publication lock: $!\n";
    flock($lock, LOCK_EX) or die "cannot lock publication: $!\n";
    $self->_refresh($builder);

    # The importer retains the existing semantic deduplication. A passing
    # build without a repair follows exactly the same publication path.
    my $importer = File::Spec->catfile($root, 'bin', 'import-receipts');
    $self->_must($builder, $root, $^X, $importer,
                '--receipt', $queued->{receipt}, '--record-only');
    my $directory = $registry->_distribution_directory($release);
    my $relative = File::Spec->abs2rel($directory, $root);
    my @paths = ($relative);
    my $index = File::Spec->catfile($directory, 'index.json');
    if (-f $index) {
        my $data = _read_json($index);
        my %seen;
        for my $entry (@{$data->{releases}}) {
            for my $set (@{$entry->{patch_sets}}) {
                for my $recipe (@{$set->{recipes} // []}) {
                    next if $seen{$recipe}++;
                    my $path = "recipes/$recipe.md";
                    push @paths, $path if -f File::Spec->catfile($root, $path);
                }
            }
        }
    }
    $self->_must_git($builder, 'add', '--', @paths);
    my ($changed) = $self->_git($builder, 'diff', '--cached', '--quiet',
                               'HEAD', '--', @paths);
    die "cannot inspect publication changes\n" if $changed > 1;
    if ($changed) {
        my $record = _read_json($queued->{receipt});
        my $suffix = ": record $record->{status} on $^V";
        my $name = $release->{distribution};
        $name = substr($name, 0, 69 - length($suffix)) . '...'
            if length($name . $suffix) > 72;
        my $subject = $name . $suffix;
        $self->_must($builder, $root, 'git-compose-commit',
            '--subject', $subject,
            '--text', "Record $release->{cpan_path} with its source and patch digests, "
                . 'test outcome, and interpreter build configuration.',
            '--', @paths);
    }
    my $ahead = $self->_must_git($builder, 'rev-list', '--count',
        "refs/remotes/$self->{remote}/$self->{branch}..HEAD");
    my $pushed = 0 + _line($ahead);
    if ($pushed && $self->{mode} ne 'pr') {
        $self->_push($builder);
    }
    my $batched = $pushed && $self->{mode} eq 'pr';
    if ($batched) {
        my $outgoing = File::Spec->catdir($self->{base}, 'outgoing');
        make_path($outgoing);
        my $record = _read_json($queued->{receipt});
        _write_json(File::Spec->catfile($outgoing,
            sha256_hex($release->{cpan_path}) . '.json'), {
                cpan_path => $release->{cpan_path}, status => $record->{status},
            });
    }
    unlink $queue_path or die "cannot clear publication queue $queue_path: $!\n";
    return { status => $batched ? 'batched' : $pushed ? 'pushed' : 'unchanged',
             distribution => $release->{distribution} };
}

sub _refresh ($self, $builder) {
    # Workers inherit their builder before forking. Reload the shared
    # permission decision and PR URL while holding the registration lock.
    my $saved = _read_json(File::Spec->catfile($self->{base}, 'config.json'));
    $self->{mode} = 'pr'
        if $self->{mode} eq 'auto' && ($saved->{mode} // '') eq 'pr';
    $self->{pr_url} //= $saved->{pr_url};
    my $tracking = "refs/remotes/$self->{remote}/$self->{branch}";
    $self->_must_git($builder, 'fetch', '--quiet', '--no-tags', $self->{remote},
                    "+refs/heads/$self->{branch}:$tracking");
    # Once a PR is public, append to its branch instead of rewriting its
    # commits. The reviewer can integrate newer upstream changes normally.
    return if $self->{mode} eq 'pr' && $self->{pr_url};
    my ($contained) = $self->_git($builder, 'merge-base', '--is-ancestor',
                                 $tracking, 'HEAD');
    return unless $contained;
    die "cannot compare ports publication history\n" if $contained > 1;
    $self->_rebase($builder, $tracking);
}

sub _push ($self, $builder) {
    for my $attempt (1 .. 3) {
        my ($status, $output) = $self->_git($builder, 'push', $self->{remote},
            "HEAD:refs/heads/$self->{branch}");
        return unless $status;
        if ($self->{mode} eq 'auto'
            && $output =~ /permission to .* denied|write access .*not granted|\b403\b|must .*pull request|protected branch.*(?:denied|not allowed)/i) {
            $self->{mode} = 'pr';
            $self->_save_config;
            warn "ports direct push is not permitted; retaining results for a batch PR\n";
            return;
        }
        die "ports push failed: $output\n"
            unless $output =~ /non-fast-forward|fetch first|remote contains work/i;
        $self->_refresh($builder);
    }
    die "ports remote kept advancing; publication remains queued\n";
}

sub finish ($self, $builder) {
    $self->_recover_receipts($builder);
    my $results = $self->retry($builder);
    return { status => 'pending', results => $results }
        if grep { $_->{status} eq 'pending' } @$results;
    my $summary = eval { $self->_summarize($builder); 1 };
    if (!$summary) {
        my $reason = $@ || "cannot summarize publication\n";
        chomp $reason;
        return { status => 'pending', reason => $reason };
    }
    return { status => 'pushed', results => $results }
        unless $self->{mode} eq 'pr';
    my $ahead = _line($self->_must_git($builder, 'rev-list', '--count',
        "refs/remotes/$self->{remote}/$self->{branch}..HEAD"));
    return { status => 'unchanged', mode => 'pr' }
        unless $ahead || $self->{pr_url};
    my $link = eval { $self->_pull_request($builder) };
    if (!$link) {
        my $reason = $@ || "cannot publish the contribution branch\n";
        chomp $reason;
        return { status => 'pending', mode => 'pr', reason => $reason };
    }
    $self->{pr_url} = $link;
    $self->_save_config;
    return { status => 'submitted', mode => 'pr', url => $link };
}

# A process can exit after writing its receipt but before saving the queue
# item. Recover that gap from immutable receipts without rebuilding anything.
sub _recover_receipts ($self, $builder) {
    File::Find::find({
        no_chdir => 1,
        wanted => sub {
            my $path = $File::Find::name;
            if (-d $path && $path eq $self->{base}) {
                $File::Find::prune = 1;
                return;
            }
            return unless -f $path && /(?:^|[\\\/])receipt\.json\z/;
            my $state = File::Spec->catfile(dirname($path), 'publication.json');
            if (-f $state) {
                my $saved = _read_json($state);
                return if ($saved->{status} // '') =~ /\A(?:pushed|unchanged|batched)\z/;
            }
            my $record = _read_json($path);
            return unless ($record->{status} // '') =~ /\A(?:installed|failed)\z/;
            $self->enqueue($record, $path);
        },
    }, $builder->{workdir});
}

sub _summarize ($self, $builder) {
    my $root = $self->{checkout};
    open my $lock, '>>', File::Spec->catfile($root, '.registration.lock')
        or die "cannot open publication lock: $!\n";
    flock($lock, LOCK_EX) or die "cannot lock publication: $!\n";
    $self->_refresh($builder);
    my $head = _line($self->_must_git($builder, 'rev-parse', 'HEAD'));
    my $snapshot = tempdir('summary-XXXXXXXX', DIR => $self->{base});
    $self->_must_git($builder, 'worktree', 'add', '--quiet', '--detach', $snapshot, $head);
    $self->_regenerate($builder, $snapshot);
    my $changed = $self->_must($builder, $snapshot, 'git',
                              'diff', '--name-only', '-z', 'HEAD');
    my @paths = grep { length } split /\0/, $changed;
    for my $path (@paths) {
        die "unexpected generated publication file: $path\n"
            unless $path =~ m{\A(?:data/.+/status\.json|status/(?:SUMMARY|UNRESOLVED|XS-PATCHES)\.(?:md|json))\z};
        my ($dirty) = $self->_git($builder, 'diff', '--quiet', 'HEAD', '--', $path);
        die "unpublished changes prevent summary refresh: $path\n" if $dirty;
        my $target = File::Spec->catfile($root, $path);
        make_path(dirname($target));
        copy(File::Spec->catfile($snapshot, $path), $target)
            or die "cannot refresh $path: $!\n";
    }
    $self->_must_git($builder, 'worktree', 'remove', '--force', $snapshot);
    if (@paths) {
        $self->_must($builder, $root, 'git-compose-commit',
            '--subject', 'Refresh ports build summaries and native patch catalog',
            '--text', 'Regenerate human indexes from the committed distribution records.',
            '--', @paths);
    }
    my $ahead = $self->_must_git($builder, 'rev-list', '--count',
        "refs/remotes/$self->{remote}/$self->{branch}..HEAD");
    $self->_push($builder) if _line($ahead) && $self->{mode} ne 'pr';
}

sub _regenerate ($self, $builder, $directory) {
    $self->_must($builder, $directory, $^X,
        File::Spec->catfile($directory, 'bin', 'import-receipts'), '--rebuild');
    my $native = File::Spec->catfile($directory, 'bin', 'build-xs-index');
    $self->_must($builder, $directory, $^X, $native) if -f $native;
}

sub _github_repository ($self, $builder) {
    my $url = _line($self->_must_git($builder, 'remote', 'get-url', $self->{remote}));
    my ($repository) = $url =~ m{github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?\z};
    die "batch PR publication needs a GitHub ports remote\n" unless $repository;
    return $repository;
}

sub _pull_request ($self, $builder) {
    my $root = $self->{checkout};
    my $repository = $self->_github_repository($builder);
    my $login = _line($self->_must($builder, $root, 'gh', 'api', 'user', '--jq', '.login'));
    my ($name) = $repository =~ m{/([^/]+)\z};
    my ($exists, $fork) = $self->_run($builder, $root, 'gh', 'api',
        "repos/$login/$name", '--jq', '.clone_url');
    if ($exists) {
        $fork = $self->_must($builder, $root, 'gh', 'api', '--method', 'POST',
            "repos/$repository/forks", '--jq', '.clone_url');
    }
    else {
        my $parent = _line($self->_must($builder, $root, 'gh', 'api',
            "repos/$login/$name", '--jq', '.parent.full_name // ""'));
        die "existing $login/$name is not a fork of $repository\n"
            unless $parent eq $repository;
    }
    my $branch = 'xperl/ports-' . substr(sha256_hex($self->{base}), 0, 12);
    $self->_must_git($builder, 'push', _line($fork), "HEAD:refs/heads/$branch");
    my $existing = _line($self->_must($builder, $root, 'gh', 'pr', 'list',
        '--repo', $repository, '--head', "$login:$branch", '--base', $self->{branch},
        '--json', 'url', '--jq', '.[0].url // ""'));
    return $existing if length $existing;
    my $body = File::Spec->catfile($self->{base}, 'pull-request.md');
    open my $file, '>', $body or die "cannot write $body: $!\n";
    print {$file} "Record XPerl build results and compatibility repairs.\n\n",
        "The commits preserve release/source identities, patch digests, ",
        "test outcomes and the interpreter build configurations.\n";
    my $outgoing = File::Spec->catdir($self->{base}, 'outgoing');
    if (-d $outgoing) {
        opendir my $entries, $outgoing or die "cannot read $outgoing: $!\n";
        my @names = sort grep { /\A[0-9a-f]+\.json\z/ } readdir $entries;
        closedir $entries or die "cannot close $outgoing: $!\n";
        print {$file} "\nCompleted distributions:\n\n";
        for my $name (@names) {
            my $record = _read_json(File::Spec->catfile($outgoing, $name));
            print {$file} "- $record->{cpan_path}: $record->{status}\n";
        }
    }
    close $file or die "cannot close $body: $!\n";
    return _line($self->_must($builder, $root, 'gh', 'pr', 'create',
        '--repo', $repository, '--head', "$login:$branch", '--base', $self->{branch},
        '--title', 'Record XPerl build results and compatibility repairs',
        '--body-file', $body));
}

# Rebase committed results in a clean, detached worktree. Other workers may
# have prepared files in the live registry; those never enter the rebase.
sub _rebase ($self, $builder, $tracking) {
    my $head = _line($self->_must_git($builder, 'rev-parse', 'HEAD'));
    my $retry = tempdir('rebase-XXXXXXXX', DIR => $self->{base});
    $self->_must_git($builder, 'worktree', 'add', '--quiet', '--detach', $retry, $head);
    my ($status, $output) = $self->_git_at($builder, $retry, 'rebase', $tracking);
    my $error;
    eval {
        for (1 .. 100) {
            last unless $status;
            my $conflicted = $self->_must($builder, $retry, 'git',
                'diff', '--name-only', '--diff-filter=U', '-z');
            my @paths = grep { length } split /\0/, $conflicted;
            die "ports rebase needs review in $retry: $output\n"
                unless @paths && !grep { !_generated_path($_) } @paths;
            for my $path (grep { m{\Adata/.+/status\.json\z} } @paths) {
                $self->_merge_status($builder, $retry, $path);
            }
            # Summaries derive from distribution records. Regenerate them
            # after merging records instead of choosing either host's copy.
            $self->_regenerate($builder, $retry)
                if grep { m{\Astatus/} } @paths;
            $self->_must($builder, $retry, 'git', 'add', '--', @paths);
            ($status, $output) = $self->_git_at($builder, $retry,
                '-c', 'core.editor=true', 'rebase', '--continue');
        }
        die "ports rebase did not finish in $retry\n" if $status;
        my $rebased = _line($self->_must($builder, $retry, 'git', 'rev-parse', 'HEAD'));

        # Protect all unpublished files, including staged additions. The
        # remaining paths can receive the newly published remote state.
        my $dirty = $self->_must_git($builder, 'diff', '--name-only', '-z', 'HEAD');
        my $untracked = $self->_must_git($builder, 'ls-files', '--others',
                                        '--exclude-standard', '-z');
        my %protected = map { $_ => 1 }
            grep { length } split /\0/, $dirty . $untracked;
        my $incoming = $self->_must_git($builder, 'diff', '--name-only', '-z',
                                       $head, $rebased);
        for my $path (grep { $protected{$_} } split /\0/, $incoming) {
            die "remote update overlaps an unpublished repair: $path; review $retry\n";
        }
        my @exclude = map { ":(top,literal,exclude)$_" } sort keys %protected;
        $self->_must_git($builder, 'reset', '--soft', $rebased);
        $self->_must_git($builder, 'restore', "--source=$rebased", '--staged',
                        '--worktree', '--', '.', @exclude);
        1;
    } or $error = $@ || "ports rebase failed\n";
    if ($error) {
        $self->_git_at($builder, $retry, 'rebase', '--abort');
        die $error;
    }
    $self->_must_git($builder, 'worktree', 'remove', $retry);
}

sub _generated_path ($path) {
    return $path =~ m{\A(?:data/.+/status\.json|status/(?:SUMMARY|UNRESOLVED|XS-PATCHES)\.(?:md|json))\z};
}

sub _merge_status ($self, $builder, $directory, $path) {
    my $left = $JSON->decode($self->_must($builder, $directory,
                                         'git', 'show', ":2:$path"));
    my $right = $JSON->decode($self->_must($builder, $directory,
                                          'git', 'show', ":3:$path"));
    _write_json(File::Spec->catfile($directory, $path),
                _merge_observations($path, $left, $right));
}

# Union two copies of a status record by observation id, keeping the first
# copy's order. Differing metadata or one id with two contents needs review.
sub _merge_observations ($path, $left, $right) {
    my (%left_meta, %right_meta);
    %left_meta = %$left;
    %right_meta = %$right;
    delete $left_meta{observations};
    delete $right_meta{observations};
    die "conflicting ports metadata needs review: $path\n"
        unless $JSON->encode(\%left_meta) eq $JSON->encode(\%right_meta)
            && ref($left->{observations}) eq 'ARRAY'
            && ref($right->{observations}) eq 'ARRAY';
    my (%seen, @observations);
    for my $observation (@{$left->{observations}}, @{$right->{observations}}) {
        my $id = $observation->{id} // die "status observation has no id: $path\n";
        if (exists $seen{$id}) {
            die "conflicting status observation needs review: $path\n"
                unless $seen{$id} eq $JSON->encode($observation);
            next;
        }
        $seen{$id} = $JSON->encode($observation);
        push @observations, $observation;
    }
    $left->{observations} = \@observations;
    return $left;
}

sub _git ($self, $builder, @args) {
    return $self->_git_at($builder, $self->{checkout}, @args);
}

sub _git_at ($self, $builder, $directory, @args) {
    return $self->_run($builder, $directory, 'git', @args);
}

sub _must_git ($self, $builder, @args) {
    return $self->_must($builder, $self->{checkout}, 'git', @args);
}

sub _must ($self, $builder, $directory, @command) {
    my ($status, $output) = $self->_run($builder, $directory, @command);
    die "$command[0] failed during publication: $output\n" if $status;
    return $output;
}

sub _run ($self, $builder, $directory, @command) {
    my $log = File::Spec->catfile($self->{base},
        "command-$$-" . ++$self->{sequence} . '.log');
    local $ENV{GIT_TERMINAL_PROMPT} = 0;
    my ($status, $timeout) = $builder->_run($directory, $log,
        { timeout => 120 }, @command);
    open my $file, '<', $log or die "cannot read publication log $log: $!\n";
    my $output = do { local $/; <$file> };
    close $file or die "cannot close publication log $log: $!\n";
    die "publication command timed out; see $log\n" if $timeout;
    return ($status, $output);
}

sub _line ($text) { $text =~ s/\s+\z//; return $text }

sub _read_json ($path) {
    open my $file, '<:raw', $path or die "cannot read $path: $!\n";
    my $data = $JSON->decode(do { local $/; <$file> });
    close $file or die "cannot close $path: $!\n";
    return $data;
}

sub _write_json ($path, $data) {
    my $temporary = "$path.tmp-$$";
    open my $file, '>:raw', $temporary or die "cannot write $temporary: $!\n";
    print {$file} $JSON->encode($data) or die "cannot write $path: $!\n";
    close $file or die "cannot close $path: $!\n";
    rename $temporary, $path or die "cannot save $path: $!\n";
}

1;

=head1 NAME

XPerl::Installer::Publication - publish completed CPAN build results

=head1 DESCRIPTION

Publication keeps an isolated ports checkout under the install work directory.
It imports each completed receipt, commits only that distribution and its
linked recipes, and pushes new facts to the configured upstream of ports
C<main>. Identical facts create no commit. Git mutations share the registry's
registration lock across build and repair workers.

C<auto> pushes directly and changes to batched GitHub fork pull requests on
an explicit permission refusal. C<direct> retains rejected pushes for retry.
C<pr> batches from the start. The Build object handles C<off> before setup.
Publication requires Git and C<git-compose-commit>; pull requests also need
an authenticated C<gh> command.

=head1 METHODS

=head2 prepare

Create or reopen publication state for a builder. Returns no publisher for
a registry that is not a Git checkout. The caller's checkout and index are
not mutated. The builder must use the publisher's C<registry> for subsequent
patch lookup and repair registration.
Uncommitted or branch-only registry changes in the caller's checkout are
carried into the publication checkout. Only changes since the merge base
with upstream count, so newer upstream data is never reverted; a status
record changed on both sides is merged by observation id, and any other
file changed on both sides is refused.

=head2 complete

Queue an immutable completed receipt and attempt to publish it. Returns a
separate publication status. Transport failures retain the queue and do not
change the build result.

=head2 finish

Recover receipts missed by an interrupted queue write, retry pending results,
and regenerate human summaries from committed records. In PR mode, push the
contribution branch to a fork and create or reuse its pull request. Resume
with the same work directory to retry without rebuilding completed releases.

=cut
