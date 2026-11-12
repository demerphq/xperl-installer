use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Spec;
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;
use XPerl::Installer::Build;
use XPerl::Installer::Fetch;
use XPerl::Installer::Parallel;
use XPerl::Installer::Platform;
use XPerl::Installer::Registry;
use XPerl::Installer::Triage;

my $json = JSON::PP->new->canonical->pretty;
my $assessment = {
    schema => 1, disposition => 'upstream-broken',
    reason => 'The same configure defect occurs on ordinary Perl',
    references => [{ url => 'https://example.org/issues/42' }],
    baselines => [{
        implementation => 'perl', perl_version => 'v5.45.5',
        os => 'linux', archname => 'x86_64-linux', result => 'same-failure',
        build => { rc_stack => 0, useithreads => 0, usemultiplicity => 0,
                   debugging => 0, uselongdouble => 0, usequadmath => 0 },
    }],
};
is_deeply(XPerl::Installer::Triage->validate($assessment), $assessment,
          'ordinary Perl evidence retains exact version and build flags');

sub rejected ($report, $pattern, $name) {
    my $ok = eval { XPerl::Installer::Triage->validate($report); 1 };
    like($ok ? '' : $@, $pattern, $name);
}

rejected({ %$assessment, baselines => [] }, qr/matching ordinary Perl/,
         'a red matrix link alone cannot establish an upstream failure');
my $different = $json->decode($json->encode($assessment));
$different->{baselines}[0]{result} = 'different-failure';
rejected($different, qr/matching ordinary Perl/, 'a different control failure is insufficient');
my $missing = $json->decode($json->encode($assessment));
delete $missing->{baselines}[0]{build}{rc_stack};
rejected($missing, qr/missing boolean rc_stack/, 'unknown build flags cannot be guessed');
rejected({ %$assessment, reason => 'See /home/example/build/log' }, qr/portable/,
         'host paths cannot enter public triage');
rejected({ %$assessment, disposition => 'rc-stack' }, qr/disposition/,
         'known RC-stack defects are repairs, not deferrals');

my $root = abs_path(tempdir(CLEANUP => 1,
    DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
local @ENV{qw(TMPDIR TEMP TMP)} = ($root) x 3;

sub write_json ($path, $value) {
    open my $out, '>', $path or die $!;
    print {$out} $json->encode($value);
    close $out or die $!;
}

my $mirror = "$root/mirror";
my $releases = "$mirror/authors/id/E/EX/EXAMPLE";
make_path("$mirror/modules", $releases, "$root/registry");
write_json("$root/registry/registry.json", {
    schema => 2, active_repositories => 1,
    placement => 'siphash24-zero-jump-v1', fanout => 'siphash24-zero-first-byte-v1',
    repositories => [{ id => 0, path => '.' }],
});
my $dist = 'Example-Unsupported-1.00';
my $tar = Archive::Tar->new;
$tar->add_data("$dist/Makefile.PL", "die qq(Unsupported OS fixture\\n);\n");
$tar->write("$releases/$dist.tar.gz", 1);
my $index = "File: 02packages.details.txt\n\n"
    . "Example::Unsupported 1.00 E/EX/EXAMPLE/$dist.tar.gz\n";
gzip \$index => "$mirror/modules/02packages.details.txt.gz" or die $GzipError;

# A protocol deferral keeps its assessment in the result and receipt, and
# stops the repair budget after one call without inventing a source fix.
my $agent = "$root/agent";
open my $out, '>', $agent or die $!;
print {$out} "#!$^X\n";
print {$out} <<'AGENT';
use strict;
use warnings;
use JSON::PP;
open my $in, '<', $ARGV[0] or die $!;
my $request = JSON::PP->new->decode(do { local $/; <$in> });
close $in or die $!;
open my $out, '>', $request->{response_path} or die $!;
print {$out} JSON::PP->new->encode({
    schema => 1, status => 'deferred', triage => {
        schema => 1, disposition => 'unsupported-platform',
        reason => 'The fixture requires another operating system',
        references => [{ url => 'https://example.org/platforms' }], baselines => [],
    },
});
close $out or die $!;
AGENT
close $out or die $!;
chmod 0755, $agent or die $!;
my $registry = XPerl::Installer::Registry->new(path => "$root/registry");
my $fetcher = XPerl::Installer::Fetch->new(mirror => $mirror, cache => "$root/cache");

sub install ($work) {
    my $builder = XPerl::Installer::Build->new(
        prefix => "$root/prefix", workdir => $work, registry => $registry,
        repair_command => $agent, repair_interval => 0);
    return XPerl::Installer::Parallel->new(
        fetcher => $fetcher, builder => $builder, jobs => 1, repair_jobs => 1,
    )->run({ module => 'Example::Unsupported' });
}

my $result = install("$root/work");
my ($node) = @{$result->{nodes}};
is($node->{status}, 'failed', 'unsupported platform remains an honest failure');
is($node->{triage}{disposition}, 'unsupported-platform', 'batch result exposes triage');
open my $in, '<', $node->{receipt} or die $!;
my $receipt = $json->decode(do { local $/; <$in> });
close $in or die $!;
is(scalar(grep { $_->{name} eq 'repair' } @{$receipt->{phases}}), 1,
   'deferral stops repeated repair calls');

# Store the portable observation as the ports importer does. New patches,
# source bytes, builds or a later success must invalidate this deferral.
my $release = { %{$fetcher->fetch('Example::Unsupported')},
                distribution => 'Example-Unsupported', distribution_version => '1.00' };
my $directory = $registry->status_directory_for($release);
make_path($directory);
my $observation = {
    cpan_path => $release->{cpan_path}, source_sha256 => $release->{sha256},
    xperl_version => "$^V", platform => $receipt->{platform},
    status => 'failed', patch_sha256 => [], triage => $receipt->{triage},
};
my $record = { schema => 2, author => 'EXAMPLE', distribution => 'Example-Unsupported',
               observations => [$observation] };
write_json("$directory/status.json", $record);
is_deeply($registry->triage_for($release, $receipt->{platform}), $receipt->{triage},
          'the same source and build reuse the assessment');
ok(!$registry->triage_for({ %$release, sha256 => 'f' x 64 }, $receipt->{platform}),
   'a different source is reassessed');
ok(!$registry->triage_for($release, { %{$receipt->{platform}}, build_id => 'other' }),
   'a different interpreter build is reassessed');

$result = install("$root/retry");
($node) = @{$result->{nodes}};
ok(!defined($node->{receipt}), 'planning reuses deferral before configure or the agent runs');
is($node->{triage}{disposition}, 'unsupported-platform', 'reused assessment stays visible');

# Direct callers receive an ordinary failed receipt as well, without a
# configure or repair phase. Planning itself does not invent build evidence.
my $direct = XPerl::Installer::Build->new(
    prefix => "$root/prefix", workdir => "$root/direct", registry => $registry);
my $ok = eval { $direct->install($release); 1 };
like($ok ? '' : $@, qr/deferred \(unsupported-platform\)/,
     'direct builds honor the same assessment');

$observation->{patch_sha256} = ['a' x 64];
write_json("$directory/status.json", $record);
ok(!$registry->triage_for($release, $receipt->{platform}), 'changed patch set is reassessed');
$observation->{patch_sha256} = [];
push @{$record->{observations}}, { %$observation, status => 'installed' };
write_json("$directory/status.json", $record);
ok(!$registry->triage_for($release, $receipt->{platform}), 'a later success retires the deferral');

done_testing;
