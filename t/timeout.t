use strict;
use warnings;
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

# A build phase that never finishes must not stall the installer: it is
# stopped after the phase timeout, together with any processes it started.

my $root = abs_path(tempdir(CLEANUP => 1,
                            DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $mirror = File::Spec->catdir($root, 'mirror');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path(File::Spec->catdir($mirror, 'modules'), $releases);
my $pid_file = File::Spec->catfile($root, 'grandchild.pid');

my $dist = 'Example-Hang-1.00';
my $tar = Archive::Tar->new;
$tar->add_data("$dist/Makefile.PL",
    "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Example::Hang', VERSION => '1.00');\n");
$tar->add_data("$dist/lib/Example/Hang.pm",
    "package Example::Hang;\nour \$VERSION = '1.00';\n1;\n");
# The test starts a grandchild that never exits and waits for it, like a
# test that runs a command which blocks on its input.
$tar->add_data("$dist/t/hang.t", <<"TEST");
use Test::More tests => 1;
my \$child = fork // die;
if (!\$child) { sleep 600; exit 0 }
open my \$pid, '>', '$pid_file' or die;
print {\$pid} \$child;
close \$pid;
waitpid \$child, 0;
ok(1);
TEST
$tar->write(File::Spec->catfile($releases, "$dist.tar.gz"), 1);
my $index = "File: 02packages.details.txt\n\n"
    . "Example::Hang 1.00 E/EX/EXAMPLE/$dist.tar.gz\n";
gzip \$index => File::Spec->catfile($mirror, 'modules', '02packages.details.txt.gz')
    or die $GzipError;

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl');
my $work = File::Spec->catdir($root, 'work');
my $started = time;
open my $saved, '>&', \*STDERR or die $!;
open STDERR, '>', File::Spec->catfile($root, 'stderr') or die $!;
my $status = system($^X, $script, 'install', '--mirror', $mirror,
    '--cache', File::Spec->catdir($root, 'cache'),
    '--prefix', File::Spec->catdir($root, 'prefix'), '--workdir', $work,
    '--phase-timeout', 3, 'Example::Hang');
open STDERR, '>&', $saved or die $!;
my $elapsed = time - $started;
my $errors = do { open my $in, '<', File::Spec->catfile($root, 'stderr') or die $!;
                  local $/; <$in> };

isnt($status, 0, 'a phase that never finishes fails the install');
cmp_ok($elapsed, '<', 60, 'the installer does not wait for the hung phase');
like($errors, qr/test timed out after 3 seconds/, 'the failure says the phase timed out');
my ($receipt_path) = glob File::Spec->catfile($work, 'release-*', 'receipt.json');
my $receipt = do { open my $in, '<', $receipt_path or die $!;
                   JSON::PP->new->decode(do { local $/; <$in> }) };
my ($test) = grep { $_->{name} eq 'test' } @{$receipt->{phases}};
ok($test && $test->{timed_out}, 'the receipt marks the phase as timed out');
SKIP: {
    skip 'process groups are not available on this platform', 1 if $^O eq 'MSWin32';
    my $grandchild = do { open my $in, '<', $pid_file or die $!; local $/; <$in> };
    ok(!kill(0, $grandchild), 'processes started by the phase are stopped too');
    kill 9, $grandchild;
}

done_testing();
