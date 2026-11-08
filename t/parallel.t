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
use Time::HiRes qw(sleep time);

# Parallel installation against a local CPAN mirror.

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
            map { my ($n, $v) = split />=/; ("Example::$n" => $v // 0) }
            @{$opt{requires} // []} } } },
    }));
    $tar->write(File::Spec->catfile($releases, "$dist.tar.gz"), 1);
    push @index, "$module 1.00 E/EX/EXAMPLE/$dist.tar.gz";
}

release('SlowA', sleep => 2);
release('SlowB', sleep => 2);
release('SlowRepair', sleep => 4);
release('Pair', requires => [qw(SlowA SlowB)]);
release('Base');
release('Left', requires => ['Base']);
release('Right', requires => ['Base']);
release('Top', requires => [qw(Left Right)]);
release('Bad', broken => 1);
release('BadTwo', broken => 1);
release('NeedsBad', requires => ['Bad']);
release('Fine');
release('Mixed', requires => [qw(NeedsBad Fine)]);
release('LoopA', requires => ['LoopB']);
release('LoopB', requires => ['LoopA']);
release('Loop', requires => ['LoopA']);
release('Late');
release('Dyn', dynamic => ['Example::Late']);
# Two dependents need different versions of one module; the scheduled
# release only satisfies the weaker requirement.
release('Ver');
release('VerLow', requires => ['Ver']);
release('VerAHigh', requires => ['Ver>=2']);    # resolved before VerLow
release('VerZHigh', requires => ['Ver>=2']);    # resolved after VerLow
release('VerTop', requires => [qw(VerAHigh VerLow VerZHigh)]);
# This is the only reference to Pinned. An impossible version must not leave
# its archive in the cache or schedule an orphan build.
release('Pinned');
release('PinnedOnlyHigh', requires => ['Pinned>=2']);
# Two modules from one release, required through different paths.
release('Twin', extra => ['Extra']);
release('ViaTwin', requires => ['Twin']);
release('ViaExtra', requires => ['Twin::Extra']);
release('Twins', requires => [qw(ViaTwin ViaExtra)]);

# A package declared in META provides that lives inside another module's
# file, so Module::Metadata cannot find it once installed.
{
    my $dist = 'Example-Multi-1.00';
    my $tar = Archive::Tar->new;
    $tar->add_data("$dist/Makefile.PL",
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Example::Multi', VERSION => '1.00');\n");
    $tar->add_data("$dist/lib/Example/Multi.pm",
        "package Example::Multi;\nour \$VERSION = '1.00';\n"
        . "package Example::Internal;\nsub value { 42 }\n1;\n");
    $tar->add_data("$dist/t/basic.t",
        "use Test::More tests => 1; use Example::Multi; is(Example::Internal::value(), 42);\n");
    $tar->add_data("$dist/META.json", JSON::PP->new->encode({
        'meta-spec' => { version => 2 }, name => 'Example-Multi', version => '1.00',
        abstract => 'fixture', author => ['XPerl'], license => ['perl_5'],
        generated_by => 'parallel.t', release_status => 'stable',
        dynamic_config => JSON::PP::false, prereqs => {},
        provides => {
            'Example::Multi' => { file => 'lib/Example/Multi.pm', version => '1.00' },
            'Example::Internal' => { file => 'lib/Example/Multi.pm' },
        },
    }));
    $tar->write(File::Spec->catfile($releases, "$dist.tar.gz"), 1);
    push @index, "Example::Multi 1.00 E/EX/EXAMPLE/$dist.tar.gz",
                 "Example::Internal undef E/EX/EXAMPLE/$dist.tar.gz";
}
release('UsesInternal', requires => ['Internal']);
release('UsesDynamicVersion', requires => ['DynamicVersion>=v1.20.0']);

my $index = "File: 02packages.details.txt\n\n" . join("\n", sort @index) . "\n";
gzip \$index => File::Spec->catfile($mirror, 'modules', '02packages.details.txt.gz')
    or die $GzipError;

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl-install');
my $run = 0;
sub install (@args) {
    ++$run;
    my $prefix = File::Spec->catdir($root, "prefix-$run");
    my $work = File::Spec->catdir($root, "work-$run");
    open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
        '--cache', $cache, '--prefix', $prefix, '--workdir', $work,
        @args or die $!;
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

# The default build pool runs independent releases at the same time.
my ($status, $result, $prefix, $work) = install('Example::Pair');
is($status, 0, 'default parallel install succeeds');
is($result->{status}, 'installed', 'requested module installed');
my $built = by_dist(receipts($work));
my ($ta, $tb) = map { phase($built->{$_}, 'test') } qw(SlowA SlowB);
ok($ta && $tb && $ta->{started} < $tb->{finished} && $tb->{started} < $ta->{finished},
   'independent test phases overlap by default');
ok(phase($built->{Pair}, 'configure')->{started}
       >= max(map { phase($built->{$_}, 'install')->{finished} } qw(SlowA SlowB)),
   'a release starts only after its prerequisites are installed');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Pair.pm)), 'module installed');

# An installed module may take its version from another package. Metadata
# cannot evaluate that declaration alone, so the installer loads the module
# in a child interpreter to check a versioned prerequisite.
my $dynamic_prefix = File::Spec->catdir($root, 'dynamic-version-prefix');
my $dynamic_lib = File::Spec->catdir($dynamic_prefix, qw(lib perl5 Example));
make_path($dynamic_lib);
for my $file (
    ['Shared.pm', "package Example::Shared; our \$VERSION = '1.25'; 1;\n"],
    ['DynamicVersion.pm', "package Example::DynamicVersion; use Example::Shared; use version; our \$VERSION = version->declare(\"\$Example::Shared::VERSION\"); 1;\n"],
) {
    open my $out, '>', File::Spec->catfile($dynamic_lib, $file->[0]) or die $!;
    print {$out} $file->[1];
    close $out or die $!;
}
for my $jobs (1, 2) {
    open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
        '--cache', $cache, '--prefix', $dynamic_prefix, '--jobs', $jobs,
        '--workdir', File::Spec->catdir($root, "dynamic-version-work-$jobs"),
        'Example::DynamicVersion' or die $!;
    my $output = do { local $/; <$pipe> };
    ok(close $pipe, "job count $jobs accepts an installed dynamic version");
    is(JSON::PP->new->decode($output)->{status}, 'installed',
       "job count $jobs skips the already installed module");

    open my $dependent, '-|', $^X, $script, 'install', '--mirror', $mirror,
        '--cache', $cache, '--prefix', $dynamic_prefix, '--jobs', $jobs,
        '--workdir', File::Spec->catdir($root, "dynamic-dependent-work-$jobs"),
        'Example::UsesDynamicVersion' or die $!;
    my $dependent_output = do { local $/; <$dependent> };
    ok(close $dependent, "job count $jobs accepts the runtime version");
    is(JSON::PP->new->decode($dependent_output)->{status}, 'installed',
       "job count $jobs installs the dependent");
}

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

# A release that cannot satisfy a stronger requirement is rejected before
# the dependent that needs it is built.
($status, $result, $prefix, $work) = install('Example::VerTop', '--jobs', 2);
isnt($status, 0, 'an unsatisfiable version requirement fails the install');
for my $strict (qw(VerAHigh VerZHigh)) {
    is(node($result, $strict)->{status}, 'failed',
       "$strict, which needs the higher version, fails");
    like(node($result, $strict)->{reason}, qr/Example::Ver\b.*2/,
         "${strict}'s failure names the module and the required version");
    ok(!grep({ $_->{cpan_path} =~ /Example-$strict-/ } receipts($work)),
       "$strict is not built");
}
is(node($result, 'VerLow')->{status}, 'installed',
   'a dependent satisfied by the release still installs');
is(node($result, 'VerTop')->{status}, 'blocked', 'their common dependent is blocked');

my $pinned_prefix = File::Spec->catdir($root, 'pinned-prefix');
my $pinned_lib = File::Spec->catdir($pinned_prefix, qw(lib perl5 Example));
make_path($pinned_lib);
open my $pinned_file, '>', File::Spec->catfile($pinned_lib, 'Pinned.pm') or die $!;
print {$pinned_file} "package Example::Pinned; our \$VERSION = '1.00'; 1;\n";
close $pinned_file or die $!;

# The installed and indexed versions are both too old for this pin. Neither
# worker path should fetch the same release or schedule an orphan build.
for my $jobs (1, 2) {
    ($status, $result, $prefix, $work) =
        install('Example::PinnedOnlyHigh', '--jobs', $jobs,
                '--prefix', $pinned_prefix);
    isnt($status, 0, "impossible indexed version fails with $jobs job(s)");
    like(node($result, 'PinnedOnlyHigh')->{reason}, qr/Example::Pinned\b.*2/,
         'the failure names the unsatisfied requirement') if $jobs > 1;
    ok(!-f File::Spec->catfile($cache, qw(authors id E EX EXAMPLE),
                              'Example-Pinned-1.00.tar.gz'),
       'the indexed release is not fetched');
    ok(!grep({ $_->{cpan_path} =~ /Example-Pinned-1\.00/ } receipts($work)),
       'the indexed release is not built');
    ok(!grep({ $_->{cpan_path} =~ /Example-Pinned-1\.00/ } @{$result->{nodes} // []}),
       'the indexed release is absent from the graph');
}

# A dependent of a package declared only in META provides is built once the
# release declaring it is installed.
($status, $result, $prefix, $work) = install('Example::UsesInternal', '--jobs', 2);
is($status, 0, 'a dependent of a provides-only package installs');
is(node($result, 'UsesInternal')->{status}, 'installed',
   'the provides-only package counts as installed');

# Several modules in one run: each is resolved once, shared prerequisites
# are built once, and one module's failure does not stop the others.
sub request ($result, $module) {
    my ($request) = grep { $_->{module} eq $module } @{$result->{modules} // []};
    return $request // {};
}
for my $jobs (2, 1) {
    ($status, $result, $prefix, $work) = install('Example::Fine', '--jobs', $jobs,
        'Example::Top', 'Example::Bad', 'Example::Missing', 'Example::Pair');
    isnt($status, 0, "a batch with failures exits non-zero ($jobs jobs)");
    is($result->{status}, 'failed', "batch status reports the failure ($jobs jobs)");
    is(request($result, $_)->{status}, 'installed', "$_ installs in a batch ($jobs jobs)")
        for qw(Example::Fine Example::Top Example::Pair);
    is(request($result, 'Example::Bad')->{status}, 'failed',
       "a broken module fails without stopping the batch ($jobs jobs)");
    like(request($result, 'Example::Missing')->{reason}, qr/not found/,
         "an unknown module is reported ($jobs jobs)");
}

# The same list from a file, with comments and blank lines.
my $list = File::Spec->catfile($root, 'modules.txt');
open my $list_file, '>', $list or die $!;
print {$list_file} "# modules to install\nExample::Fine\n\nExample::Top  \n";
close $list_file or die $!;
($status, $result) = install('--from', $list, '--jobs', 2);
is($status, 0, 'a module list from a file installs');
is_deeply([sort map { $_->{module} } @{$result->{modules}}],
          [qw(Example::Fine Example::Top)], 'comments and blank lines are ignored');

# --jobs 1 keeps the sequential path.
($status, $result) = install('Example::Top', '--jobs', 1);
is($status, 0, 'one job still installs');
ok(!exists $result->{nodes}, 'one job uses the sequential installer');

# A failed build moves to the repair pool. Its dependent waits while other
# builds and repairs continue, then runs when the repair installs.
my $agent = File::Spec->catfile($root, 'repair-agent');
open my $agent_file, '>', $agent or die $!;
print {$agent_file} "#!$^X\n";
print {$agent_file} <<'AGENT';
use strict;
use warnings;
use feature 'signatures';
use File::Spec;
use JSON::PP;
use Time::HiRes qw(time sleep);
my $request_path = shift @ARGV;
open my $input, '<', $request_path or die $!;
my $request = JSON::PP->new->decode(do { local $/; <$input> });
my ($name) = $request->{module} =~ /\AExample::(Bad\w*)\z/
    or die "unexpected repair module\n";
sub event ($kind) {
    open my $log, '>>', $ENV{XPERL_REPAIR_EVENTS} or die $!;
    flock $log, 2 or die $!;
    print {$log} "$name $kind ", time, "\n";
    close $log or die $!;
}
event('start');
sleep 2;
my $path = File::Spec->catfile($request->{source}, 'lib', 'Example', "$name.pm");
open my $source, '<', $path or die $!;
my $body = do { local $/; <$source> };
close $source or die $!;
$body =~ s/sub value \{ 0 \}/sub value { 42 }/
    or die "expected source not found\n";
open my $output, '>', $path or die $!;
print {$output} $body;
close $output or die $!;
event('end');
AGENT
close $agent_file or die $!;
chmod 0755, $agent or die $!;
my $events = File::Spec->catfile($root, 'repair-events');
local $ENV{XPERL_REPAIR_EVENTS} = $events;
($status, $result, $prefix, $work) = install(
    '--jobs', 4, '--repair-jobs', 2, '--repair-attempts', 1,
    '--repair-limit', 2, '--repair-interval', 0,
    '--repair-command', $agent,
    qw(Example::Bad Example::BadTwo Example::NeedsBad
       Example::Fine Example::SlowRepair));
is($status, 0, 'repairs unblock the batch');
is(request($result, $_)->{status}, 'installed', "$_ installs after repair")
    for qw(Example::Bad Example::BadTwo Example::NeedsBad
           Example::Fine Example::SlowRepair);
my $repaired = by_dist(grep { $_->{status} eq 'installed' } receipts($work));
ok(phase($repaired->{Bad}, 'repair') && phase($repaired->{BadTwo}, 'repair'),
   'both failures used the repair command');
open my $events_file, '<', $events or die $!;
my %times;
while (my $line = <$events_file>) {
    my ($name, $kind, $time) = split ' ', $line;
    $times{$name}{$kind} = $time;
}
ok($times{Bad}{start} < $times{BadTwo}{end}
       && $times{BadTwo}{start} < $times{Bad}{end},
   'two repair workers overlap');
my $slow_test = phase($repaired->{SlowRepair}, 'test');
ok($slow_test->{started} < $times{Bad}{end}
       && $times{Bad}{start} < $slow_test->{finished},
   'a build continues while another release is repaired');

# The default one-worker pool uses only the calls the run allows. Other
# failures remain visible after the budget is spent.
($status, $result) = install(
    '--jobs', 4, '--repair-attempts', 1, '--repair-limit', 1,
    '--repair-interval', 0, '--repair-command', $agent,
    qw(Example::Bad Example::BadTwo));
isnt($status, 0, 'the batch reports an unrepaired release');
my @limited = map { request($result, "Example::$_") } qw(Bad BadTwo);
is(scalar(grep { $_->{status} eq 'installed' } @limited), 1,
   'one failure is repaired with one call');
my ($unrepaired) = grep { $_->{status} eq 'failed' } @limited;
like($unrepaired->{reason}, qr/repair limit reached/,
     'the other failure reports the exhausted repair budget');

# A stop request drains the active build or repair and leaves the rest for
# resume. Wait for an observable phase rather than guessing startup timing.
sub stop_during ($label, $started, @options) {
    my $work = File::Spec->catdir($root, "$label-work");
    my $prefix = File::Spec->catdir($root, "$label-prefix");
    my $output = File::Spec->catfile($root, "$label.json");
    my $pid = fork;
    die "cannot fork: $!" unless defined $pid;
    if (!$pid) {
        open STDOUT, '>', $output or die $!;
        exec { $^X } $^X, $script, 'install', '--mirror', $mirror,
            '--cache', $cache, '--prefix', $prefix, '--workdir', $work,
            @options or die $!;
    }
    my $deadline = time + 30;
    my $ready;
    while (time < $deadline) {
        $ready = $started->($work);
        last if $ready;
        sleep 0.02;
    }
    ok($ready, "$label reaches the phase being stopped");
    is(system($^X, $script, 'stop', '--workdir', $work), 0,
       "$label accepts a stop request");
    waitpid $pid, 0;
    is($? >> 8, 2, "$label returns the stopped exit status");
    open my $input, '<', $output or die $!;
    my $result = JSON::PP->new->decode(do { local $/; <$input> });
    close $input or die $!;
    is($result->{status}, 'stopped', "$label reports a graceful stop");
    return ($result, $prefix, $work);
}

for my $jobs (1, 2) {
    my ($stopped, $prefix, $work) = stop_during("stop-build-$jobs", sub ($work) {
        my $found;
        find({ no_chdir => 1, wanted => sub {
            $found = 1 if /test-1\.log\z/;
        } }, $work) if -d $work;
        return $found;
    }, '--jobs', $jobs, 'Example::Pair');
    ok(!-f File::Spec->catfile($prefix, qw(lib perl5 Example Pair.pm)),
       'the dependent does not start after a stop request');
    my @completed = grep { $_->{status} eq 'installed' } receipts($work);
    ok(@completed, 'an active distribution finishes before shutdown');

    open my $pipe, '-|', $^X, $script, 'install', '--resume', '--workdir', $work
        or die $!;
    my $output = do { local $/; <$pipe> };
    ok(close $pipe, "the stopped $jobs-worker session resumes");
    is(JSON::PP->new->decode($output)->{status}, 'installed',
       'resume finishes the original request');
}

my $stop_events = File::Spec->catfile($root, 'stop-repair-events');
{
    local $ENV{XPERL_REPAIR_EVENTS} = $stop_events;
    my ($stopped, $prefix, $work) = stop_during('stop-repair', sub ($work) {
        return -s $stop_events;
    }, '--jobs', 2, '--repair-jobs', 1, '--repair-attempts', 1,
       '--repair-interval', 0, '--repair-command', $agent,
       qw(Example::Bad Example::BadTwo));
    my @repaired = grep { phase($_, 'repair') } receipts($work);
    is(scalar @repaired, 1, 'shutdown starts no second repair worker');
    is($repaired[0]{status}, 'installed', 'the active repair finishes and installs');
    open my $input, '<', $stop_events or die $!;
    my $events = do { local $/; <$input> };
    close $input or die $!;
    like($events, qr/ end /, 'the repair subprocess exits normally');
}

done_testing();
