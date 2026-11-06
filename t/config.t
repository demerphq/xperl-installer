use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use lib "$FindBin::Bin/../lib";
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use XPerl::Installer::Config;

my $root = abs_path(tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $path = File::Spec->catfile($root, 'installer.toml');
open my $output, '>:raw', $path or die $!;
print {$output} <<'TOML';
schema = 1

[install]
prefix = "/opt/xperl"
cache = "/tmp/xperl-cache"

[agents.claude]
command = "bin/claude-wrapper"
attempts = 2
timeout = 600
TOML
close $output or die $!;

my $config = XPerl::Installer::Config->load($path);
is($config->{install}{prefix}, '/opt/xperl', 'install prefix is loaded');
is($config->{agents}{claude}{command},
   File::Spec->catfile($root, qw(bin claude-wrapper)),
   'relative repair command is resolved from config directory');
is($config->{agents}{claude}{attempts}, 2, 'attempt limit is loaded');
is($config->{agents}{claude}{timeout}, 600, 'timeout is loaded');

open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[install]\npreifx = '/opt/xperl'\n";
close $output or die $!;
my $ok = eval { XPerl::Installer::Config->load($path); 1 };
ok(!$ok, 'unknown config key is rejected');
like($@, qr/unknown config key install\.preifx/, 'key error identifies typo');

open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[install]\njobs = 4\n";
close $output or die $!;
is(XPerl::Installer::Config->load($path)->{install}{jobs}, 4,
   'parallel job count is loaded');
open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[install]\njobs = 0\n";
close $output or die $!;
$ok = eval { XPerl::Installer::Config->load($path); 1 };
like($ok ? '' : $@, qr/install\.jobs must be a positive integer/,
     'a job count below one is rejected');

open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[install]\nphase_timeout = 900\n";
close $output or die $!;
is(XPerl::Installer::Config->load($path)->{install}{phase_timeout}, 900,
   'phase timeout is loaded');
open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[install]\nphase_timeout = 'soon'\n";
close $output or die $!;
$ok = eval { XPerl::Installer::Config->load($path); 1 };
like($ok ? '' : $@, qr/install\.phase_timeout must be a non-negative integer/,
     'a non-numeric phase timeout is rejected');

open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[agents.claude]\ncommand = ''\n";
close $output or die $!;
$ok = eval { XPerl::Installer::Config->load($path); 1 };
ok(!$ok, 'empty repair command is rejected');
like($@, qr/agents\.claude\.command/, 'command error names the profile');

done_testing();
