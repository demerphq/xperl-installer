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

my $root = abs_path(tempdir(CLEANUP => 1,
    DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $builder = XPerl::Installer::Build->new(
    prefix => "$root/prefix", workdir => "$root/work", phase_log_mb => 1);

# Infinite output must stop promptly and leave a bounded, useful log.
my $started = time;
my ($status, $timeout, $limit) = $builder->_run($root, "$root/flood.log",
    { phase => 'configure', timeout => 5 }, $^X, '-e',
    '$| = 1; print "x" x 8192 while 1');
is($status, 125, 'output cap stops a runaway command');
is($limit, 'log', 'output limit is distinguished from a timeout');
ok(!$timeout, 'the log guard fires before the deadline');
cmp_ok(time - $started, '<', 5, 'output loop stops promptly');
cmp_ok(-s "$root/flood.log", '<', 1024 * 1024 + 256,
       'log stays within the cap plus the stop explanation');

# A process can close its output and keep running. That must not evade
# supervision by taking the parent out of its pipe-reading loop.
($status, $timeout) = $builder->_run($root, "$root/closed.log",
    { timeout => 0.3 }, $^X, '-e', 'close STDOUT; close STDERR; sleep 30');
is($status, 124, 'deadline applies after output pipes close');
ok($timeout, 'closed-pipe hang is recorded as a timeout');

SKIP: {
    skip 'RLIMIT_DATA heap enforcement is checked on Linux', 2 unless $^O eq 'linux';
    my $bounded = XPerl::Installer::Build->new(
        prefix => "$root/prefix", workdir => "$root/work", phase_memory_mb => 64);
    $status = $bounded->_run($root, "$root/memory.log",
        { phase => 'test', timeout => 10 }, $^X, '-e',
        'my $memory = "x" x (256 * 1024 * 1024); print length $memory');
    isnt($status, 0, 'a build child cannot allocate beyond the data limit');
    $status = $bounded->_run($root, "$root/agent.log",
        { timeout => 10 }, $^X, '-e',
        'my $memory = "x" x (80 * 1024 * 1024); print length $memory');
    is($status, 0, 'the build memory cap does not constrain an agent command');
}

# Exercise config, receipts and resume through the command a human runs.
# The first attempt stops during configure. A larger explicit resume limit
# then builds and installs the same release without changing its source.
my $mirror = "$root/mirror";
my $releases = "$mirror/authors/id/E/EX/EXAMPLE";
make_path("$mirror/modules", $releases);
my $dist = 'Example-Verbose-1.00';
my $tar = Archive::Tar->new;
$tar->add_data("$dist/Makefile.PL", <<'CONFIGURE');
use ExtUtils::MakeMaker;
$| = 1;
print 'x' x (1536 * 1024);
WriteMakefile(NAME => 'Example::Verbose', VERSION => '1.00');
CONFIGURE
$tar->add_data("$dist/lib/Example/Verbose.pm",
    "package Example::Verbose; our \$VERSION = '1.00'; 1;\n");
$tar->add_data("$dist/t/basic.t",
    "use Test::More tests => 1; use_ok('Example::Verbose');\n");
$tar->write("$releases/$dist.tar.gz", 1);
my $index = "File: 02packages.details.txt\n\n"
    . "Example::Verbose 1.00 E/EX/EXAMPLE/$dist.tar.gz\n";
gzip \$index => "$mirror/modules/02packages.details.txt.gz" or die $GzipError;
open my $config, '>', "$root/config.toml" or die $!;
print {$config} "schema = 1\n[install]\nphase_log_mb = 1\n";
close $config or die $!;
my $script = "$FindBin::Bin/../bin/xperl-install";
my $work = "$root/cli-work";
my $result_file = "$root/result.json";

sub invoke (@args) {
    open my $saved, '>&', \*STDOUT or die $!;
    open STDOUT, '>', $result_file or die $!;
    my $exit = system($^X, $script, 'install', @args);
    open STDOUT, '>&', $saved or die $!;
    open my $input, '<', $result_file or die $!;
    my $result = JSON::PP->new->decode(do { local $/; <$input> });
    close $input or die $!;
    return ($exit, $result);
}

my ($exit, $result) = invoke('--config', "$root/config.toml",
    '--mirror', $mirror, '--cache', "$root/cache", '--prefix', "$root/cli-prefix",
    '--workdir', $work, 'Example::Verbose');
isnt($exit, 0, 'configured log cap stops the installation');
like($result->{modules}[0]{reason}, qr/configure exceeded log limit of 1 MiB/,
     'human result explains the limit');
my ($receipt_path) = glob "$work/release-*/receipt.json";
open my $input, '<', $receipt_path or die $!;
my $receipt = JSON::PP->new->decode(do { local $/; <$input> });
close $input or die $!;
is($receipt->{phases}[0]{resource_limit}, 'log', 'receipt identifies the guard');
is($receipt->{resource_limits}{phase_log_mb}, 1, 'receipt records configured cap');

($exit, $result) = invoke('--resume', '--workdir', $work, '--phase-log-mb', 3);
is($exit, 0, 'explicit resume override lets the legitimate build finish');
is($result->{modules}[0]{status}, 'installed', 'resumed release is installed');
open $input, '<', "$work/install-session.json" or die $!;
my $session = JSON::PP->new->decode(do { local $/; <$input> });
close $input or die $!;
is($session->{options}{phase_log_mb}, 3, 'new limit is saved for later resumes');

done_testing;
