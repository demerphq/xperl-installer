use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;
use Time::HiRes qw(time);
use XPerl::Installer::Build;

# A repair command may start a paid AI agent. A caller can cap the whole run,
# while the normal case gives every failed release its own repair allowance.

my $root = abs_path(tempdir(CLEANUP => 1,
                            DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
# Child installers keep their per-user repair lock and rate file under this
# home, so fixture agents never compete with a real installer's files.
my $home = File::Spec->catdir($root, 'home');
make_path($home);
my $mirror = File::Spec->catdir($root, 'mirror');
my $cache = File::Spec->catdir($root, 'cache');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path(File::Spec->catdir($mirror, 'modules'), $releases);

my @index;
sub release ($name, @requires) {
    my $dist = "Example-$name-1.00";
    my $tar = Archive::Tar->new;
    $tar->add_data("$dist/Makefile.PL",
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Example::$name', VERSION => '1.00');\n");
    $tar->add_data("$dist/lib/Example/$name.pm",
        "package Example::$name;\nour \$VERSION = '1.00';\nsub value { 0 }\n1;\n");
    $tar->add_data("$dist/t/basic.t",
        "use Test::More tests => 1;\nuse Example::$name;\nis(Example::${name}::value(), 42);\n");
    $tar->add_data("$dist/META.json", JSON::PP->new->encode({
        'meta-spec' => { version => 2 }, name => "Example-$name", version => '1.00',
        abstract => 'fixture', author => ['XPerl'], license => ['perl_5'],
        generated_by => 'repair-limits.t', release_status => 'stable',
        dynamic_config => JSON::PP::false,
        prereqs => { runtime => { requires => { map { ("Example::$_" => 0) } @requires } } },
    }));
    $tar->write(File::Spec->catfile($releases, "$dist.tar.gz"), 1);
    push @index, "Example::$name 1.00 E/EX/EXAMPLE/$dist.tar.gz";
}
# Every release fails its test until repaired.
release('Leaf');
release('Stem', 'Leaf');
release('One');
release('Two');
release('Both', qw(One Two));
my $index = "File: 02packages.details.txt\n\n" . join("\n", sort @index) . "\n";
gzip \$index => File::Spec->catfile($mirror, 'modules', '02packages.details.txt.gz')
    or die $GzipError;

# The agent repairs any fixture module and logs when it ran.
my $agent = File::Spec->catfile($root, 'agent');
open my $agent_file, '>', $agent or die $!;
print {$agent_file} "#!$^X\n", <<'AGENT';
use strict;
use warnings;
use JSON::PP;
use Time::HiRes qw(time sleep);
my $request = do {
    open my $in, '<', $ARGV[0] or die $!;
    JSON::PP->new->decode(do { local $/; <$in> });
};
my $start = time;
sleep 1;
my $dir = "$request->{source}/lib/Example";
opendir my $dh, $dir or die $!;
for my $file (grep { /\.pm\z/ } readdir $dh) {
    my $path = "$dir/$file";
    open my $in, '<', $path or die $!;
    my $body = do { local $/; <$in> };
    close $in;
    $body =~ s/sub value \{ 0 \}/sub value { 42 }/;
    open my $out, '>', $path or die $!;
    print {$out} $body;
    close $out or die $!;
}
open my $log, '>>', $ENV{XPERL_AGENT_LOG} or die $!;
printf {$log} "%s %.3f %.3f\n", $request->{module}, $start, time;
close $log or die $!;
AGENT
close $agent_file or die $!;
chmod 0755, $agent or die $!;

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl-install');
my $run = 0;
sub install ($module, @extra) {
    ++$run;
    local $ENV{HOME} = $home;
    local $ENV{XPERL_AGENT_LOG} = File::Spec->catfile($root, "agent-$run.log");
    my $errors = File::Spec->catfile($root, "stderr-$run");
    open my $saved, '>&', \*STDERR or die $!;
    open STDERR, '>', $errors or die $!;
    open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
        '--cache', $cache, '--prefix', File::Spec->catdir($root, "prefix-$run"),
        '--workdir', File::Spec->catdir($root, "work-$run"),
        '--repair-command', $agent, '--repair-attempts', 1,
        '--repair-interval', 0, @extra, $module
        or die $!;
    open STDERR, '>&', $saved or die $!;
    my $output = do { local $/; <$pipe> };
    close $pipe;
    my $status = $? >> 8;
    $output .= do { open my $in, '<', $errors or die $!; local $/; <$in> };
    my @calls;
    if (open my $log, '<', $ENV{XPERL_AGENT_LOG}) {
        @calls = map { [split] } <$log>;
    }
    return ($status, \@calls, $output);
}

# Without a run-wide cap, both releases can use their own attempt allowance.
my ($status, $calls, $output) = install('Example::Stem');
is($status, 0, 'the run repairs both releases by default');
is(scalar @$calls, 2, 'each release receives its own repair call');

# An explicit run-wide cap still stops further calls.
($status, $calls, $output) = install('Example::Stem', '--repair-limit', 1);
isnt($status, 0, 'an explicit cap stops the second repair');
is(scalar @$calls, 1, 'the cap permits one agent call');
like($output, qr/repair limit/, 'the failure names the run-wide cap');

# Parallel builds never run two repairs at the same time.
($status, $calls) = install('Example::Both', '--jobs', 3, '--repair-limit', 3);
is($status, 0, 'parallel install with repairs succeeds');
is(scalar @$calls, 3, 'every broken release was repaired once');
my @sorted = sort { $a->[1] <=> $b->[1] } @$calls;
my $overlap = grep { $sorted[$_][1] < $sorted[$_ - 1][2] } 1 .. $#sorted;
is($overlap, 0, 'repair calls never overlap');

# A minimum interval spaces starts even when the agent finishes quickly.
($status, $calls) = install('Example::Stem', '--repair-interval', 2);
is($status, 0, 'a spaced run still repairs both releases');
@sorted = sort { $a->[1] <=> $b->[1] } @$calls;
cmp_ok($sorted[1][1] - $sorted[0][1], '>=', 1.9,
       'agent calls begin at least two seconds apart');

# The default coordination files live in a private per-user directory under
# the installer's home state, never in the shared temporary directory.
my $private = File::Spec->catdir($home, '.xperl', 'repair');
ok(-d $private && !-l $private, 'the run created a private repair directory');
is((stat $private)[2] & 07777, 0700, 'the repair directory is mode 0700');
for my $name (qw(rate lock)) {
    my $file = File::Spec->catfile($private, $name);
    ok(-f $file && !-l $file, "the repair $name file is a regular file");
    is((stat $file)[2] & 07777, 0600, "the repair $name file is mode 0600");
}
{
    local $ENV{HOME} = $home;
    my $builder = XPerl::Installer::Build->new(
        prefix => File::Spec->catdir($root, 'defaults-prefix'),
        workdir => File::Spec->catdir($root, 'defaults-work'));
    my $tmp = abs_path(File::Spec->tmpdir);
    for my $key (qw(repair_rate_file repair_lock)) {
        my $path = $builder->{$key};
        is(index($path, "$private/"), 0, "the default $key is in the private directory");
        my $parent = abs_path((File::Spec->splitpath($path))[1]);
        isnt($parent, $tmp, "the default $key is not directly in the temporary directory");
    }
}

# A planted symlink must not let another local user redirect the rate file
# or lock onto a file the installer's user can write.
my $victim = File::Spec->catfile($root, 'victim');
sub plant ($name) {
    open my $out, '>', $victim or die $!;
    print {$out} "precious\n";
    close $out or die $!;
    my $link = File::Spec->catfile($root, $name);
    unlink $link;
    symlink $victim, $link or die $!;
    return $link;
}
sub victim_body () {
    open my $in, '<', $victim or die $!;
    return do { local $/; <$in> };
}

my $link = plant('planted-rate');
ok(!eval { XPerl::Installer::Build::_space_repair_calls($link, 1); 1 },
   'a symlinked rate file is refused');
like($@, qr/repair rate file/, 'the refusal names the rate file');
is(victim_body(), "precious\n", 'the rate file symlink target is unchanged');

$link = plant('planted-lock');
ok(!eval { XPerl::Installer::Build::_repair_lock($link); 1 },
   'a symlinked repair lock is refused');
like($@, qr/repair lock/, 'the refusal names the repair lock');
is(victim_body(), "precious\n", 'the repair lock symlink target is unchanged');

# Ordinary spacing still records a start time and delays the next call.
my $rate = File::Spec->catfile($root, 'spacing.rate');
XPerl::Installer::Build::_space_repair_calls($rate, 1);
my $started = time;
XPerl::Installer::Build::_space_repair_calls($rate, 1);
cmp_ok(time - $started, '>=', 0.9, 'a second call waits for the interval');
open my $recorded, '<', $rate or die $!;
like(scalar <$recorded>, qr/\A\d+\.\d+\n\z/, 'the rate file holds one timestamp');
my $lock = XPerl::Installer::Build::_repair_lock(
    File::Spec->catfile($root, 'spacing.lock'));
ok($lock, 'a fresh repair lock can be taken');

done_testing();
