use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Config;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;
use feature 'signatures';
use builtin qw(siphash_2_4);
no warnings 'experimental::builtin';

# A local CPAN mirror and a sharded ports registry describing recorded
# successes. Each fixture distribution is a tiny Makefile.PL release whose
# test checks value() == 42.

my $root = abs_path(tempdir(CLEANUP => 1,
                            DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $mirror = File::Spec->catdir($root, 'mirror');
my $registry = File::Spec->catdir($root, 'registry');
my $cache = File::Spec->catdir($root, 'cache');
my $json = JSON::PP->new->canonical->pretty;
make_path(File::Spec->catdir($mirror, 'modules'), $registry);

my %archive_sha;
sub release ($author, $dist, $version, %opt) {
    my $module = $opt{module} // do { (my $m = $dist) =~ s/-/::/g; "Example::$m" };
    my $name = "$dist-$version";
    my $tar = Archive::Tar->new;
    my $requires = $opt{requires} // {};
    $tar->add_data("$name/Makefile.PL",
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => '$module', VERSION => '$version');\n");
    (my $file = $module) =~ s{::}{/}g;
    my $value = $opt{value} // 42;
    $tar->add_data("$name/lib/$file.pm",
        "package $module;\nour \$VERSION = '$version';\nsub value { $value }\n1;\n");
    $tar->add_data("$name/t/basic.t",
        "use Test::More tests => 1; use $module; is($module\::value(), 42);\n");
    $tar->add_data("$name/META.json", JSON::PP->new->encode({
        'meta-spec' => { version => 2 }, name => $dist, version => $version,
        abstract => 'fixture', author => ['XPerl'], license => ['perl_5'],
        generated_by => 'ported.t', release_status => 'stable',
        dynamic_config => JSON::PP::false,
        prereqs => { runtime => { requires => $requires } },
    }));
    my ($a1, $a2) = (substr($author, 0, 1), substr($author, 0, 2));
    my $dir = File::Spec->catdir($mirror, 'authors', 'id', $a1, $a2, $author);
    make_path($dir);
    my $path = File::Spec->catfile($dir, "$name.tar.gz");
    $tar->write($path, 1);
    open my $in, '<:raw', $path or die $!;
    $archive_sha{"$a1/$a2/$author/$name.tar.gz"} =
        Digest::SHA->new(256)->addfile($in)->hexdigest;
    return ($module, "$a1/$a2/$author/$name.tar.gz");
}

sub placement ($author, $dist) {
    my $prefix = unpack 'H2', siphash_2_4(encode('UTF-8', "$author/$dist"), "\0" x 16);
    return File::Spec->catdir($registry, 'data', $prefix, $author, $dist);
}

sub write_json ($path, $data) {
    my ($volume, $dir) = File::Spec->splitpath($path);
    make_path(File::Spec->catpath($volume, $dir, ''));
    open my $out, '>', $path or die $!;
    print {$out} $json->encode($data);
    close $out or die $!;
}

my %status;
sub observe ($author, $dist, $module, $cpan_path, $version, %opt) {
    push @{$status{"$author/$dist"}{observations}}, {
        id => sha256_hex("$cpan_path $version " . ($opt{at} // '') . ($opt{status} // '')),
        observed_at => $opt{at} // '2026-11-01T00:00:00Z',
        module => $module, version => $version, cpan_path => $cpan_path,
        source_sha256 => $opt{sha} // $archive_sha{$cpan_path} // ('0' x 64),
        xperl_version => $opt{xperl} // "$^V",
        status => $opt{status} // 'installed',
        patch_set => $opt{patch_set}, patch_sha256 => [],
        phases => [],
    };
    $status{"$author/$dist"}{author} = $author;
    $status{"$author/$dist"}{distribution} = $dist;
}

my @index;
sub record ($author, $dist, $version, %opt) {
    my ($module, $path) = release($author, $dist, $version, %opt);
    observe($author, $dist, $module, $path, $version, %opt)
        unless $opt{unrecorded};
    push @index, "$module $version $path" if $opt{indexed} // 1;
    return ($module, $path);
}

# Base 1.00 is recorded; the CPAN index now points at a broken Base 1.10.
my ($base) = record('EXAMPLE', 'Base', '1.00', indexed => 0);
record('EXAMPLE', 'Base', '1.10', value => 0, unrecorded => 1);
record('EXAMPLE', 'App', '1.00', requires => { 'Example::Base' => '1.00' });
record('EXAMPLE', 'Tool', '1.00', requires => { 'Example::Base' => '0' });
# Same distribution name, two authors; only EXAMPLE's needs its patch.
record('EXAMPLE', 'Patched', '1.00', value => 0, patch_set => 'fix');
record('OTHER', 'Patched', '1.00', module => 'Other::Patched', indexed => 0);
record('EXAMPLE', 'Broken', '1.00', value => 0);
record('EXAMPLE', 'NeedsBroken', '1.00', requires => { 'Example::Broken' => '0' });
record('EXAMPLE', 'CycleA', '1.00', requires => { 'Example::CycleB' => '0' });
record('EXAMPLE', 'CycleB', '1.00', requires => { 'Example::CycleA' => '0' });
# The archive on the mirror no longer matches the recorded hash.
my (undef, $changed) = record('EXAMPLE', 'Changed', '1.00');
$status{'EXAMPLE/Changed'}{observations}[0]{source_sha256} = 'f' x 64;
# Recorded, but the archive has gone from the mirror.
observe('EXAMPLE', 'Gone', 'Example::Gone',
        'E/EX/EXAMPLE/Gone-1.00.tar.gz', '1.00');
# Two successful releases; the newer one later failed.
record('EXAMPLE', 'Multi', '1.00', indexed => 0);
record('EXAMPLE', 'Multi', '1.20', at => '2026-11-02T00:00:00Z');
observe('EXAMPLE', 'Multi', 'Example::Multi', 'E/EX/EXAMPLE/Multi-1.20.tar.gz',
        '1.20', status => 'failed', at => '2026-11-03T00:00:00Z');
# Never succeeded: not part of the batch.
record('EXAMPLE', 'NeverWorked', '1.00', status => 'failed');

my $index = "File: 02packages.details.txt\n\n" . join("\n", sort @index) . "\n";
gzip \$index => File::Spec->catfile($mirror, 'modules', '02packages.details.txt.gz')
    or die $GzipError;

write_json(File::Spec->catfile($registry, 'registry.json'), {
    schema => 2, active_repositories => 1,
    placement => 'siphash24-zero-jump-v1',
    fanout => 'siphash24-zero-first-byte-v1',
    repositories => [{ id => 0, path => '.' }],
});
for my $key (sort keys %status) {
    my $record = $status{$key};
    write_json(File::Spec->catfile(placement(@{$record}{qw(author distribution)}),
                                   'status.json'),
               { schema => 2, %$record });
}
# A record filed under the wrong shard is reported, not used.
write_json(File::Spec->catfile($registry, qw(data zz EXAMPLE Misplaced status.json)),
    { schema => 2, author => 'EXAMPLE', distribution => 'Misplaced',
      observations => [] });

# EXAMPLE/Patched carries a patch for the running XPerl.
my $patch = <<'PATCH';
--- a/lib/Example/Patched.pm
+++ b/lib/Example/Patched.pm
@@ -1,4 +1,4 @@
 package Example::Patched;
 our $VERSION = '1.00';
-sub value { 0 }
+sub value { 42 }
 1;
PATCH
my $patched_dir = placement('EXAMPLE', 'Patched');
make_path(File::Spec->catdir($patched_dir, 'patches'));
open my $patch_file, '>:raw', File::Spec->catfile($patched_dir, qw(patches fix.patch))
    or die $!;
print {$patch_file} $patch;
close $patch_file or die $!;
write_json(File::Spec->catfile($patched_dir, 'index.json'), {
    schema => 1, distribution => 'Patched',
    releases => [{
        version => '1.00', cpan_path => 'E/EX/EXAMPLE/Patched-1.00.tar.gz',
        source_sha256 => $archive_sha{'E/EX/EXAMPLE/Patched-1.00.tar.gz'},
        patch_sets => [{
            id => 'fix', xperl => { min_inclusive => "$^V", max_exclusive => 'v99.0.0' },
            patches => [{ path => 'patches/fix.patch', sha256 => sha256_hex($patch) }],
        }],
    }],
});

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl');
sub xperl (@arguments) {
    open my $pipe, '-|', $^X, $script, @arguments or die $!;
    my $output = do { local $/; <$pipe> };
    close $pipe;
    return ($? >> 8, $output);
}
sub common ($prefix, $workdir) {
    return ('--registry', $registry, '--mirror', $mirror, '--cache', $cache,
            '--prefix', $prefix, '--workdir', $workdir);
}
sub by_key ($report) { return { map { $_->{key} => $_ } @{$report->{entries}} } }
sub releases_built ($workdir) {
    opendir my $dir, $workdir or return 0;
    return scalar grep { /\Arelease-/ } readdir $dir;
}

# --- dry run -------------------------------------------------------------
my $prefix = File::Spec->catdir($root, 'prefix');
my $workdir = File::Spec->catdir($root, 'work');
my ($status, $output) = xperl('install-ported', common($prefix, $workdir),
                              '--dry-run', '--json');
is($status, 0, 'dry run succeeds');
my $plan = eval { JSON::PP->new->decode($output) } // {};
my $planned = by_key($plan);
is_deeply([sort keys %$planned],
          [sort((map { "EXAMPLE/$_" } qw(App Base Broken Changed CycleA CycleB
                                         Gone Multi NeedsBroken Patched Tool)),
                'OTHER/Patched')],
          'selects one release for every recorded success')
    or diag explain [sort keys %$planned];
ok(!$planned->{'EXAMPLE/NeverWorked'}, 'a distribution that never succeeded is not selected');
is($planned->{'EXAMPLE/Base'}{cpan_path}, 'E/EX/EXAMPLE/Base-1.00.tar.gz',
   'selects the recorded release, not the current CPAN release');
is($planned->{'EXAMPLE/Multi'}{version}, '1.20', 'selects the highest recorded success');
is($planned->{'EXAMPLE/Multi'}{recorded}{latest_status}, 'failed',
   'flags a recorded failure after the selected success');
is($planned->{'EXAMPLE/Patched'}{patch_set}, 'fix', 'plans the applicable patch set');
is(scalar(grep { $_->{path} =~ /Misplaced/ } @{$plan->{invalid}}), 1,
   'a misplaced status record is reported as invalid');
is(releases_built($workdir), 0, 'dry run builds nothing');
BAIL_OUT('selection is broken') unless %$planned;

# The other author's distribution is selected separately from EXAMPLE's.
($status, $output) = xperl('install-ported', common($prefix, $workdir),
                           '--dry-run', '--json', '--only', 'OTHER/Patched');
my $other_plan = by_key(eval { JSON::PP->new->decode($output) } // {});
is_deeply([keys %$other_plan], ['OTHER/Patched'], '--only selects one entry');
ok(!defined $other_plan->{'OTHER/Patched'}{patch_set},
   'another author\'s release does not use EXAMPLE\'s patch');

# --- full run ------------------------------------------------------------
($status, $output) = xperl('install-ported', common($prefix, $workdir), '--json');
isnt($status, 0, 'a run with failures exits non-zero');
my $report = eval { JSON::PP->new->decode($output) } // {};
my $entry = by_key($report);
is($entry->{'EXAMPLE/App'}{status}, 'installed', 'dependent installs');
is($entry->{'EXAMPLE/Tool'}{status}, 'installed', 'second dependent installs');
is($entry->{'EXAMPLE/Base'}{status}, 'satisfied',
   'a release built earlier as a dependency is not rebuilt');
my @base_receipts = grep {
    open my $in, '<', $_ or die $!;
    JSON::PP->new->decode(do { local $/; <$in> })->{cpan_path} =~ /Base-/
} glob File::Spec->catfile($workdir, 'release-*', 'receipt.json');
is(scalar @base_receipts, 1, 'the shared dependency was built once');
like(do { open my $in, '<', $base_receipts[0] or die $!; local $/; <$in> },
     qr{Base-1\.00\.tar\.gz}, 'the shared dependency used its recorded release');
is($entry->{'EXAMPLE/Patched'}{status}, 'installed', 'patched release installs');
is($entry->{'EXAMPLE/Patched'}{patch_set}, 'fix', 'report names the applied patch set');
is($entry->{'EXAMPLE/Broken'}{status}, 'failed', 'a broken release fails');
is($entry->{'EXAMPLE/Broken'}{failed_phase}, 'test', 'report names the failed phase');
ok(-f $entry->{'EXAMPLE/Broken'}{receipt}, 'failed release keeps its receipt');
like($entry->{'EXAMPLE/NeedsBroken'}{reason}, qr/dependency failed: .*Broken-1\.00/,
     'a dependent of a failed release fails without rebuilding it');
like($entry->{'EXAMPLE/CycleA'}{reason}, qr/dependency cycle/, 'cycle is reported');
like($entry->{'EXAMPLE/CycleB'}{reason}, qr/dependency cycle/,
     'both members of the cycle fail');
is($entry->{'EXAMPLE/Changed'}{status}, 'skipped', 'changed source is skipped');
like($entry->{'EXAMPLE/Changed'}{reason}, qr/source changed/, 'reason says source changed');
is($entry->{'EXAMPLE/Gone'}{status}, 'skipped', 'missing archive is skipped');
like($entry->{'EXAMPLE/Gone'}{reason}, qr/archive unavailable/,
     'reason says the archive is unavailable');
is($entry->{'EXAMPLE/Multi'}{status}, 'installed', 'the selected release installs');
is($entry->{'OTHER/Patched'}{status}, 'installed',
   'a same-named distribution from another author installs without the patch');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example App.pm)),
   'modules land in the validation prefix');
is($report->{platform}{key}, "$^O/$Config{archname}", 'report records the platform');
is($report->{xperl}{version}, "$^V", 'report records the XPerl version');
is($report->{counts}{installed}, 5, 'report counts installed entries');
is($report->{counts}{failed}, 4, 'report counts failed entries');
is($report->{counts}{skipped}, 2, 'report counts skipped entries');
for my $name (qw(report.json summary.txt state.json)) {
    ok(-f File::Spec->catfile($workdir, 'install-ported', $name), "$name written");
}

# --- resume --------------------------------------------------------------
($status) = xperl('install-ported', common($prefix, $workdir), '--json');
isnt($status, 0, 'a second run without --resume refuses the used work directory');
my $built_before = releases_built($workdir);
($status, $output) = xperl('install-ported', common($prefix, $workdir), '--json',
                           '--resume');
my $resumed = by_key(eval { JSON::PP->new->decode($output) } // {});
ok($resumed->{'EXAMPLE/App'}{resumed}, 'resume keeps an earlier success');
is($resumed->{'EXAMPLE/App'}{status}, 'installed', 'resumed success stays installed');
is($resumed->{'EXAMPLE/Broken'}{status}, 'failed', 'resume retries an earlier failure');
ok(!$resumed->{'EXAMPLE/Broken'}{resumed}, 'a failure is never carried over');
is(releases_built($workdir) - $built_before, 1,
   'resume rebuilt only the failed release');

# --- the other author, in a fresh prefix ----------------------------------
my $other_prefix = File::Spec->catdir($root, 'other-prefix');
my $other_work = File::Spec->catdir($root, 'other-work');
($status, $output) = xperl('install-ported', common($other_prefix, $other_work),
                           '--json', '--only', 'OTHER/Patched');
is($status, 0, 'a run with only successes exits zero');
my $other = by_key(eval { JSON::PP->new->decode($output) } // {});
is($other->{'OTHER/Patched'}{status}, 'installed', 'other author installs unpatched');
my $other_summary = do {
    open my $in, '<', File::Spec->catfile($other_work, qw(install-ported summary.txt))
        or die $!;
    local $/; <$in>;
};
like($other_summary, qr/^excluded: 11 entries/m,
     'the readable summary counts excluded entries');
unlike($other_summary, qr{EXAMPLE/App}, 'excluded entries are not listed one by one');

done_testing();
