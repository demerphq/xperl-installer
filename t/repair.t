use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;
use TOML::Tiny;

my $root = abs_path(tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $mirror = File::Spec->catdir($root, 'mirror');
my $cache = File::Spec->catdir($root, 'cache');
my $prefix = File::Spec->catdir($root, 'prefix');
my $registry = File::Spec->catdir($root, 'registry');
my $modules = File::Spec->catdir($mirror, 'modules');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path($modules, $releases, $registry);

my $index = <<'INDEX';
File: 02packages.details.txt

Example::Fixable 1.00 E/EX/EXAMPLE/Example-Fixable-1.00.tar.gz
Example::Unfixable 1.00 E/EX/EXAMPLE/Example-Unfixable-1.00.tar.gz
Example::Slow 1.00 E/EX/EXAMPLE/Example-Slow-1.00.tar.gz
Example::NeedsLibrary 1.00 E/EX/EXAMPLE/Example-NeedsLibrary-1.00.tar.gz
Example::Unknown 1.00 E/EX/EXAMPLE/Example-Unknown-1.00.tar.gz
Example::NeedsPerl 1.00 E/EX/EXAMPLE/Example-NeedsPerl-1.00.tar.gz
Example::Extra 1.00 E/EX/EXAMPLE/Example-Extra-1.00.tar.gz
INDEX
gzip \$index => File::Spec->catfile($modules, '02packages.details.txt.gz')
    or die $GzipError;

for my $name (qw(Fixable Unfixable Slow NeedsLibrary Unknown NeedsPerl Extra)) {
    my $dist = "Example-$name-1.00";
    my $tar = Archive::Tar->new;
    $tar->add_data("$dist/Makefile.PL",
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Example::$name', VERSION => '1.00');\n");
    $tar->add_data("$dist/lib/Example/$name.pm",
        "package Example::$name;\nour \$VERSION = '1.00';\nsub value { 0 }\n1;\n");
    my $test = $name eq 'NeedsLibrary'
        ? "use Test::More tests => 1; ok(-f \$ENV{XPERL_TEST_LIBRARY_READY}, 'native library is available');\n"
        : $name eq 'NeedsPerl'
        ? "use Test::More tests => 1; use Example::Extra; pass('Perl prerequisite is available');\n"
        : $name eq 'Extra'
        ? "use Test::More tests => 1; pass('CPAN prerequisite builds');\n"
        : "use Test::More tests => 1; use Example::$name; is(Example::${name}::value(), 42);\n";
    $tar->add_data("$dist/t/basic.t", $test);
    $tar->write(File::Spec->catfile($releases, "$dist.tar.gz"), 1);
}

my $agent = File::Spec->catfile($root, 'repair-agent');
open my $agent_file, '>', $agent or die $!;
print {$agent_file} "#!$^X\n";
print {$agent_file} <<'AGENT';
use strict;
use warnings;
use JSON::PP;
use File::Spec;
my $request_path = shift @ARGV;
open my $request_file, '<', $request_path or die $!;
my $request = JSON::PP->new->decode(do { local $/; <$request_file> });
open my $marker, '>', $ENV{XPERL_REPAIR_MARKER} or die $!;
print {$marker} JSON::PP->new->encode($request);
close $marker or die $!;
exit 0 if $request->{module} eq 'Example::Unfixable';
if ($request->{module} eq 'Example::Slow') { sleep 3; exit 0 }
if ($request->{module} eq 'Example::NeedsLibrary') {
    open my $out, '>', $request->{response_path} or die $!;
    print {$out} JSON::PP->new->encode({
        schema => 1, status => 'needs_user_action',
        action => {
            kind => 'system_dependency',
            message => 'Install the example native library',
            install_hint => 'sudo apt install libexample-dev',
        },
    });
    close $out or die $!;
    exit 0;
}
if ($request->{module} eq 'Example::Unknown') {
    open my $out, '>', $request->{response_path} or die $!;
    print {$out} JSON::PP->new->encode({
        schema => 1, status => 'needs_user_action',
        action => {
            kind => 'manual_step',
            message => 'I cannot identify the test failure; inspect the test log',
        },
    });
    close $out or die $!;
    exit 0;
}
if ($request->{module} eq 'Example::NeedsPerl') {
    open my $out, '>', $request->{response_path} or die $!;
    print {$out} JSON::PP->new->encode({
        schema => 1, status => 'needs_cpan_dependency',
        module => 'Example::Extra',
    });
    close $out or die $!;
    exit 0;
}
my $module = File::Spec->catfile($request->{source},
                                qw(lib Example Fixable.pm));
open my $source, '<', $module or die $!;
my $body = do { local $/; <$source> };
close $source or die $!;
$body =~ s/sub value \{ 0 \}/sub value { 42 }/
    or die "expected source not found\n";
open my $output, '>', $module or die $!;
print {$output} $body;
close $output or die $!;
# Make cannot tell a repair from the first build when both land in the
# same timestamp unit (one second for GNU make 3.81). Backdating the edit
# and post-dating the first build's marker makes that case deterministic.
utime 1_000_000_000, 1_000_000_000, $module or die $!;
my $marker_file = File::Spec->catfile($request->{source}, 'pm_to_blib');
utime time + 3600, time + 3600, $marker_file if -e $marker_file;
my $added = File::Spec->catfile($request->{source},
                                qw(lib Example Added.pm));
open my $extra, '>', $added or die $!;
print {$extra} "package Example::Added;\n1;\n";
close $extra or die $!;
my $object = File::Spec->catfile($request->{source}, 'Attribute.o');
open my $built, '>:raw', $object or die $!;
print {$built} "\0compiled object\0";
close $built or die $!;
my $scratch = File::Spec->catfile($request->{source}, 'tmp2');
open my $temporary, '>', $scratch or die $!;
print {$temporary} "test scratch output\n";
close $temporary or die $!;
AGENT
close $agent_file or die $!;
chmod 0755, $agent or die $!;

my $config_path = File::Spec->catfile($root, 'installer.toml');
open my $config_file, '>:raw', $config_path or die $!;
print {$config_file} TOML::Tiny->new->encode({
    schema => 1,
    install => { mirror => $mirror, cache => $cache, prefix => $prefix },
    agents => { fixture => { command => $agent, attempts => 1,
                             interval => 0 } },
});
close $config_file or die $!;

local $ENV{XPERL_REPAIR_MARKER} = File::Spec->catfile($root, 'request.json');
my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl-install');
open my $pipe, '-|', $^X, $script, 'install', '--config', $config_path,
    '--agent', 'fixture', '--registry', $registry, 'Example::Fixable' or die $!;
my $output = do { local $/; <$pipe> };
ok(close $pipe, 'repair completed');
my $result = eval { JSON::PP->new->decode($output) };
ok($result && $result->{status} eq 'installed', 'repaired module installed');
my $receipt_path = $result->{receipts}[0];
open my $receipt_file, '<', $receipt_path or die $!;
my $receipt = JSON::PP->new->decode(do { local $/; <$receipt_file> });
is_deeply([map { $_->{name} } @{$receipt->{phases}}],
          [qw(configure build test repair configure build test proposal-check install)],
          'installer reran all checks after repair');
my $proposal = $receipt->{proposal};
ok($proposal && -f $proposal->{path}, 'reviewable patch was written');
is($receipt->{registration}{status}, 'registered',
   'successful repair entered the configured registry');
ok(-f $receipt->{registration}{index}
   && -f $receipt->{registration}{evidence},
   'registry keeps the release index and portable test evidence');
open my $patch_file, '<:raw', $proposal->{path} or die $!;
my $patch = do { local $/; <$patch_file> };
is(sha256_hex($patch), $proposal->{sha256}, 'receipt records patch digest');
like($patch, qr/\+sub value \{ 42 \}/, 'patch contains source repair');
like($patch, qr/^\+\+\+ b\/lib\/Example\/Added\.pm$/m,
     'patch contains agent-added source file');
unlike($patch, qr/^\+\+\+ b\/(?:Makefile|blib\/)/m,
       'patch excludes generated build products');
unlike($patch, qr/Attribute\.o/, 'patch excludes an agent-built object file');
unlike($patch, qr/tmp2/, 'patch excludes a test scratch file');
open my $request_file, '<', $ENV{XPERL_REPAIR_MARKER} or die $!;
my $request = JSON::PP->new->decode(do { local $/; <$request_file> });
is($request->{failed_phase}, 'test', 'agent received failed phase');
is($request->{registry}, $registry, 'agent received the registry location');
like($request->{guidance}, qr/not making progress.*manual_step/,
     'agent receives guidance to hand an unproductive repair to a human');
ok(-f $request->{failed_log}, 'agent received persistent test log');
like($request->{response_path}, qr/\A\Q$request->{source}\E\//,
     'agent response stays inside its writable source directory');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Fixable.pm)),
   'repaired module installed in prefix');

open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--registry', $registry,
    '--prefix', File::Spec->catdir($root, 'replay-prefix'),
    'Example::Fixable' or die $!;
my $replay_output = do { local $/; <$pipe> };
ok(close $pipe, 'registered patch installs from the original release');
my $replay = JSON::PP->new->decode($replay_output);
is($replay->{status}, 'installed',
   'registry replay needs no repair agent');

open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, '--repair-command', $agent,
    '--repair-attempts', '2', '--repair-interval', '0',
    'Example::Unfixable' or die $!;
my $failure = do { local $/; <$pipe> };
ok(!close $pipe, 'repair stops when the agent leaves source unchanged');
like($failure, qr/repair made no source changes/,
     'the failure explains why another repair was not attempted');
my ($unfixed_receipt) = $failure =~ /"receipt"\s*:\s*"([^"]+)"/;
ok(defined $unfixed_receipt && -f $unfixed_receipt,
   'the unchanged repair has a receipt');
if ($unfixed_receipt) {
    my $unfixed = JSON::PP->new->decode(do {
        open my $input, '<', $unfixed_receipt or die $!;
        local $/; <$input>;
    });
    is(scalar(grep { $_->{name} eq 'repair' } @{$unfixed->{phases}}), 1,
       'the no-change result uses one repair call');
    ok($unfixed->{phases}[-1]{unchanged},
       'the receipt marks the repair as unchanged');
}
ok(!-f File::Spec->catfile($prefix, qw(lib perl5 Example Unfixable.pm)),
   'unrepaired module was not installed');

# A missing host dependency is a user action, not a source repair. The
# saved install request lets a later run retry it after the dependency arrives.
my $action_work = File::Spec->catdir($root, 'action-work');
my $ready = File::Spec->catfile($root, 'native-library-ready');
local $ENV{XPERL_TEST_LIBRARY_READY} = $ready;
open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, '--workdir', $action_work,
    '--repair-command', $agent, '--repair-interval', '0',
    'Example::NeedsLibrary' or die $!;
my $action_output = do { local $/; <$pipe> };
ok(!close $pipe, 'missing native library prevents installation');
my $action_result = JSON::PP->new->decode($action_output);
is($action_result->{user_actions}[0]{kind}, 'system_dependency',
   'the result classifies the host dependency');
is($action_result->{user_actions}[0]{install_hint},
   'sudo apt install libexample-dev', 'the result includes an install hint');
is($action_result->{resume}{workdir}, $action_work,
   'the result points to the saved install session');
my $action_receipt = $action_result->{nodes}[0]{receipt};
my $action_record = JSON::PP->new->decode(do {
    open my $input, '<', $action_receipt or die $!;
    local $/; <$input>;
});
is($action_record->{user_action}{message},
   'Install the example native library', 'receipt preserves the diagnosis');
is(scalar(grep { $_->{name} eq 'repair' } @{$action_record->{phases}}), 1,
   'the installer does not retry a missing host dependency');

# An agent can admit uncertainty without making another source edit. The
# scheduler records the handoff and keeps an unrelated release moving.
open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', File::Spec->catdir($root, 'unknown-prefix'),
    '--workdir', File::Spec->catdir($root, 'unknown-work'),
    '--repair-command', $agent, '--repair-interval', '0',
    'Example::Unknown', 'Example::Extra' or die $!;
my $unknown_output = do { local $/; <$pipe> };
ok(!close $pipe, 'unattended run reports an uncertain repair');
my $unknown_result = JSON::PP->new->decode($unknown_output);
is($unknown_result->{user_actions}[0]{kind}, 'manual_step',
   'uncertain repair reaches the human action queue');
like($unknown_result->{user_actions}[0]{message}, qr/inspect the test log/,
     'the handoff keeps the agent diagnosis');
my ($extra_result) = grep { $_->{module} eq 'Example::Extra' }
                     @{$unknown_result->{modules}};
is($extra_result->{status}, 'installed',
   'independent release installs while a repair needs human help');

open my $native_library, '>', $ready or die $!;
close $native_library or die $!;
open $pipe, '-|', $^X, $script, 'install', '--resume',
    '--workdir', $action_work or die $!;
my $resumed_output = do { local $/; <$pipe> };
ok(close $pipe, 'the saved request succeeds after the dependency arrives');
my $resumed = JSON::PP->new->decode($resumed_output);
is($resumed->{status}, 'installed', 'resume installs the distribution');
is_deeply($resumed->{user_actions}, [],
          'the resolved dependency leaves no pending action');

# An undeclared CPAN prerequisite returns to the build graph. The scheduler
# installs it and retries the release without asking the user to intervene.
open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', File::Spec->catdir($root, 'perl-prefix'),
    '--workdir', File::Spec->catdir($root, 'perl-work'),
    '--repair-command', $agent, '--repair-interval', '0',
    'Example::NeedsPerl' or die $!;
my $perl_output = do { local $/; <$pipe> };
ok(close $pipe, 'undeclared CPAN dependency was installed');
my $perl_result = JSON::PP->new->decode($perl_output);
is($perl_result->{status}, 'installed',
   'the original release succeeds after its prerequisite');
my ($extra_node) = grep { $_->{cpan_path} =~ /Example-Extra/ }
                   @{$perl_result->{nodes}};
is($extra_node->{status}, 'installed',
   'the missing CPAN release joined the build graph');
is_deeply($perl_result->{user_actions}, [],
          'a CPAN dependency needs no user action');

SKIP: {
    skip 'an interactive terminal is needed to test the action shell', 3
        unless -t STDIN && -t STDERR;

    unlink $ready or die $!;
    my $shell = File::Spec->catfile($root, 'install-dependency-shell');
    open my $shell_file, '>', $shell or die $!;
    print {$shell_file} "#!$^X\n";
    print {$shell_file} 'open my $out, q(>), $ENV{XPERL_TEST_LIBRARY_READY} or die $!; close $out or die $!;', "\n";
    close $shell_file or die $!;
    chmod 0755, $shell or die $!;

    local $ENV{SHELL} = $shell;
    open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
        '--cache', $cache, '--prefix', File::Spec->catdir($root, 'shell-prefix'),
        '--workdir', File::Spec->catdir($root, 'shell-work'),
        '--repair-command', $agent, '--repair-interval', '0',
        '--action-shell', 'Example::NeedsLibrary' or die $!;
    my $shell_output = do { local $/; <$pipe> };
    ok(close $pipe, 'the action shell retries the failed release');
    ok(-f $ready, 'the shell ran before the retry');
    my $shell_result = JSON::PP->new->decode($shell_output);
    is($shell_result->{status}, 'installed',
       'the retry succeeds after the shell exits');
}

open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, '--repair-command', $agent,
    '--repair-attempts', '1', '--repair-timeout', '1',
    '--repair-interval', '0', 'Example::Slow'
    or die $!;
my $timeout = do { local $/; <$pipe> };
ok(!close $pipe, 'slow repair command times out');
ok(!-f File::Spec->catfile($prefix, qw(lib perl5 Example Slow.pm)),
   'timed-out repair did not install module');

done_testing();
