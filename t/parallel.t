use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Cwd qw(abs_path);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use List::Util qw(max);
use Test::More;

# Opt-in parallel installation (--jobs K) against a local CPAN mirror.

my $root = abs_path(tempdir(CLEANUP => 1,
                            DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $mirror = File::Spec->catdir($root, 'mirror');
my $cache = File::Spec->catdir($root, 'cache');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path(File::Spec->catdir($mirror, 'modules'), $releases);

my @index;
# Fixture release: value() returns 42 unless broken; the test optionally
# sleeps so overlapping work is observable. Static prerequisites go into
# META.json; dynamic ones only into Makefile.PL, so they appear in MYMETA.
sub release ($name, %opt) {
    my $module = "Example::$name";
    my $dist = "Example-$name-1.00";
    my $tar = Archive::Tar->new;
    my $dynamic = join ', ', map { "'$_' => 0" } @{$opt{dynamic} // []};
    $tar->add_data("$dist/Makefile.PL",
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => '$module', VERSION => '1.00',"
        . " PREREQ_PM => { $dynamic });\n");
    my $value = $opt{broken} ? 0 : 42;
    $tar->add_data("$dist/lib/Example/$name.pm",
        "package $module;\nour \$VERSION = '1.00';\nsub value { $value }\n1;\n");
    for my $extra (@{$opt{extra} // []}) {
        $tar->add_data("$dist/lib/Example/$name/$extra.pm",
            "package ${module}::$extra;\nour \$VERSION = '1.00';\n1;\n");
        push @index, "${module}::$extra 1.00 E/EX/EXAMPLE/$dist.tar.gz";
    }
    my $sleep = $opt{sleep} ? "sleep $opt{sleep};\n" : '';
    $tar->add_data("$dist/t/basic.t",
        "use Test::More tests => 1;\n${sleep}use $module;\nis($module\::value(), 42);\n");
    $tar->add_data("$dist/META.json", JSON::PP->new->encode({
        'meta-spec' => { version => 2 }, name => "Example-$name", version => '1.00',
        abstract => 'fixture', author => ['XPerl'], license => ['perl_5'],
        generated_by => 'parallel.t', release_status => 'stable',
        dynamic_config => $opt{dynamic} ? JSON::PP::true : JSON::PP::false,
        prereqs => { runtime => { requires => {
            map { ("Example::$_" => 0) } @{$opt{requires} // []} } } },
    }));
    $tar->write(File::Spec->catfile($releases, "$dist.tar.gz"), 1);
    push @index, "$module 1.00 E/EX/EXAMPLE/$dist.tar.gz";
}

release('SlowA', sleep => 2);
release('SlowB', sleep => 2);
release('Pair', requires => [qw(SlowA SlowB)]);
release('Base');
release('Left', requires => ['Base']);
release('Right', requires => ['Base']);
release('Top', requires => [qw(Left Right)]);
release('Bad', broken => 1);
release('NeedsBad', requires => ['Bad']);
release('Fine');
release('Mixed', requires => [qw(NeedsBad Fine)]);
release('LoopA', requires => ['LoopB']);
release('LoopB', requires => ['LoopA']);
release('Loop', requires => ['LoopA']);
release('Late');
release('Dyn', dynamic => ['Example::Late']);
# Two modules from one release, required through different paths.
release('Twin', extra => ['Extra']);
release('ViaTwin', requires => ['Twin']);
release('ViaExtra', requires => ['Twin::Extra']);
release('Twins', requires => [qw(ViaTwin ViaExtra)]);

my $index = "File: 02packages.details.txt\n\n" . join("\n", sort @index) . "\n";
gzip \$index => File::Spec->catfile($mirror, 'modules', '02packages.details.txt.gz')
    or die $GzipError;

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl');
my $run = 0;
sub install ($module, @extra) {
    ++$run;
    my $prefix = File::Spec->catdir($root, "prefix-$run");
    my $work = File::Spec->catdir($root, "work-$run");
    open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
        '--cache', $cache, '--prefix', $prefix, '--workdir', $work,
        @extra, $module or die $!;
    my $output = do { local $/; <$pipe> };
    close $pipe;
    my $status = $? >> 8;
    my $result = eval { JSON::PP->new->decode($output) } // {};
    return ($status, $result, $prefix, $work);
}
sub receipts ($work, $name = 'receipt.json') {
    my @found;
    find({ no_chdir => 1, wanted => sub {
        push @found, $File::Find::name if (File::Spec->splitpath($File::Find::name))[2] eq $name;
    } }, $work) if -d $work;
    return map {
        open my $in, '<', $_ or die $!;
        JSON::PP->new->decode(do { local $/; <$in> });
    } @found;
}
sub phase ($receipt, $name) {
    my ($phase) = grep { $_->{name} eq $name } @{$receipt->{phases}};
    return $phase;
}
sub by_dist (@receipts) {
    return { map { ($_->{cpan_path} =~ m{/Example-(\w+)-})[0] => $_ } @receipts };
}
sub node ($result, $name) {
    my ($node) = grep { $_->{cpan_path} =~ m{/Example-\Q$name\E-} } @{$result->{nodes} // []};
    return $node // {};
}

# Independent releases build at the same time.
my ($status, $result, $prefix, $work) = install('Example::Pair', '--jobs', 2);
is($status, 0, 'parallel install succeeds');
is($result->{status}, 'installed', 'requested module installed');
my $built = by_dist(receipts($work));
my ($ta, $tb) = map { phase($built->{$_}, 'test') } qw(SlowA SlowB);
ok($ta && $tb && $ta->{started} < $tb->{finished} && $tb->{started} < $ta->{finished},
   'independent test phases overlap with two jobs');
ok(phase($built->{Pair}, 'configure')->{started}
       >= max(map { phase($built->{$_}, 'install')->{finished} } qw(SlowA SlowB)),
   'a release starts only after its prerequisites are installed');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Pair.pm)), 'module installed');

# A shared prerequisite is built once.
($status, $result, $prefix, $work) = install('Example::Top', '--jobs', 3);
is($status, 0, 'diamond installs');
my @base = grep { $_->{cpan_path} =~ /Example-Base-/ } receipts($work);
is(scalar @base, 1, 'shared prerequisite built once');
$built = by_dist(receipts($work));
ok(phase($built->{Left}, 'configure')->{started} >= phase($built->{Base}, 'install')->{finished}
   && phase($built->{Right}, 'configure')->{started} >= phase($built->{Base}, 'install')->{finished},
   'both dependents wait for the shared prerequisite');

# A failure blocks only its descendants.
($status, $result, $prefix, $work) = install('Example::Mixed', '--jobs', 2);
isnt($status, 0, 'install with a failed prerequisite exits non-zero');
is($result->{status}, 'failed', 'requested module reported as failed');
is(node($result, 'Bad')->{status}, 'failed', 'the broken release fails');
ok(-f node($result, 'Bad')->{receipt}, 'the broken release keeps its receipt');
is(node($result, 'NeedsBad')->{status}, 'blocked', 'its dependent is blocked');
like(node($result, 'NeedsBad')->{reason}, qr/dependency failed: \S*Example-Bad-1\.00/,
     'the block names the failed release');
like(node($result, 'Mixed')->{reason}, qr/Example-Bad-1\.00/,
     'a transitive dependent names the root failure');
is(node($result, 'Fine')->{status}, 'installed', 'independent work still completes');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Fine.pm)),
   'independent release installed');

# Cycles fail their members without building them.
($status, $result) = install('Example::Loop', '--jobs', 2);
isnt($status, 0, 'cycle exits non-zero');
like(node($result, 'LoopA')->{reason}, qr/dependency cycle/, 'cycle member fails');
is(node($result, 'Loop')->{status}, 'blocked', 'a dependent of the cycle is blocked');

# A prerequisite known only after configure expands the graph.
($status, $result, $prefix, $work) = install('Example::Dyn', '--jobs', 2);
is($status, 0, 'configure-time prerequisite is resolved');
$built = by_dist(receipts($work));
ok($built->{Late} && $built->{Dyn}, 'both releases installed');
ok(phase($built->{Dyn}, 'configure')->{started} >= phase($built->{Late}, 'install')->{finished},
   'the release is rebuilt after its configure-time prerequisite');
my @deferred = receipts($work, 'deferred.json');
is(scalar @deferred, 1, 'the deferred attempt is recorded separately');
is($deferred[0]{status}, 'deferred', 'deferred attempt has its own status');
ok(!grep({ ($_->{status} // '') eq 'deferred' } receipts($work)),
   'no receipt.json carries a deferred status');

# Module names that resolve to one release share a single node.
($status, $result, $prefix, $work) = install('Example::Twins', '--jobs', 3);
is($status, 0, 'release providing two required modules installs');
is(scalar(grep { $_->{cpan_path} =~ /Example-Twin-1\.00/ } receipts($work)), 1,
   'a release required under two module names is built once');
is(scalar(grep { $_->{cpan_path} =~ /Example-Twin-1\.00/ } @{$result->{nodes}}), 1,
   'the graph has one node for the release');

# --jobs 1 keeps the sequential path.
($status, $result) = install('Example::Top', '--jobs', 1);
is($status, 0, 'one job still installs');
ok(!exists $result->{nodes}, 'one job uses the sequential installer');

done_testing();
