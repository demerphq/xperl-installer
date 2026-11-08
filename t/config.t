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
interval = 10
TOML
close $output or die $!;

my $config = XPerl::Installer::Config->load($path);
is($config->{install}{prefix}, '/opt/xperl', 'install prefix is loaded');
is($config->{agents}{claude}{command},
   File::Spec->catfile($root, qw(bin claude-wrapper)),
   'relative repair command is resolved from config directory');
is($config->{agents}{claude}{attempts}, 2, 'attempt limit is loaded');
is($config->{agents}{claude}{timeout}, 600, 'timeout is loaded');
is($config->{agents}{claude}{interval}, 10, 'call interval is loaded');

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
print {$output} "schema = 1\n[install]\nrepair_jobs = 2\n";
close $output or die $!;
is(XPerl::Installer::Config->load($path)->{install}{repair_jobs}, 2,
   'repair worker count is loaded');
open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[install]\nrepair_jobs = 0\n";
close $output or die $!;
$ok = eval { XPerl::Installer::Config->load($path); 1 };
like($ok ? '' : $@, qr/install\.repair_jobs must be a positive integer/,
     'a repair worker count below one is rejected');

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
print {$output} "schema = 1\n[install]\nnative_prefixes = ['/opt/homebrew']\n";
close $output or die $!;
is_deeply(XPerl::Installer::Config->load($path)->{install}{native_prefixes},
          ['/opt/homebrew'], 'native prefixes are loaded');
open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[install]\nnative_prefixes = '/opt/homebrew'\n";
close $output or die $!;
$ok = eval { XPerl::Installer::Config->load($path); 1 };
like($ok ? '' : $@, qr/install\.native_prefixes must be a list/,
     'a single native prefix string is rejected');

open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[install]\nlayout = 'site'\n";
close $output or die $!;
is(XPerl::Installer::Config->load($path)->{install}{layout}, 'site',
   'install layout is loaded');
open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[install]\nlayout = 'flat'\n";
close $output or die $!;
$ok = eval { XPerl::Installer::Config->load($path); 1 };
like($ok ? '' : $@, qr/install\.layout must be auto, site or install_base/,
     'an unknown install layout is rejected');

open $output, '>:raw', $path or die $!;
print {$output} "schema = 1\n[agents.claude]\ncommand = ''\n";
close $output or die $!;
$ok = eval { XPerl::Installer::Config->load($path); 1 };
ok(!$ok, 'empty repair command is rejected');
like($@, qr/agents\.claude\.command/, 'command error names the profile');

# Built-in providers need settings, not a user-written wrapper.
open $output, '>:raw', $path or die $!;
print {$output} <<'TOML';
schema = 1
[agents.codex]
model = 'gpt-6.1-sol'
effort = 'high'
add_dirs = ['../ports']
[agents.porter]
provider = 'claude'
executable = 'bin/claude'
model = 'sonnet'
TOML
close $output or die $!;
$config = XPerl::Installer::Config->load($path);
is($config->{agents}{codex}{provider}, 'codex', 'known profile implies provider');
is($config->{agents}{codex}{effort}, 'high', 'provider effort is loaded');
is($config->{agents}{porter}{provider}, 'claude', 'profiles can alias a provider');
is($config->{agents}{porter}{executable},
   File::Spec->catfile($root, qw(bin claude)),
   'an explicit executable path is relative to the config');
is_deeply($config->{agents}{codex}{add_dirs},
          [File::Spec->rel2abs('../ports', $root)],
          'extra directories are relative to the config');

for my $case (
    ["provider = 'other'", qr/provider must be codex or claude/],
    ["effort = 'enormous'", qr/effort is unsupported/],
    ["add_dirs = 'here'", qr/add_dirs must be a list/],
    ["command = 'wrapper'\nmodel = 'model'", qr/cannot combine command/],
) {
    open $output, '>:raw', $path or die $!;
    print {$output} "schema = 1\n[agents.codex]\n$case->[0]\n";
    close $output or die $!;
    $ok = eval { XPerl::Installer::Config->load($path); 1 };
    like($ok ? '' : $@, $case->[1], 'invalid provider settings are rejected');
}

done_testing();
