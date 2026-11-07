package XPerl::Installer::Registry;

use strict;
use warnings;
use feature 'signatures';
use Cwd qw(abs_path);
use Digest::SHA;
use Encode qw(encode);
use Fcntl qw(:flock);
use File::Basename ();
use File::Copy qw(copy);
use File::Find ();
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP;
use POSIX qw(strftime);
use version;
use builtin qw(jumphash_string siphash_2_4);
no warnings 'experimental::builtin';

sub new ($class, %args) {
    die "registry directory is required\n" unless $args{path} && -d $args{path};
    my $root = abs_path($args{path});
    my $config_path = File::Spec->catfile($root, 'registry.json');
    my $self = bless { path => $root }, $class;
    return $self unless -f $config_path;

    open my $input, '<:raw', $config_path
        or die "cannot read $config_path: $!\n";
    my $config = JSON::PP->new->decode(do { local $/; <$input> });
    my $count = $config->{active_repositories};
    die "unsupported registry configuration in $config_path\n"
        unless $config->{schema} == 2
            && $config->{placement} eq 'siphash24-zero-jump-v1'
            && $config->{fanout} eq 'siphash24-zero-first-byte-v1'
            && defined($count) && $count =~ /\A[1-8]\z/
            && ref($config->{repositories}) eq 'ARRAY'
            && @{$config->{repositories}} == $count;
    my @repositories;
    for my $id (0 .. $count - 1) {
        my $entry = $config->{repositories}[$id];
        die "invalid repository $id in $config_path\n"
            unless ref($entry) eq 'HASH'
                && defined($entry->{id}) && $entry->{id} == $id
                && defined($entry->{path}) && length($entry->{path})
                && !File::Spec->file_name_is_absolute($entry->{path});
        my $path = abs_path(File::Spec->catdir($root, $entry->{path}));
        die "repository $id is unavailable: $entry->{path}\n"
            unless defined($path) && -d $path;
        $repositories[$id] = $path;
    }
    die "repository 0 must be the bootstrap checkout\n"
        unless $repositories[0] eq $root;
    $self->{repositories} = \@repositories;
    return $self;
}

sub patches_for ($self, $release) {
    my $distribution = $release->{distribution};
    die "invalid distribution name\n"
        unless defined $distribution && $distribution =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/;
    my $base = $self->_distribution_directory($release);
    my $index = File::Spec->catfile($base, 'index.json');
    return { patches => [] } unless -f $index;
    open my $input, '<:raw', $index or die "cannot read $index: $!\n";
    my $json = do { local $/; <$input> };
    my $data = JSON::PP->new->decode($json);
    die "unsupported registry schema in $index\n"
        unless $data->{schema} == 1 && $data->{distribution} eq $distribution;
    my @releases = grep {
        $_->{version} eq $release->{distribution_version}
            && $_->{cpan_path} eq $release->{cpan_path}
    } @{$data->{releases}};
    die "duplicate registry release for $distribution\n" if @releases > 1;
    return { patches => [], index_sha256 => Digest::SHA::sha256_hex($json) }
        unless @releases;
    my $entry = $releases[0];
    die "registry source digest mismatch for $distribution\n"
        unless $entry->{source_sha256} eq $release->{sha256};
    my $running = version->parse("$^V");
    my @sets = grep {
        $running >= version->parse($_->{xperl}{min_inclusive})
            && $running < version->parse($_->{xperl}{max_exclusive})
    } @{$entry->{patch_sets}};
    die "ambiguous registry patch sets for $distribution\n" if @sets > 1;
    return { patches => [], index_sha256 => Digest::SHA::sha256_hex($json) }
        unless @sets;
    my $set = $sets[0];
    my $purpose = $set->{purpose} // 'compatibility';
    die "invalid registry patch purpose: $purpose\n"
        unless $purpose eq 'compatibility' || $purpose eq 'security';
    my $advisories = $set->{advisories} // [];
    die "security patch set needs an advisory\n"
        if $purpose eq 'security' && ref($advisories) ne 'ARRAY';
    die "security patch set needs an advisory\n"
        if $purpose eq 'security' && !@$advisories;
    my @patches;
    for my $patch (@{$set->{patches}}) {
        my $relative = $patch->{path};
        die "invalid registry patch path: $relative\n"
            unless $relative =~ m{\Apatches/[A-Za-z0-9_.-]+\.patch\z};
        my $path = File::Spec->catfile($base, split m{/}, $relative);
        my $real = abs_path($path);
        my $patch_base = abs_path(File::Spec->catdir($base, 'patches'));
        die "patch escapes registry: $relative\n"
            unless defined $real && defined $patch_base
                && index($real, "$patch_base/") == 0;
        open my $file, '<:raw', $real or die "cannot read $real: $!\n";
        my $digest = Digest::SHA->new(256)->addfile($file)->hexdigest;
        die "patch digest mismatch: $relative\n"
            unless $digest eq $patch->{sha256};
        push @patches, { path => $real, sha256 => $digest };
    }
    my @recipes;
    for my $id (@{$set->{recipes} // []}) {
        die "invalid registry recipe id: $id\n"
            unless $id =~ /\A[A-Za-z0-9_.-]+\z/;
        my $path = File::Spec->catfile($self->{path}, 'recipes', "$id.md");
        my $real = abs_path($path);
        my $base = File::Spec->catdir($self->{path}, 'recipes');
        die "recipe escapes registry: $id\n"
            unless defined $real && index($real, "$base/") == 0;
        push @recipes, { id => $id, path => $real };
    }
    return {
        patch_set => $set->{id},
        purpose => $purpose,
        advisories => $advisories,
        index_sha256 => Digest::SHA::sha256_hex($json),
        patches => \@patches,
        recipes => \@recipes,
    };
}

sub _distribution_directory ($self, $release) {
    my $distribution = $release->{distribution};
    return File::Spec->catdir($self->{path}, 'distributions', $distribution)
        unless $self->{repositories};
    return $self->directory_for(author_from_path($release->{cpan_path}),
                                $distribution);
}

sub author_from_path ($cpan_path) {
    $cpan_path //= '';
    my ($initial, $pair, $author) =
        $cpan_path =~ m{\A([A-Z])/([A-Z]{2})/([A-Z0-9_-]+)/(?:[^/]+/)*[^/]+\z};
    die "invalid CPAN author path: $cpan_path\n"
        unless defined($author)
            && substr($author, 0, 1) eq $initial
            && substr($author, 0, 2) eq $pair;
    return $author;
}

# The registry directory for one CPAN author and distribution under the
# configured placement: jump consistent hash selects the repository and the
# first SipHash byte selects the shard prefix.
sub directory_for ($self, $author, $distribution) {
    die "registry has no sharded layout\n" unless $self->{repositories};
    die "invalid CPAN author: $author\n"
        unless defined($author) && $author =~ /\A[A-Z0-9_-]+\z/;
    die "invalid distribution name: $distribution\n"
        unless defined($distribution)
            && $distribution =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/;
    my $key = encode('UTF-8', "$author/$distribution");
    my $repository = jumphash_string($key, scalar @{$self->{repositories}});
    my $prefix = unpack 'H2', siphash_2_4($key, "\0" x 16);
    return File::Spec->catdir($self->{repositories}[$repository], 'data',
                              $prefix, $author, $distribution);
}

# A successful repair becomes a patch against the original CPAN archive.
# Lock the registry while changing its index so concurrent build workers do
# not overwrite one another's release entries.
sub register_repair ($self, $release, $record) {
    my $proposal = $record->{proposal} // die "repair has no patch proposal\n";
    die "repair was not installed\n"
        unless ($record->{status} // '') eq 'installed';
    die "repair patch is empty\n" unless @{$proposal->{files} // []};
    for my $name (qw(test proposal-check install)) {
        die "repair lacks a passing $name phase\n"
            unless grep { $_->{name} eq $name && !$_->{exit_status} }
                        @{$record->{phases} // []};
    }

    my $distribution = $release->{distribution};
    my $version = $release->{distribution_version};
    die "invalid distribution version\n"
        unless defined($version) && $version =~ /\A[A-Za-z0-9_.-]+\z/;
    my $author = author_from_path($release->{cpan_path});
    my $source_sha = $release->{sha256};
    die "invalid source digest\n"
        unless $source_sha =~ /\A[0-9a-f]{64}\z/;
    my $xperl = $record->{xperl_version};
    my ($major, $minor, $micro) = $xperl =~ /\Av(\d+)\.(\d+)\.(\d+)\z/;
    die "invalid XPerl version\n" unless defined $micro;

    my $patch = _read_file($proposal->{path});
    my $digest = Digest::SHA::sha256_hex($patch);
    die "repair patch digest mismatch\n"
        unless $digest eq ($proposal->{sha256} // '');
    die "repair patch includes a local home path\n"
        if $patch =~ m{/(?:home|Users)/[^/\s]+/};

    my @recipes;
    push @recipes, 'hash-entry-traversal-v1'
        if $patch =~ /HvENTRY_(?:FIRST|NEXT|LIMIT)/;
    push @recipes, 'hash-size-accounting-v1'
        if $patch =~ /Hv(?:LINEAR_CAP|OA_INDEX|IS_LINEAR)/;
    push @recipes, 'hash-shared-string-table-v1'
        if $patch =~ /HvSTR(?:SLOTS|_TOMBSTONE|_REFCOUNT)/;
    push @recipes, 'hash-metadata-manipulation-v1'
        if $patch =~ /HvMAX_RAW/;
    push @recipes, 'regex-internals-v1'
        if $patch =~ /RX_(?:NPARENS|OFFS_START|OFFS_END)/;
    my @linked = grep {
        -f File::Spec->catfile($self->{path}, 'recipes', "$_.md")
    } @recipes;

    my $base = $self->_distribution_directory($release);
    my $lock_path = File::Spec->catfile($self->{path}, '.registration.lock');
    open my $lock, '>>', $lock_path
        or die "cannot lock registry $lock_path: $!\n";
    flock($lock, LOCK_EX) or die "cannot lock registry: $!\n";

    my $index_path = File::Spec->catfile($base, 'index.json');
    my $index = -f $index_path ? _read_json($index_path)
        : { schema => 1, distribution => $distribution, releases => [] };
    die "registry index identifies another distribution\n"
        unless $index->{schema} == 1
            && $index->{distribution} eq $distribution;
    my @entries = grep { $_->{cpan_path} eq $release->{cpan_path} }
                  @{$index->{releases}};
    die "duplicate registry release\n" if @entries > 1;
    my $entry = $entries[0];
    if ($entry) {
        die "registry release digest differs\n"
            unless $entry->{source_sha256} eq $source_sha
                && $entry->{version} eq $version;
    }
    else {
        $entry = {
            version => $version,
            cpan_path => $release->{cpan_path},
            source_sha256 => $source_sha,
            patch_sets => [],
        };
        push @{$index->{releases}}, $entry;
    }

    my $running = version->parse($xperl);
    my @active = grep {
        $running >= version->parse($_->{xperl}{min_inclusive})
            && $running < version->parse($_->{xperl}{max_exclusive})
    } @{$entry->{patch_sets}};
    die "ambiguous patch sets for repaired release\n" if @active > 1;
    my $set = $active[0];
    if (!$set) {
        $set = {
            id => "repair-$xperl",
            purpose => 'compatibility',
            xperl => {
                min_inclusive => $xperl,
                max_exclusive => "v$major." . ($minor + 1) . '.0',
            },
            recipes => \@linked,
        };
        push @{$entry->{patch_sets}}, $set;
    }
    my %seen;
    $set->{recipes} = [grep { !$seen{$_}++ }
                       @{$set->{recipes} // []}, @linked];

    my $stem = "repair-$xperl-$version-" . substr($digest, 0, 12);
    my $relative = "patches/$stem.patch";
    my $patch_dir = File::Spec->catdir($base, 'patches');
    my $evidence_dir = File::Spec->catdir($base, 'evidence');
    make_path($patch_dir, $evidence_dir);
    my $target = File::Spec->catfile($patch_dir, "$stem.patch");
    if (-f $target) {
        die "registered patch differs from proposal\n"
            unless Digest::SHA::sha256_hex(_read_file($target)) eq $digest;
    }
    else {
        copy($proposal->{path}, $target)
            or die "cannot copy repair patch: $!\n";
    }
    $set->{patches} = [{ path => $relative, sha256 => $digest }];

    # Evidence keeps only portable release and test facts. Build commands,
    # logs and prefixes in a receipt contain machine-local paths.
    my %platform = %{$record->{platform} // {}};
    $platform{cc} = File::Basename::basename($platform{cc})
        if defined $platform{cc};
    $platform{make} = File::Basename::basename($platform{make})
        if defined $platform{make};
    my $evidence = {
        date => strftime('%Y-%m-%d', gmtime),
        source_sha256 => $source_sha,
        patch_set_id => $set->{id},
        patch_sha256 => $digest,
        xperl_version => $xperl,
        platform => \%platform,
        files => $proposal->{files},
        recipe_candidates => \@recipes,
        tests => [map { { phase => $_, result => 'pass' } }
                      qw(test proposal-check install)],
    };
    my $evidence_path = File::Spec->catfile($evidence_dir, "$stem.json");
    _write_json($evidence_path, $evidence);
    _write_json($index_path, $index);
    close $lock;
    return { patch_set => $set->{id}, patch_sha256 => $digest,
             index => $index_path, evidence => $evidence_path };
}

sub _read_file ($path) {
    open my $input, '<:raw', $path or die "cannot read $path: $!\n";
    return do { local $/; <$input> };
}

sub _read_json ($path) {
    return JSON::PP->new->decode(_read_file($path));
}

sub _write_json ($path, $data) {
    my ($out, $temporary) = tempfile('.index-XXXXXXXX',
        DIR => File::Basename::dirname($path), UNLINK => 0);
    print {$out} JSON::PP->new->canonical->pretty->encode($data);
    close $out or die "cannot close $temporary: $!\n";
    rename $temporary, $path or die "cannot replace $path: $!\n";
}

# Every build status record in every configured repository. A record is
# accepted only where the placement rules would put it; anything else is
# returned as invalid with a reason rather than guessed at.
sub status_records ($self) {
    die "batch status records require a registry.json layout\n"
        unless $self->{repositories};
    my (@records, @invalid, %seen);
    for my $repository (@{$self->{repositories}}) {
        my $data = File::Spec->catdir($repository, 'data');
        next unless -d $data;
        my @paths;
        File::Find::find({
            no_chdir => 1,
            wanted => sub {
                push @paths, $File::Find::name
                    if -f $File::Find::name
                        && File::Basename::basename($File::Find::name)
                            eq 'status.json';
            },
        }, $data);
        for my $path (sort @paths) {
            my $record = eval {
                open my $input, '<:raw', $path or die "cannot read: $!\n";
                my $status = JSON::PP->new->decode(do { local $/; <$input> });
                die "unsupported status schema\n"
                    unless ref($status) eq 'HASH'
                        && ($status->{schema} // 0) == 2
                        && ref($status->{observations}) eq 'ARRAY';
                my $expected = File::Spec->catfile(
                    $self->directory_for($status->{author},
                                         $status->{distribution}),
                    'status.json');
                # abs_path is undefined for a placement that does not exist.
                my $placed = abs_path($expected);
                die "record is not at its placement ($expected)\n"
                    unless defined $placed && abs_path($path) eq $placed;
                my $key = "$status->{author}/$status->{distribution}";
                die "duplicate status record for $key\n" if $seen{$key}++;
                { key => $key, path => abs_path($path), %$status };
            };
            if ($record) { push @records, $record }
            else {
                chomp(my $reason = $@);
                push @invalid, { path => $path, reason => $reason };
            }
        }
    }
    return { records => \@records, invalid => \@invalid };
}

# The git revision of the registry checkout, when it is one. Missing git
# or a non-checkout registry is reported as undefined, not as an error.
sub revision ($self) {
    my $root = $self->{path};
    return {} unless -e File::Spec->catfile($root, '.git');
    my $head = _git($root, 'rev-parse', 'HEAD');
    return {} unless defined $head;
    my $status = _git($root, 'status', '--porcelain', '--untracked-files=no');
    return { commit => $head, dirty => length($status // '') ? 1 : 0 };
}

sub _git ($root, @arguments) {
    open my $pipe, '-|', 'git', '-C', $root, @arguments or return;
    my $output = do { local $/; <$pipe> };
    close $pipe or return;
    chomp $output if defined $output;
    return $output;
}

1;
