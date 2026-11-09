# XPerl::Installer

Want to try it? [Install a CPAN module you use](TRY-A-MODULE.md) and tell us
what happens. The guide keeps the trial in a separate library directory.

Collaborators starting from a fresh workspace should use the
[current bootstrap guide](planning/bootstrap.md). It includes an
[umbrella agent-instructions template](planning/perldev-AGENTS.md).

The installer resolves a module through CPAN's `02packages` index, fetches its
original release archive, and can build, test, and install a `Makefile.PL` or
`Build.PL` distribution into an explicit prefix. It recursively installs
declared required prerequisites. With `--registry DIR`, it applies known
patches from the local `xperl-cpan-ports` repository before building. The CLI
uses XPerl's `dispatch/on` syntax.

Build and install this distribution with an installed XPerl. The commands
below assume a Perlbrew installation named `xperl` and run from this
repository's root:

```sh
prefix="$HOME/perl5/perlbrew/perls/xperl"
"$prefix/bin/perl" Makefile.PL
make
make test
make install
"$prefix/bin/perl" "$prefix/bin/xperl-install" resolve Sereal::Decoder
"$prefix/bin/perl" "$prefix/bin/xperl-install" fetch Sereal::Decoder
"$prefix/bin/perl" "$prefix/bin/xperl-install" install --prefix "$prefix" Example::Tiny
```

The installed interpreter runs the installer and every CPAN build and test.
A plain `make install` puts the installer in the interpreter's site library,
which its `@INC` already searches, so no `PERL5LIB` is needed. During
development, the installed XPerl can run `bin/xperl-install` from this checkout. The
source directory does not enter CPAN build paths. End users can run ordinary
installs without changing or rebuilding XPerl.

Because `--prefix` above is the interpreter's own prefix, `xperl-install install`
puts modules in its site library too (see [Install layout](#install-layout)).
The earlier local::lib-style setup still works: install with
`Makefile.PL INSTALL_BASE="$prefix"`, pass `--layout install_base`, and export
`PERL5LIB="$prefix/lib/perl5"` so later commands find the modules.

To install the current Sereal releases with local compatibility patches:

```sh
"$prefix/bin/perl" "$prefix/bin/xperl-install" install --prefix "$prefix" --registry ../xperl-cpan-ports Sereal::Decoder
"$prefix/bin/perl" "$prefix/bin/xperl-install" install --prefix "$prefix" --registry ../xperl-cpan-ports Sereal::Encoder
```

## Finding modules affected by a core change

`scan-impact` searches CPAN source through [grep.metacpan.org](https://grep.metacpan.org/).
Give it a Perl compatible regular expression for the changed API or internal
structure. For the XPerl hash storage change, start with:

```sh
"$prefix/bin/perl" "$prefix/bin/xperl-install" scan-impact --pattern 'HvARRAY|HeNEXT|HeSHARED_NEXT'
"$prefix/bin/perl" "$prefix/bin/xperl-install" scan-impact --pattern 'HvARRAY|HeNEXT|HeSHARED_NEXT' --json > hash-candidates.json
```

The default file filter is `*.c, *.xs, *.h, *.inc`, and the default ignore
filter is `ppport.h`. Use `--files` and `--ignore` to change those filters.
The same fields appear in the website's search form. Results include source
files and line numbers, and the JSON form can feed a review queue. A match
means the code needs inspection; it does not mean the distribution fails on
XPerl. The command does not change the ports registry or install packages.
If the API truncates a search or the page limit is reached, JSON reports
`incomplete: true` and the text view warns on stderr.

## Install layout

`--layout` (or `layout` in the `[install]` table) chooses where modules go:

- `site` builds with `INSTALLDIRS=site` (`--installdirs site` for `Build.PL`)
  and installs into the running interpreter's site library, script and
  manual directories. Its `@INC` finds them without `PERL5LIB`.
- `install_base` builds with `INSTALL_BASE=PREFIX` (`--install_base`) and
  installs under `PREFIX/lib/perl5`. Scripts that use those modules need that
  directory in `PERL5LIB`.
- `auto`, the default, uses `site` when `--prefix` is the interpreter's own
  prefix (`$Config{siteprefixexp}`, otherwise `$Config{installprefix}`), and
  `install_base` for any other prefix, such as a validation prefix.

A site install ignores the caller's `PERL_MM_OPT` and `PERL_MB_OPT`, so a
local::lib setting cannot redirect it. If an older copy of the module remains
under `PREFIX/lib/perl5`, it comes first in `@INC` whenever `PERL5LIB` names
that directory. The installer warns about it and lists it under
`shadowed_by` in the receipt. Receipts record the layout in `layout`.

## Stopping and resuming

From another terminal, request a graceful stop using the running install's
work directory:

```sh
xperl-install stop --workdir /path/to/work
```

The installer starts no further builds or repairs. Active work finishes,
including testing and installing a successful repair, then the installer
saves its results and exits with status 2. For `install`, resume with:

```sh
xperl-install install --resume --workdir /path/to/work
```

For `install-ported`, rerun the original command with `--resume`. Resume
clears the stop request. This is a cooperative stop command; it does not
change what Ctrl-C or forcibly terminating a process does.

## Configuration

`--config FILE` reads a TOML file. The format is intentionally small. CLI
options override values in `[install]`. `--agent codex` and `--agent claude`
use built-in adapters and repair instructions, without a config file or a
wrapper script. Install and sign in to the selected provider's CLI first.
No agent runs without `--agent` or `--repair-command`.

```toml
schema = 1

[install]
prefix = "/home/me/perl5/perlbrew/perls/xperl"
registry = "/home/me/perldev/xperl-cpan-ports"
cache = "/home/me/.xperl/cache"

[agents.codex]
model = "gpt-6.1-sol"
effort = "high"
attempts = 16
timeout = 600
interval = 10

[agents.claude]
attempts = 16
timeout = 600
interval = 10

[agents.other]
command = "/home/me/bin/another-repair-tool"
```

For example, `xperl-install install --config config.toml --agent claude
Module::Name` chooses Claude Code. `--agent codex` chooses Codex, defaulting
to `gpt-6.1-sol` with high reasoning effort. Claude defaults to `sonnet`, the
Claude Code alias for the current Sonnet model, rather than the CLI's own
default, which may be a larger and costlier model. Set `model` to choose
another, for example `model = "claude-opus-5-5"`. Both adapters accept
`model`, `effort`, `executable`, and `add_dirs`. A named profile such as
`[agents.porter]` can select `provider = "claude"` or `provider = "codex"`.

The provider CLI runs noninteractively in the distribution source directory.
Codex uses its `workspace-write` sandbox and enables live web search for
upstream research. Claude accepts edits and permits its Bash, Read, Edit,
Write, Glob, Grep, WebSearch, and WebFetch tools without prompting. Claude
has no equivalent write sandbox: its file-editing tools stay within the
working directories, but Bash can change anything the user can, including
the installed interpreter and a registry checkout. Claude also loads the
user's own settings, hooks, plugins, MCP servers and instruction files in
these sessions. Both providers receive shared instructions for build
configurations, existing patches, recipes, missing dependencies, and
unattended human handoff. The installer
supervises timeouts and retries, reruns the builds and tests, and registers
successful repairs in a configured writable registry. Its normal invocation
does not require another agent to manage the run.

Before editing, repair agents check the distribution's upstream repository,
bug reports, pending PRs and relevant recent fixes. The request's `upstream`
field supplies repository and bug-tracker resources from release metadata.
Agents verify that a proposed fix matches the failure and the actual Perl
version and build configuration before adapting it. This investigation is
read-only. Ordinary installs make no additional upstream requests.

Agents write findings to the request's `upstream_research_path`: schema 1,
status `checked` or `unavailable`, a `summary`, and a `references` array of
objects containing HTTP(S) `url` values. A completed search with no useful
reports uses an empty array. Unavailable access is recorded and local
diagnosis continues. The receipt keeps the summary; registered repair
evidence keeps the status and public links. Research files never enter the
distribution patch. Custom agents that omit this report are recorded as
`not_reported`, preserving compatibility without claiming a search occurred.

`executable` defaults to the provider's program on `PATH`. Explicit relative
executable paths, custom commands, and `add_dirs` are relative to the config
file. `add_dirs` grants the worker access to additional working directories;
ordinary repairs need none. Keep credentials with the provider CLI rather
than in the installer config. The request and receipt record the selected
provider and model. A saved install session keeps those settings for
`--resume`; an explicit `--agent` or `--repair-command` replaces its selection.

`--cache DIR` selects a download cache directory; the default is
`$HOME/.xperl/cache`. `--workdir DIR` keeps unpacked builds, logs, and receipts
separate from downloads; by default they go under the cache's `work/`
directory. `--mirror URL` selects an HTTPS CPAN
mirror. A local mirror directory with `modules/` and `authors/id/` subtrees is
supported for tests. `--refresh` fetches the index and archive again. Registry
lookup is optional and does not require an AI agent.

The registry root contains `registry.json`. The installer combines the CPAN
author from the resolved archive with its distribution name, then uses jump
consistent hash to choose a data repository and a fixed SipHash prefix to
find that author's patch index. A registry without `registry.json` retains
the original flat layout for compatibility. The current shared registry has
one active data repository. CPAN archive paths may include subdirectories
under the author; those directories do not change the registry key.

The command reports the archive's SHA-256 digest for reproducibility. This
checkpoint calculates the digest but does not yet authenticate it against
independent CPAN checksum metadata. Install writes phase logs and a JSON
receipt under the cache's `work/` directory. It stops before installation
when configuration, build, or tests fail. A configure step must create its
Makefile or Build script even if the process exits zero. The installer resolves
required prerequisites from the release metadata, then checks generated
`MYMETA.json` or `MYMETA.yml` after configuration for additional required
prerequisites before building. Older metadata is converted before validation,
so fixable fields such as a missing abstract do not block dependency
resolution. For releases with no META file, the archive filename supplies the
distribution name and version for registry lookup; generated MYMETA can still
provide prerequisites after configuration. Optional prerequisites are not
installed automatically. `Build.PL`
distributions need their build
tool, commonly `Module::Build`, installed or declared as a required build
prerequisite.

The runner uses cpanm's noninteractive build signals. Configure, build, and
test set `PERL_MM_USE_DEFAULT=1`; test also sets
`NONINTERACTIVE_TESTING=1`. Configure sets the CPAN-running markers used by
some older build scripts, plus `PERL5_CPAN_IS_EXECUTING` for Makefile.PL.
Each build phase identifies the current interpreter through `PERL` and sets
`PERL_USE_UNSAFE_INC` from
the distribution's `x_use_unsafe_inc` metadata when present, or to `1` for
older distributions, while preserving an explicit caller setting. The
variables are scoped to the child command. The installer does not set
`AUTOMATED_TESTING`, which denotes smoke testing rather than installation,
and it leaves color settings such as `NO_COLOR` to the distribution's tests.

## Parallel builds

`--jobs K` (or `jobs` in the `[install]` table) builds independent releases
in parallel, for both `install` and `install-ported`. The default is four
build workers. A single `install Module --jobs 1` uses the sequential path.
The scheduler:

- The release graph is resolved breadth-first from each release's static
  metadata before anything is built. Every module name that resolves to the
  same CPAN release shares one node, so no release builds twice.
- Up to K workers build releases whose prerequisites are installed. A failed
  release keeps its receipt and enters the repair queue if an agent is
  configured. Independent builds carry on. Dependents wait for repair and
  start as soon as it installs the prerequisite. If repair fails or its
  budget is exhausted, those dependents are reported as `blocked` with
  "dependency failed: <release>: <reason>".
- Dependency cycles are detected on the graph, and their members fail with
  the cycle path.
- When a release's configured metadata (`MYMETA`) names prerequisites that
  are not yet available, its worker stops after configure. The scheduler
  then adds those releases to the graph and builds the release again from a
  clean copy. The stopped attempt is written to `deferred.json`, not to a
  receipt.
- The install phase holds an exclusive lock on
  `PREFIX/.xperl-install.lock`, so two workers never install at once. Test
  phases may still run while another release installs into the same prefix.
- Build workers never call a repair program. The separate repair pool starts
  as failures arrive, with one worker by default. `--repair-jobs K` or
  `repair_jobs = K` in `[install]` sets its size independently of `--jobs`.

`install` also accepts several module names, or `--from FILE` with one module
per line (blank lines and `#` comments are ignored). Such a batch uses the same
scheduler, even with one job: each module is resolved once, prerequisites they
share are built once, and a failure does not stop the other modules. The
output adds a `modules` list with each requested module's status, release,
receipt and reason, and the command exits non-zero if any of them failed.

`install --jobs K` prints a `nodes` list with each release's status, reason,
receipt and prerequisites. Receipts record each phase's start and finish
times.

## Phase timeout

Each configure, build, test, and install phase has a time limit: by default
3600 seconds. `--phase-timeout SECONDS` (or `phase_timeout` in the
`[install]` table) changes it, and `0` removes it. A phase that runs longer is
stopped together with every process it started, because on Unix-like hosts
each phase runs in its own process group. It is reported as "PHASE timed out
after N seconds", and its receipt marks the phase `timed_out`. This keeps one
hung test, for example a test that runs a command which waits on its input,
from stalling a long or parallel run.

## Native libraries

Distributions that bind a C library need its headers, libraries and
pkg-config files. The compiler does not search Homebrew's prefix on Apple
silicon (`/opt/homebrew`), so by default the installer adds the Homebrew
installation's `include`, `lib` and `lib/pkgconfig` directories to `CPATH`,
`LIBRARY_PATH` and `PKG_CONFIG_PATH` for every phase. They come after any
value already in the environment. The installation is `HOMEBREW_PREFIX` when
that is set, otherwise on macOS the first of `/opt/homebrew` and `/usr/local`
that contains `bin/brew`.

`--native-prefix DIR` (repeatable), or `native_prefixes = ["DIR", ...]` in the
`[install]` table, replaces the detected prefix. `--no-native-prefix` adds
none. Receipts record the prefixes used in `native_prefixes`.

A distribution whose `Makefile.PL` looks for headers only in a fixed list of
directories (Image::Scale, Image::Magick) does not see these paths and needs
a port.

## Optional repair command

`--agent codex` or `--agent claude` enables a built-in repair adapter after a
failed configure, build, or test phase. Named TOML profiles configure those
adapters or select another tool. `--repair-command PATH` accepts a custom
executable using the protocol below. `--repair-attempts N` limits repair calls
for one release; the default is sixteen. `--repair-timeout SECONDS` limits each
call to 600 seconds by default. This is a hang guard, not a measure of repair
quality. An unchanged source edit stops retries early.
`--repair-interval SECONDS` spaces agent call starts across installer processes
owned by the same user; the default is ten seconds.

A repair program may start a paid AI agent. `--repair-limit N` optionally
caps calls across the whole run. When set, the scheduler reserves each
repair's possible calls and returns unused calls when it finishes. Later
failures are reported when that budget is exhausted. Without it, every
failed release can use its own attempt allowance. With the default one
repair worker, a per-user lock
also serializes agents started by separate installer processes. Selecting
more than one repair worker permits concurrent agents. A selected agent
profile can supply `attempts`, `timeout`, `interval`, and `limit`.

The installer never calls a repair program without an explicit selection.
Custom commands must be executable files. A custom command runs with the
distribution source directory as its working directory and receives one
argument: the absolute path to a JSON request file.

The request has `schema: 1`, the module and CPAN archive identity, source
digest, XPerl executable and version, attempt number, source directory,
failed phase, command, log path, and `response_path`. When a registry patch
set names migration recipes, `recipes` contains their IDs and absolute
Markdown paths. If a registry is configured, `registry` gives its root.
`platform.build` describes the interpreter configuration and `build_id`
identifies it. `applied_patches` lists copies of the registry patches applied
to this source, with their digests. The agent should retain those changes in
its consolidated repair and check whether the result is valid for other builds.
`known_patches` supplies copies from all recorded releases of the same author
and distribution as context, with their release and patch-set identities.
An older patch is guidance; it is not necessarily applicable to this release.
`guidance` tells provider wrappers to stop an unproductive debug/change loop
and return an honest handoff to the human.
The repair program may inspect and change any available checkout needed to
resolve the failure, including the installer, registry, or XPerl core during
bootstrap development. The wrapper determines which checkouts are available.
The program should exit zero when a source edit is ready for another
build. A nonzero exit or no source change stops repair. The installer reruns
configuration,
build, and tests after each successful repair call, and records every phase
and request in the receipt. Installation runs only after the tests pass.

The installer records a patch only for changes to the CPAN distribution. If
the repair changes the installer or registry, the worker must review and
commit that change separately. A core change requires rebuilding and
reinstalling XPerl, then resuming with the installed interpreter; the current
process cannot switch interpreters. These are workflow requirements, not a
restriction on what the repair worker may investigate or edit.

When the log identifies a missing CPAN prerequisite that the release did not
declare, the repair program should leave the source alone and write a JSON
response at `response_path`:

```json
{
  "schema": 1,
  "status": "needs_cpan_dependency",
  "module": "Class::Accessor::Lite"
}
```

The installer adds the module to its dependency graph, builds it, then retries
the release. `range` may specify a required version; the default is `0`.
The response file lives inside the distribution source directory, beside the
files being repaired.

When the log identifies a missing host dependency, the repair program should
instead write:

```json
{
  "schema": 1,
  "status": "needs_user_action",
  "action": {
    "kind": "system_dependency",
    "message": "Cyrus SASL development headers and library are missing",
    "install_hint": "Ubuntu/Debian: sudo apt install libsasl2-dev"
  }
}
```

`install_hint` is optional. An agent should name a package only after checking
the host's package manager or other reliable evidence. `kind` may instead be
`core_change` or `manual_step`. Exit zero after writing the response. The
installer records the action in the receipt and final JSON, stops retrying
that release, and continues unrelated builds. It never runs the suggested
command itself.

The repair worker may return `manual_step` when it cannot find a justified
next change. It should say what failed and what the human should inspect,
rather than guess or keep retrying. For example:

```json
{
  "schema": 1,
  "status": "needs_user_action",
  "action": {
    "kind": "manual_step",
    "message": "I cannot identify the cause of the XS crash; inspect the test log and backtrace"
  }
}
```

Agent wrappers should pass the request's `guidance` to the agent and
explicitly permit this answer. A report of uncertainty is useful work: the
installer keeps the failure evidence and can resume after a human supplies
a fix or new information. In unattended mode, it continues independent
releases, reports the action in `user_actions`, exits with a failed status,
and includes a `resume` command. It does not wait for human input unless
`--action-shell` was explicitly requested in an interactive terminal.

Every `install` saves its request list and effective options as
`WORKDIR/install-session.json`. After completing a missing dependency, run
`xperl-install install --resume --workdir WORKDIR`. Installed modules satisfy the
retry, while failed and blocked releases are attempted again. The saved
session requires the same installed XPerl executable and version.
`--action-shell` offers an interactive alternative for `install` and
`install-ported`: after the batch finishes,
it prints all queued actions, opens the user's shell, and retries the batch
once when the shell exits. It requires a terminal and never opens a shell in
an unattended run.

After a successful repair, the installer writes `proposal.patch` next to the
receipt. It compares repaired source files with the untouched CPAN archive,
includes files added by registry patches or the repair command, and leaves
ordinary build products out. The patch includes any known registry changes
so it applies directly to the original release. A dry run against a fresh
copy of that release must pass before installation. The receipt records the
proposal path, file list, and SHA-256 digest for review.

When `--registry` names a writable checkout, the installer registers a
successful repair automatically. It writes the patch, an exact release and
XPerl version selector, and portable test evidence. It links recipes whose
source signatures appear in the patch. The receipt records the registration
paths and digest. If registration fails, installation remains successful but
the receipt records the error and the installer warns on stderr. The local
proposal remains available for retry. A later install selects the registered
patch without an AI agent.

The repair program can be any agent wrapper that accepts this protocol. A
Codex wrapper, a Claude wrapper, or another tool receives the same request
and must return the same exit status and source edits. The request contains
no provider-specific fields. Credentials and provider settings belong to the
selected provider profile, not its receipts. The installer does not bundle
an AI service.

## Publishing completed distributions

With a Git ports registry, `--publish auto` is the default. Every completed
distribution is committed and pushed immediately when it adds new facts.
This includes successful builds needing no patch, successful repairs, and
unresolved failures. An already installed module produces no build evidence.
Repeating the same result creates no duplicate observation or empty commit.

Publication uses the configured upstream of the ports repository's `main`
branch, including its remote name and push URL. Configure that upstream to
the shared ports repository. It need not be named `origin`. Git and
`git-compose-commit` must be on PATH, with a Git author name and email
configured. The installer logs its publication mode and destination branch.

The installer keeps a separate checkout under `WORKDIR/publication/`. Known
patches and local registry changes are copied there, and subsequent repair
registration uses that checkout. Your source checkout, staged changes and
current branch are left alone. Pull the ports repository normally to see
the published results there. Only the completed distribution's files and
linked recipes enter each commit. Human summaries and the XS patch catalog
are regenerated from committed results when the run drains.

Choose a publication mode with `--publish MODE` or `[install].publish` in
TOML:

- `auto`: push directly. A clear write-permission refusal switches to a
  batch fork pull request. Network failures and conflicting repairs remain
  queued for retry or review.
- `direct`: push directly and keep every rejected push queued.
- `pr`: batch results locally, then push a contribution branch to a GitHub
  fork and create or reuse one pull request when the run drains. This needs
  an authenticated `gh` command and permission to create a fork and PR.
- `off`: keep the existing local registration behavior without Git
  publication.

A publication error does not change a successful build into a failure.
The installer reports publication separately in its JSON result and retains
the immutable receipt, logs and pending queue under the work directory.
Resume with the same work directory to retry pending publication without
rebuilding completed releases:

```sh
xperl-install install --resume --workdir /path/to/work
```

Concurrent status observations are merged. Conflicting source patches are
left for review and revalidation. Publication never resolves a race with a
force push. Non-Git registry snapshots and installs without a registry keep
working without Git or a hosting account; snapshots do not have an automatic
publication destination.

## Validating recorded ports

`install-ported` rebuilds every release that the ports registry records as
successfully built under XPerl, whether or not it needed a patch. It checks
that the current XPerl, installer, and registry still work together, and it
exposes stale patches, installer defects, portability problems, and XPerl
regressions. Use a fresh prefix and work directory for each validation, and
keep one download cache across runs:

```sh
validation_prefix="$PWD/tmp/ported-prefix"
export PERL5LIB="$validation_prefix/lib/perl5:$prefix/lib/perl5"
"$prefix/bin/perl" "$prefix/bin/xperl-install" install-ported --dry-run \
    --registry ../xperl-cpan-ports
"$prefix/bin/perl" "$prefix/bin/xperl-install" install-ported \
    --registry ../xperl-cpan-ports --prefix "$validation_prefix" \
    --workdir "$PWD/tmp/ported-work"
```

`--dry-run` prints the selection and the patch set chosen for the running
XPerl without building anything; add `--json` for a machine-readable plan.
`--only AUTHOR/Distribution` and `--exclude AUTHOR/Distribution` restrict
the run and may be repeated. A run continues after individual failures and
writes `report.json` and `summary.txt` under `WORKDIR/install-ported/`. The
report records the platform, XPerl version and configuration, registry
revision, and for every entry its source identity, recorded and applied
patch sets, status, failed phase, test summary, and receipts. The command
exits non-zero when any entry failed or was skipped. No repair program runs
unless `--agent` or `--repair-command` is given.

Selection rules:

- Candidates are the `installed` observations in every `status.json` under
  each configured registry repository. A record that is not at the location
  the placement rules give for its author and distribution is reported as
  invalid and ignored.
- One release is chosen per author and distribution. Observations are
  grouped by exact archive path and source hash. Releases with a success
  under the running XPerl version come first, then the highest release
  version, the most recent success, and the archive path. A release whose
  latest observation failed is still selected and flagged in the report.
- The recorded archive is fetched by its CPAN path, never replaced with the
  current CPAN index answer. A different source hash is reported as
  `skipped` with "source changed", and a missing archive as `skipped` with
  "archive unavailable".
- Registry patches follow the ordinary rules for the exact release, source
  hash, and running XPerl version.
- Prerequisites are resolved as in an ordinary install, except that a
  prerequisite whose CPAN distribution is itself selected uses the recorded
  release. Each release is built at most once per run: an entry already
  built as a dependency is reported as `satisfied`, and dependents of a
  failed release fail with "dependency failed" without rebuilding it. A
  dependency cycle fails the entries involved and names the cycle.
- Each selected release is built from its recorded archive even when the
  running XPerl already provides the module.

A second run in the same work directory requires `--resume`. Resuming keeps
an earlier success only when its receipt still exists and the XPerl binary,
version, prefix, source hash, and selected patches are unchanged. Earlier
failures are always rebuilt and never reported as successes.

Receipts record the platform (operating system, architecture name, compiler,
make program, thread support, and XPerl commit), so results from different
hosts can be kept apart when they are imported into the ports registry.
