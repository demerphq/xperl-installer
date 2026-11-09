use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd qw(abs_path getcwd);
use Archive::Tar;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;
use XPerl::Installer::Build;
use XPerl::Installer::Publication;
use XPerl::Installer::Registry;

plan skip_all => 'publication needs Git and git-compose-commit on PATH'
    unless !grep {
        my $command = $_;
        !grep { -x File::Spec->catfile($_, $command) } File::Spec->path;
    } qw(git git-compose-commit);

my $root = abs_path(tempdir(CLEANUP => 1,
    DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $source = "$root/source";
my $remote = "$root/remote.git";
make_path("$source/bin");
my $json = JSON::PP->new->canonical->pretty;

sub run ($directory, @command) {
    my $before = getcwd();
    chdir $directory or die $!;
    my $status = system @command;
    chdir $before or die $!;
    die "@command failed: $status\n" if $status;
}

sub capture ($directory, @command) {
    my $before = getcwd();
    chdir $directory or die $!;
    open my $pipe, '-|', @command or die $!;
    my $output = do { local $/; <$pipe> };
    my $ok = close $pipe;
    chdir $before or die $!;
    die "@command failed\n" unless $ok;
    chomp $output;
    return $output;
}

sub write_file ($path, $content) {
    open my $file, '>:raw', $path or die $!;
    print {$file} $content or die $!;
    close $file or die $!;
}

# This fixture importer isolates transport tests from observation handling.
# The ports repository tests the real importer's normalization and dedup.
write_file("$source/bin/import-receipts", <<'IMPORTER');
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use JSON::PP;
use File::Path qw(make_path);
use Digest::SHA qw(sha256_hex);
use XPerl::Installer::Registry;
my ($receipt, $record_only, $rebuild);
GetOptions('receipt=s' => \$receipt, 'record-only' => \$record_only,
           'rebuild' => \$rebuild) or die;
exit 0 if $rebuild;
die 'expected incremental import' unless $record_only && $receipt;
open my $file, '<', $receipt or die $!;
my $json = JSON::PP->new->canonical->pretty;
my $record = $json->decode(do { local $/; <$file> });
close $file or die $!;
my $registry = XPerl::Installer::Registry->new(path => '.');
my $dir = $registry->_distribution_directory($record);
make_path($dir);
my $path = "$dir/status.json";
my $data = { schema => 2, author => 'EXAMPLE',
             distribution => $record->{distribution}, observations => [] };
if (-f $path) {
    open my $old, '<', $path or die $!;
    $data = $json->decode(do { local $/; <$old> });
    close $old or die $!;
}
my $facts = { status => $record->{status}, platform => $record->{platform} };
my $id = sha256_hex($json->encode($facts));
push @{$data->{observations}}, { %$facts, id => $id }
    unless grep { $_->{id} eq $id } @{$data->{observations}};
open my $out, '>', "$dir/status.json" or die $!;
print {$out} $json->encode($data);
close $out or die $!;
IMPORTER
write_file("$source/registry.json", $json->encode({
    schema => 2, active_repositories => 1,
    placement => 'siphash24-zero-jump-v1',
    fanout => 'siphash24-zero-first-byte-v1',
    repositories => [{ id => 0, path => '.' }],
}));
write_file("$source/.gitignore", "/.registration.lock\n");

# No network, hosting account or AI calls: a local bare remote is enough
# to prove that each completed result reaches the configured destination.
run($root, 'git', 'init', '--quiet', '--bare', $remote);
run($source, 'git', 'init', '--quiet');
run($source, 'git', 'symbolic-ref', 'HEAD', 'refs/heads/main');
run($source, 'git', 'config', 'user.name', 'Publication fixture');
run($source, 'git', 'config', 'user.email', 'publication@example.invalid');
run($source, 'git', 'config', 'commit.gpgsign', 'false');
run($source, 'git', 'add', '.');
run($source, 'git-compose-commit', '--subject', 'Create publication fixture');
run($source, 'git', 'remote', 'add', 'ports', $remote);
run($source, 'git', 'push', '--quiet', '--set-upstream', 'ports', 'main');
my $original_head = capture($source, 'git', 'rev-parse', 'HEAD');

my $builder = XPerl::Installer::Build->new(
    prefix => "$root/prefix", workdir => "$root/work",
    registry => XPerl::Installer::Registry->new(path => $source),
);
my $publisher = XPerl::Installer::Publication->prepare($builder);
ok($publisher, 'a Git registry enables publication');
$builder->{registry} = $publisher->registry;
my $checkout = $builder->{registry}{path};
isnt($checkout, $source, 'publication owns an isolated checkout');

write_file("$source/unrelated.txt", "caller work\n");
run($source, 'git', 'add', 'unrelated.txt');
write_file("$checkout/unrelated.txt", "other queued work\n");
run($checkout, 'git', 'add', 'unrelated.txt');
my $release = {
    module => 'Example::Clean', distribution => 'Example-Clean',
    distribution_version => '1.00',
    cpan_path => 'E/EX/EXAMPLE/Example-Clean-1.00.tar.gz',
};
my $receipt = "$root/receipt.json";
write_file($receipt, $json->encode({ %$release, status => 'installed',
    platform => { build_id => 'fixture-build' } }));
my $result = $publisher->complete($builder, $release, $receipt);
is($result->{status}, 'pushed', 'a success without a patch is pushed immediately');
my $published_head = capture($root, 'git', '--git-dir', $remote,
                             'rev-parse', 'main');
isnt($published_head, $original_head, 'the remote has the completed build');
my $relative = File::Spec->abs2rel(
    $builder->{registry}->_distribution_directory($release), $checkout);
my $status = capture($root, 'git', '--git-dir', $remote,
                     'show', "main:$relative/status.json");
is($json->decode($status)->{observations}[0]{status}, 'installed',
   'no-patch success evidence is present');
is(capture($source, 'git', 'rev-parse', 'HEAD'), $original_head,
   'the caller checkout is untouched');
is(capture($source, 'git', 'diff', '--cached', '--name-only'), 'unrelated.txt',
   'the caller index is untouched');
is(capture($checkout, 'git', 'diff', '--cached', '--name-only'), 'unrelated.txt',
   'another queued file is not included in this commit');

$result = $publisher->complete($builder, $release, $receipt);
is($result->{status}, 'unchanged', 'identical facts create no new commit');
is(capture($root, 'git', '--git-dir', $remote, 'rev-parse', 'main'),
   $published_head, 'the remote revision stays unchanged');

# A failed push preserves its queue item and does not change build status.
write_file("$remote/hooks/pre-receive", "#!/bin/sh\nexit 1\n");
chmod 0755, "$remote/hooks/pre-receive" or die $!;
write_file($receipt, $json->encode({ %$release, status => 'failed',
    platform => { build_id => 'fixture-build' } }));
$result = $publisher->complete($builder, $release, $receipt);
is($result->{status}, 'pending', 'a push failure becomes pending publication');
ok(-f $result->{queue}, 'the completed receipt remains queued');
is(capture($root, 'git', '--git-dir', $remote, 'rev-parse', 'main'),
   $published_head, 'a rejected push does not change the remote');

unlink "$remote/hooks/pre-receive" or die $!;

# Another machine can publish a result while our push is queued. Both
# observations must survive a rebase that conflicts in the same JSON file.
my $peer = "$root/peer";
run($root, 'git', 'clone', '--quiet', '--branch', 'main', $remote, $peer);
run($peer, 'git', 'config', 'user.name', 'Peer fixture');
run($peer, 'git', 'config', 'user.email', 'peer@example.invalid');
run($peer, 'git', 'config', 'commit.gpgsign', 'false');
my $peer_status = $json->decode($status);
push @{$peer_status->{observations}}, {
    id => 'peer-result', status => 'installed',
    platform => { build_id => 'peer-build' },
};
write_file("$peer/$relative/status.json", $json->encode($peer_status));
run($peer, 'git-compose-commit', '--subject', 'Record peer platform',
    '--', "$relative/status.json");
run($peer, 'git', 'push', '--quiet', 'origin', 'main');
$result = $publisher->complete($builder, $release, $receipt);
is($result->{status}, 'pushed', 'a retry publishes the existing local commit');
my $merged = $json->decode(capture($root, 'git', '--git-dir', $remote,
                                  'show', "main:$relative/status.json"));
is(scalar @{$merged->{observations}}, 3,
   'the rebase preserves both platform results and our changed outcome');
ok(grep($_->{id} eq 'peer-result', @{$merged->{observations}}),
   'the peer observation survives publication');
is(capture($checkout, 'git', 'diff', '--cached', '--name-only'), 'unrelated.txt',
   'a concurrent push does not consume another queued file');

# A contributor without direct access batches commits locally and submits
# one PR. Stub only the hosting API; Git still pushes to a real local fork.
{
    package PublicationHostingFixture;
    use parent 'XPerl::Installer::Publication';

    sub _github_repository ($self, $builder) { return 'example/ports' }

    sub _git ($self, $builder, @command) {
        return (1, 'remote: Permission to example/ports denied to fixture-user')
            if $self->{deny_direct} && $command[0] eq 'push'
                && $command[1] eq 'origin';
        return $self->SUPER::_git($builder, @command);
    }

    sub _run ($self, $builder, $directory, @command) {
        return $self->SUPER::_run($builder, $directory, @command)
            unless $command[0] eq 'gh';
        push @{$self->{hosting_calls}}, [@command];
        return (0, "fixture-user\n") if $command[1] eq 'api' && $command[2] eq 'user';
        return (1, "not found\n") if $command[1] eq 'api'
            && $command[2] eq 'repos/fixture-user/ports';
        return (0, "$self->{fixture_fork}\n") if $command[1] eq 'api'
            && $command[2] eq '--method' && $command[3] eq 'POST';
        if ($command[1] eq 'pr' && $command[2] eq 'list') {
            return (0, $self->{fixture_pr} // '');
        }
        if ($command[1] eq 'pr' && $command[2] eq 'create') {
            $self->{fixture_pr} = 'https://github.com/example/ports/pull/1';
            return (0, $self->{fixture_pr});
        }
        die "unexpected hosting command: @command\n";
    }
}

my $fork = "$root/fork.git";
run($root, 'git', 'clone', '--quiet', '--bare', '--branch', 'main', $remote, $fork);
my $contributor = XPerl::Installer::Build->new(
    prefix => "$root/contributor-prefix", workdir => "$root/contributor-work",
    registry => XPerl::Installer::Registry->new(path => $source),
);
my $batch = PublicationHostingFixture->prepare($contributor, mode => 'pr');
$batch->{fixture_fork} = $fork;
$contributor->{registry} = $batch->registry;
my $before_batch = capture($root, 'git', '--git-dir', $remote, 'rev-parse', 'main');
write_file($receipt, $json->encode({ %$release, status => 'installed',
    platform => { build_id => 'contributor-build' } }));
$result = $batch->complete($contributor, $release, $receipt);
is($result->{status}, 'batched', 'PR mode accumulates a completed no-patch build');
is(capture($root, 'git', '--git-dir', $remote, 'rev-parse', 'main'), $before_batch,
   'PR mode does not push directly to upstream');
$result = $batch->finish($contributor);
is($result->{status}, 'submitted', 'the batch creates a pull request');
is($result->{url}, 'https://github.com/example/ports/pull/1',
   'the submitted PR URL is returned');
my $fork_refs = capture($root, 'git', '--git-dir', $fork,
                        'for-each-ref', '--format=%(refname)', 'refs/heads/xperl/');
like($fork_refs, qr{refs/heads/xperl/ports-[0-9a-f]+},
     'the contribution branch reaches the fork');
open my $body_file, '<', "$root/contributor-work/publication/pull-request.md" or die $!;
my $body = do { local $/; <$body_file> };
close $body_file or die $!;
like($body, qr/Example-Clean-1\.00\.tar\.gz: installed/,
     'the PR body lists completed distributions');
$result = $batch->finish($contributor);
is($result->{status}, 'submitted', 'finishing again reuses the PR');
is(scalar(grep { $_->[1] eq 'pr' && $_->[2] eq 'create' }
          @{$batch->{hosting_calls}}), 1, 'resume does not create a duplicate PR');

# Automatic mode changes to a batch only on a clear permission refusal.
# The rejected-hook case above deliberately stays queued in direct mode.
my $denied_builder = XPerl::Installer::Build->new(
    prefix => "$root/denied-prefix", workdir => "$root/denied-work",
    registry => XPerl::Installer::Registry->new(path => $source),
);
my $denied = PublicationHostingFixture->prepare($denied_builder);
$denied->{deny_direct} = 1;
$denied->{fixture_fork} = $fork;
$denied_builder->{registry} = $denied->registry;
write_file($receipt, $json->encode({ %$release, status => 'installed',
    platform => { build_id => 'denied-build' } }));
$result = $denied->complete($denied_builder, $release, $receipt);
is($result->{status}, 'batched', 'a permission refusal automatically selects a batch PR');
is($denied->{mode}, 'pr', 'the permission decision is retained for later results');
my $resumed;
{
    local $denied_builder->{registry} = XPerl::Installer::Registry->new(path => $source);
    $resumed = PublicationHostingFixture->prepare($denied_builder);
}
is($resumed->{mode}, 'pr', 'resume restores the automatic permission decision');
is($denied->finish($denied_builder)->{status}, 'submitted',
   'the automatically selected batch reaches a fork PR');

# Exercise the Build hook with a real distribution, rather than calling
# the publisher ourselves. Even a queue write error must preserve success.
my $archive = "$root/Example-Hook-1.00.tar.gz";
my $tar = Archive::Tar->new;
$tar->add_data('Example-Hook-1.00/Makefile.PL', <<'MAKEFILE');
use ExtUtils::MakeMaker;
WriteMakefile(NAME => 'Example::Hook', VERSION => '1.00');
MAKEFILE
$tar->add_data('Example-Hook-1.00/lib/Example/Hook.pm', <<'MODULE');
package Example::Hook;
our $VERSION = '1.00';
1;
MODULE
$tar->add_data('Example-Hook-1.00/t/basic.t', <<'TEST');
use Test::More tests => 1;
use Example::Hook;
is($Example::Hook::VERSION, '1.00', 'fixture module loads');
TEST
$tar->write($archive, 1) or die 'cannot write build fixture';
open my $archive_file, '<:raw', $archive or die $!;
my $digest = Digest::SHA->new(256)->addfile($archive_file)->hexdigest;
close $archive_file or die $!;
my $hook_release = {
    module => 'Example::Hook', version => '1.00',
    distribution => 'Example-Hook', distribution_version => '1.00',
    cpan_path => 'E/EX/EXAMPLE/Example-Hook-1.00.tar.gz',
    archive => $archive, sha256 => $digest,
};
my $hook_builder = XPerl::Installer::Build->new(
    prefix => "$root/hook-prefix", workdir => "$root/hook-work",
    registry => XPerl::Installer::Registry->new(path => $source),
    publish => 'auto',
);
my $built = $hook_builder->install($hook_release);
is($built->{status}, 'installed', 'the fixture completes all build phases');
is($built->{publication}{status}, 'pushed', 'Build publishes without a repair');
my $hook_directory = File::Spec->abs2rel(
    $hook_builder->{registry}->_distribution_directory($hook_release),
    $hook_builder->{registry}{path});
like(capture($root, 'git', '--git-dir', $remote, 'show',
             "main:$hook_directory/status.json"), qr/installed/,
     'the completed Build result is present upstream');

{
    no warnings 'redefine';
    local *XPerl::Installer::Publication::enqueue = sub { die "fixture queue unavailable\n" };
    $built = $hook_builder->install($hook_release);
}
is($built->{status}, 'installed', 'a queue error cannot turn a successful build into failure');
is($built->{publication}{status}, 'pending', 'the queue error is reported separately');
ok(-f $built->{receipt}, 'the completed receipt survives a queue write failure');
my $finished = $hook_builder->finish_publication;
is($finished->{publication}{status}, 'pushed', 'finish recovers an unqueued receipt');
my $recovered = XPerl::Installer::Publication::_read_json(
    File::Spec->catfile(dirname($built->{receipt}), 'publication.json'));
is($recovered->{status}, 'unchanged', 'recovery imports the receipt without rebuilding or duplicating facts');

done_testing();
