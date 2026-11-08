# Collaborator handoff: bootstrap XPerl and validate all known ports

This records the original assignment to implement `install-ported`. That
command exists now. For a fresh setup and current commands, use the
[bootstrap guide](bootstrap.md).

This was the brief given to a coding agent such as Claude Code. Read the
existing
[package manager plan](xperl-package-manager.md), the installer [README](../README.md),
and the ports registry's `README.md`, `FORMAT.md`, `SHARDING.md`,
`CONTRIBUTING.md`, and `status/README.md` before implementing the assignment.

## Objective and ownership

Build and validate an `install-ported` (or similarly clear) installer command
that attempts every distribution recorded as successfully built under XPerl.
Use it to check that the current XPerl, installer, and ports registry still
work together. Include distributions that passed without a patch as well as
those that needed a patch. Produce a report of successes, failures, skips,
selected source releases, patches, and logs. Yves is working on Task::Kensho
and its dependencies; leave those to him and coordinate before touching any
shared files he is editing.

The development agent may be Claude, Codex, or another coding agent. The
installer's optional repair-agent protocol remains separate and must not
require one particular provider. Ordinary installs must keep working without
an agent or a registry.

## Make a light `perldev/` workspace

The following example uses a Unix-like shell. Change the parent directory to
suit the host. A fresh clone of the core repository should be named `xperl/`:

```sh
mkdir perldev
cd perldev
git clone --branch xperl/main https://github.com/demerphq/xperl.git xperl
git clone https://github.com/demerphq/xperl-installer.git xperl-installer
git clone https://github.com/demerphq/xperl-cpan-ports.git xperl-cpan-ports
git clone https://github.com/demerphq/perl_core_skillz.git perl_core_skillz
git clone https://github.com/demerphq/git-compose-commit.git git-compose-commit
cp xperl-installer/planning/perldev-AGENTS.md AGENTS.md
mkdir -p tmp .ccache
export CCACHE_DIR="$PWD/.ccache"
```

The [git-compose-commit repository](https://github.com/demerphq/git-compose-commit)
documents its Cargo installation. If Rust and Cargo are available, run
`cargo install --path ./git-compose-commit` from `perldev/`, then check
`git-compose-commit --help`. If they are unavailable, ask Yves for the tool.

Read the new umbrella `AGENTS.md`, then `xperl/AGENTS.md` and the relevant
repository instructions. Check the skill mirror with
`perl_core_skillz/sync-agent-skills --check`; the core checkout is the
canonical source of those skills. This light workspace needs no separate
blead checkout. Fetch or compare blead only when a particular core change
requires it.

Use independent named branches for work. Keep caches, unpacked CPAN sources,
logs, and validation prefixes under `tmp/` or the installer's configured
cache. Do not commit those artifacts. Commit source, tests, documentation,
reviewed patches, recipes, and status records in their owning repositories.

## Build an installed XPerl with Perlbrew

On Unix-like hosts, install Perlbrew using its
[official installation instructions](https://perlbrew.pl/Installation.html),
initialize it, and make `perlbrew` available in the shell. Perlbrew accepts a
Git checkout as an install source and `--as` names the installation; check
`perlbrew help install` on the host for its exact options. From `perldev/`:

```sh
perlbrew install --as xperl "$PWD/xperl"
prefix="${PERLBREW_ROOT:-$HOME/perl5/perlbrew}/perls/xperl"
"$prefix/bin/perl" -e 'die "not XPerl\n" unless ${^XPERL_VERSION}; print "$^V XPerl ${^XPERL_VERSION}\n"'
"$prefix/bin/perl" -V
```

Do not require a global `perlbrew switch`: use `"$prefix/bin/perl"`
explicitly for the installer and CPAN build phases. This installed
interpreter represents the end user's environment. The source checkout's
`xperl/lib` must not be added to the installer's `@INC` or `PERL5LIB`.

If a demonstrated XPerl core defect needs a fix, edit and test it in `xperl/`.
Then reinstall the changed checkout into Perlbrew and verify the installed
binary before resuming the installer. On Perlbrew versions supporting it,
`perlbrew install --force --as xperl "$PWD/xperl"` replaces the named build;
confirm with the host's `perlbrew help install`. Use the uninstalled
`xperl/./perl` only while diagnosing or testing that core fix. Do not build
core changes into the installer's normal installation procedure.

Perlbrew is the reference development setup, not an installer dependency.
On a host without Perlbrew, configure, build, test, and install XPerl into a
dedicated prefix using that platform's normal Perl build tools. Use the
resulting installed binary for every installer run. Record the platform,
compiler, XPerl version and configuration, and any setup differences. Avoid
Linux-specific paths, shell utilities, or compiler flags in portable
installer code. XS distributions require a working compiler and build tools
for that host. Report platform limitations rather than hiding them with
skipped tests.

## Install and exercise the installer

From `perldev/xperl-installer/`, using the installed XPerl:

```sh
export PERL5LIB="$prefix/lib/perl5${PERL5LIB:+:$PERL5LIB}"
"$prefix/bin/perl" Makefile.PL INSTALL_BASE="$prefix"
make
make test
make install
"$prefix/bin/perl" "$prefix/bin/xperl-install" resolve Sereal::Decoder
```

Use the make program reported by `"$prefix/bin/perl" -MConfig -e
'print $Config{make}'` when it differs from `make`. Run `make disttest` (or
the equivalent make program) before publishing an installer change. The
installer's `README.md` covers TOML configuration, shared cache and work
directories, registry selection, optional repair wrappers, and receipts.

For a normal install, put the target's `lib/perl5` first on `PERL5LIB` so
modules installed there are visible to later dependencies. The installed
XPerl's core libraries remain on its ordinary `@INC`. For example, from
`perldev/`:

```sh
validation_prefix="$PWD/tmp/ported-prefix"
mkdir -p "$validation_prefix"
export PERL5LIB="$validation_prefix/lib/perl5:$prefix/lib/perl5"
"$prefix/bin/perl" "$prefix/bin/xperl-install" install \
    --prefix "$validation_prefix" \
    --registry "$PWD/xperl-cpan-ports" \
    Sereal::Decoder
```

Do not use an existing site library to claim a fresh validation passed. Keep
one download cache across runs, but give the validation a fresh install
prefix and a separate work directory so its receipts and logs are clear.

## Implement the batch install procedure

Add a documented CLI mode and a small reusable API rather than an external
script that bypasses the installer. Reuse the existing resolver, download,
registry patch, dependency, build, test, install, and receipt code paths.
Define selection rules before coding and share them with Yves early.

- Enumerate successful registry observations across the configured shard
  layout. Select a recorded CPAN author and exact release for each
  distribution. Make the selection deterministic and describe how multiple
  successes, failures after successes, and XPerl version ranges are handled.
- Never silently replace a recorded author, archive version, or source hash
  with the current CPAN default. Report missing or changed upstream archives
  explicitly. The CPAN index remains authoritative when the user names a
  module without an author; this batch procedure has recorded identities.
- Apply only patches whose version and XPerl constraints match. Check source
  and patch hashes and record the selected registry revision. Avoid assuming
  a single repository or a flat registry layout.
- Continue after an individual distribution fails. Preserve its phase logs
  and receipt, then summarize installed, failed, skipped, and already
  satisfied entries with reasons. Avoid duplicate work for shared
  dependencies and detect cycles. Make a long run resumable without silently
  treating an earlier failure as a success.
- Provide a preview or dry-run of the selected releases. Write a
  machine-readable report as well as a readable summary, including platform,
  XPerl version and configuration, source identities, patches, tests, and
  receipt paths. Do not invoke an AI repair program unless explicitly
  selected.
- Add focused tests using a local CPAN fixture and registry fixture for
  selection, author collisions, exact release and hash checks, patch
  applicability, shared dependencies, cycle handling, continuation after
  failure, resumption, and reporting. Then run the installer suite and
  `disttest` with installed XPerl.

After the focused tests pass, run the batch procedure against a fresh prefix
and the shared ports registry. Start with a small known set, including a
patched XS distribution such as Sereal::Encoder, then attempt the full set of
recorded successes. The full run is intended to expose stale patches,
installer bugs, portability problems, and XPerl defects. Do not count a
historical success as a success on this host until its current build and
tests pass. Keep Task::Kensho out of your assigned work even if it appears in
an unresolved-status report.

## Diagnose failures and choose the right change

Read the failing receipt and phase log. Reproduce the issue against the
original CPAN release, then identify the layer that owns the defect. Apply
this preference order when the evidence permits:

1. Patch the distribution's incorrect source or tests against the original
   release. Prefer changes that also work on ordinary Perl. Use
   `#ifdef XPERL_VERSION` for XPerl-specific XS implementations.
2. Fix a general installer defect in resolution, dependency handling, build
   environment, configuration, validation, or reporting. Do not add an
   installer workaround for a defective distribution test.
3. Change the ports registry structure only when a real portability or
   scaling problem requires it. Preserve the author/distribution identity,
   shard configuration, and existing status history.
4. Change XPerl core only after a minimal reproducer demonstrates a core
   defect. Test the core change, reinstall XPerl, and rerun the normal
   installer workflow with the installed binary.

A failed test is evidence, not automatically an XPerl incompatibility. Check
platform assumptions and environment first. If a test depends on a color or
other environment setting, the test should establish its own conditions.
Prefer structured XPerl diagnostic codes and parameters over brittle
rendered exception strings. For recurring fixes, add a migration recipe.
Keep patches against original CPAN archives, not permanent forks.

Record both successful and failed observations in the ports repository, with
upstream version and source hash, XPerl version, applied patch hashes, phase
results, test summary, and platform. Import receipts using the registry's
`bin/import-receipts` instructions; review the resulting data before
committing. Commit each reviewed registry update so later runs can reuse it.
Do not claim platform-wide compatibility from one host's result.

## Collaboration and deliverables

Use `git-compose-commit --help` and the workspace `AGENTS.md` guidance for
commit messages. If `git-compose-commit` is unavailable, ask Yves for the
tool rather than silently using `git commit -m`. Keep changes on named
branches, make reviewable commits, and verify the destination branch before
pushing. Coordinate before editing files another collaborator is changing.

`planning/xpw` is an optional bash helper for recurring workspace chores. It
runs commands in a clean environment with the installed XPerl first on
`PATH`. It wraps building and testing XPerl from source (`srcbuild`,
`coretest`), the porting steps (`fetch`, `unpack`, `mkpatch`, `entry`), the
reading and posting of agent-comms entries (`comms read|take|watch|post`), and
the resolution of status-file conflicts during a ports rebase (`restatus`).
Run `planning/xpw help` for the commands and the `XPW_*` settings. Symlink it
into your `PATH` if useful; it locates the workspace from its real path.

Deliver the batch command and its tests, documentation and example command,
a full-run report with linked receipts and unresolved failures, and reviewed
ports patches or recipes produced by that run. State which results were
reproduced on this host and which remain historical records. Explain any
XPerl core changes and show the installed XPerl version used for final
validation. Leave Task::Kensho to Yves.
