use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Spec;
use Test::More;
use XPerl::Installer::Agent;
use XPerl::Installer::Build;

# Selecting a known provider supplies the adapter without a config file.
my $codex = XPerl::Installer::Agent->profile('codex');
is($codex->{provider}, 'codex', 'Codex is built in');
is($codex->{model}, 'gpt-6.1-sol', 'Codex repairs use the selected Sol model');
is($codex->{effort}, 'high', 'Codex repairs use high reasoning effort');
is(XPerl::Installer::Agent->profile('claude')->{provider}, 'claude',
   'Claude is built in');
my $claude_default = XPerl::Installer::Agent->profile('claude');
is($claude_default->{model}, 'sonnet',
   'Claude repairs default to the current Sonnet, not the CLI default');
is(XPerl::Installer::Agent->profile('claude', { model => 'claude-opus-5-5' })->{model},
   'claude-opus-5-5', 'an explicit Claude model overrides the default');
is(XPerl::Installer::Agent->profile('porter', { provider => 'claude' })->{model},
   'sonnet', 'named Claude profiles get the same default');
my $ok = eval { XPerl::Installer::Agent->profile('typo'); 1 };
like($ok ? '' : $@, qr/unknown repair agent typo/,
     'unknown providers require an explicit custom profile');

# Paths and model names remain individual arguments, including shell syntax.
my $model = 'model; $(touch unexpected)';
my $request = { source => File::Spec->catdir('source with spaces') };
my @codex = XPerl::Installer::Agent->command({
    %$codex, executable => 'codex', model => $model,
    add_dirs => ['extra directory'],
}, 'request with spaces.json', $request);
is_deeply([@codex[0 .. 2]], ['codex', 'exec', '--sandbox'],
          'Codex uses its noninteractive command');
ok(grep($_ eq $model, @codex), 'the model is passed without shell expansion');
ok(grep($_ eq 'model_reasoning_effort="high"', @codex),
   'Codex receives its reasoning configuration');
ok(grep($_ eq 'web_search="live"', @codex),
   'Codex can search current upstream reports without shell network access');
is($codex[-3], 'extra directory', 'extra writable directory is one argument');
like($codex[-1], qr/Read the JSON repair request at\n"request with spaces.json"/,
     'the shared prompt identifies the request unambiguously');
like($codex[-1], qr/unattended operation/, 'the prompt explains human handoff');
like($codex[-1], qr/Preserve previous fixes/, 'the prompt preserves prior ports');
like($codex[-1], qr/upstream repository, bug reports\nand pending pull requests/,
     'repair agents check existing upstream reports before editing');
like($codex[-1], qr/upstream_research_path/,
     'repair agents receive the research report protocol');
like($codex[-1], qr/Continue local diagnosis when upstream is\nunavailable/,
     'upstream access is optional for local repair');

my @claude = XPerl::Installer::Agent->command({
    provider => 'claude', executable => 'claude', model => 'sonnet',
    effort => 'high',
}, 'request.json', $request);
is_deeply([@claude[0 .. 2]],
          ['claude', '--print', '--no-session-persistence'],
          'Claude uses a fresh noninteractive session');
ok(grep($_ eq 'Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch', @claude),
   'Claude can build, edit and research upstream without tool approval');
ok(grep($_ eq '--effort', @claude), 'Claude receives its effort setting');

# An unavailable provider fails before dependency resolution or builds.
$ok = eval {
    XPerl::Installer::Agent->prepare({
        provider => 'codex', executable => 'xperl-test-missing-agent-862ff',
    });
    1;
};
like($ok ? '' : $@, qr/not executable or not on PATH/,
     'missing provider gives an actionable startup error');

done_testing();
