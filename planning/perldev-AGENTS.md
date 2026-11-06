# XPerl collaborator workspace instructions

This file is meant to be copied to `perldev/AGENTS.md` in a light collaborator
workspace. Read the instructions in the target repository before editing it.

## Repository map

- `xperl/` is the XPerl core checkout. Use its `xperl/main` branch as the
  project baseline. Read `xperl/AGENTS.md` and the relevant skills in
  `xperl/.agents/skills/` before core work.
- `xperl-installer/` is the standalone XPerl-native CPAN installer. Its
  `planning/xperl-package-manager.md` explains the design; `README.md`
  documents the current commands.
- `xperl-cpan-ports/` stores patches, migration recipes, and both successful
  and failed build observations. Read its `README.md`, `FORMAT.md`, and
  `CONTRIBUTING.md` before changing registry data.
- `perl_core_skillz/` mirrors Perl agent guidance. Its generic skill tree
  should stay synchronized with `xperl/.agents/skills/`. Use
  `perl_core_skillz/sync-agent-skills --check` to inspect it. Do not overwrite
  unrelated changes in either tree.
- `tmp/` holds disposable local builds, logs, and validation prefixes.
  `.ccache/` is an optional workspace-local compiler cache. Neither is a
  source repository.

## Installed XPerl is the installation runtime

Run the installer and every CPAN configure, build, test, and install phase
with an installed XPerl. On Unix-like hosts, use a Perlbrew installation
named `xperl` and set `PERL5LIB` to include the target prefix's `lib/perl5`.
Do not put `xperl/lib` from the source checkout on the installer's `@INC`.
Use the uninstalled `xperl/./perl` only while developing or testing a core
fix. Rebuild and reinstall that fix into Perlbrew before resuming the normal
installer run.

On hosts without Perlbrew, use an equivalent installed XPerl in a dedicated
prefix and document the difference. Do not substitute system Perl for XPerl.
Keep platform-specific results separate in receipts and reports.

## Diagnose the layer that failed

Start with the phase log and receipt. Reproduce failures against the original
CPAN release. Prefer a patch to the distribution when its code or tests are
wrong. Change the installer for general resolution, dependency, build, or
reporting defects. Change the registry structure only for a demonstrated
portability or scale problem. Change XPerl core only for a demonstrated core
defect. A core fix needs focused core tests, a fresh Perlbrew reinstall, and a
new normal installer run.

Keep patches against original CPAN archives. Preserve ordinary Perl behavior
where practical; use `#ifdef XPERL_VERSION` for XPerl-only XS changes. Import
both successful and failed observations into the ports registry. Record the
XPerl version, CPAN author and release, source hash, selected patches, test
result, and platform. Commit reviewed registry changes as they are made.

## Collaboration and commits

Work on a named branch. Coordinate ownership of shared files before editing
so parallel work does not overwrite another person's changes. In this
collaboration, Yves owns Task::Kensho and its dependencies.

Use `git-compose-commit` to compose commits: a concrete subject of at most
72 columns and a body explaining the outcome, implementation, and tests. If
that command is unavailable, ask Yves for it rather than silently switching
to `git commit -m`. Do not commit generated build products, caches, or
credentials. Verify the intended remote branch before pushing.
