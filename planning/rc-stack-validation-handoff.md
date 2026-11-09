# Refcounted-stack validation handoff

This is the shared task for Codex on Linux and Claude on Darwin. The goal is
to test the normal installed-XPerl workflow with `PERL_RC_STACK`, preserve
reusable repairs, and record exactly which configurations validated them.

## Repositories and current checkpoints

- [XPerl](https://github.com/demerphq/xperl), branch `xperl/main`:
  `8903238ce7` includes the parser evaluation-order audit. Generic fixes
  `431373cd01` and `abc49230f7` sequence parser operations and correct
  multiline `use` attribution. `573a695628` fixes aliased binary-operand
  stack ownership. Earlier fixes
  are `33344c78f5` (XGraph lifetime), `583875fe4a` (dispatch callbacks and
  custom `isa`), and `2e6cc28cfd` (`die`/`PROPAGATE` stack handling).
- [Installer](https://github.com/demerphq/xperl-installer), branch `main`:
  `23e8a67` adds verified clean-replay recovery for rejected artifacts.
  `b6dc330` protects newer registry data when a caller checkout is stale.
  `9198352` keeps agent notes local and out of patches. `3d2cfb7` adds
  native-source coverage and recorded replay queues. `ccd95ee` adds
  upstream issue/PR research to repair requests and both
  adapters. `c0ee4bc` publishes completed distributions automatically.
  Built-in Codex/Claude adapters and graceful stop/resume are available.
- [Ports](https://github.com/demerphq/xperl-cpan-ports), branch `main`:
  `746ec035` records the completed native-source RC coverage and coroutine
  recipe. `776d20cb` refreshes the catalog after accepting the fixed-core
  Devel::Cover patch. `530a368c` records its Linux RC pass. The registry
  includes the Ref::Util::XS provider repair, an unmodified Type::Tiny pass,
  and reconciled Linux receipts. Use the latest main, including subsequent
  reviewed changes.

Read each repository's instructions and the workspace guidance before
editing. The general setup is in [collaborator-bootstrap.md](collaborator-bootstrap.md).
This task uses an installed interpreter. A core build tree is for core
development and focused core tests, then must be reinstalled before use by
the installer. Do not put the core checkout's `lib` on the installer's `@INC`.

## Ownership and coordination

Codex owns the Linux RC rebuild and batch: Dist::Zilla, Dancer, Plack,
Catalyst, Sereal, Sereal::Encoder and Sereal::Decoder. The earlier saved
Linux session included Task::Kensho; start the new root list without it.

The current workload is unrolled in [kensho-rc-split/README.md](kensho-rc-split/README.md).
Claude owns its Darwin half (69 indexed distributions); Codex owns the Linux
half (68), in addition to the Linux batch above. Use the corresponding
`--from` list instead of starting the whole Task::Kensho wrapper.
Confirm local build authorization with Matt if required by that workspace.
The root lists are separate. Shared dependencies can occur in both trees;
claim repairs before editing their common patch. Codex will replay Darwin
repairs on Linux. A Linux pass is not a Darwin pass or vice versa.

The initial Linux root batch and assigned Linux half finished. This does
not establish that the combined selection passes on each host. Replay shared
repairs on the other platform and check the combined selection separately.
Data::Dump::Streamer is deferred by Yves. Carp::REPL requires it directly,
so its CatalystX::REPL dependency chain is deferred too.

Use the installer repository's `agent-comms` branch. Acknowledge the task,
state what is running or the exact blocker, and claim a distribution before
editing its shared patch. Poll about once a minute during active work. Keep
branches current, publish stable changes, and announce commits and PRs.
Do not assume a sent message has been accepted until there is a reply.

## Latest Linux validation

The installed perlbrew RC interpreter is XPerl v5.45.5 at `8903238ce7`.
Its full suite passed 3,313 files and 1,470,311 tests. The build uses GCC
13.3.0 on x86_64 Linux, double precision, and no threads, multiplicity,
debugging, long double or quadmath. These results establish only that profile.

The installed standalone installer passed 622 tests. Ref::Util::XS 0.117 passed 481 tests
in the interpreter's main site library, followed by unmodified Type::Tiny
2.010001 passing 9,159 tests with acceleration enabled. Devel::Cover 1.52
passed 86 files and 104 assertions with patch digest
`03c403682313c0fa1140057f5e1ff5aae235ff0c3e244b77251623b53df5a892`.
Test::Differences compares each complete coverage report in one assertion;
without it, the same suite counts individual output lines instead.
Want 0.29 passed 148 tests with its registered patch; unmodified HTML::Tree
5.07 passed 989 tests. The combined Linux follow-up satisfied all 142 selected
module targets from both owner lists, installing and testing 40 distributions
while reusing modules already available in the RC prefix. Every new result
was pushed, with no user actions or AI repairs needed. CatalystX::REPL was
omitted while its DDS chain is deferred, so this is not a complete
Task::Kensho installation.

The native-source sweep examined 1,525 distributions with recorded Linux
successes. It identified 217 native candidates and validated 216 on the
current installed RC build. The remaining candidate is the deferred DDS.
All 212 distributions selected by the initial replay queue now pass, and
the saved run finishes with publication pushed and no user actions. The
follow-up reused registered patches with AI repair disabled. Coverage and
the empty completed queue are in the ports repository under
`queues/rc-xs-linux/`.

Coro's repair is in the local `Coro-6.57/` source tree and registered against
the original CPAN release. All 223 tests pass on ordinary Perl v5.44.0,
ordinary Perl v5.45.4 with RC stacks and debugging, and RC XPerl v5.45.5.
The patch uses `PERL_RC_STACK` without requiring XPerl. See the ports recipe
`refcounted-stack-switch-v1` before adapting stack-switching custom ops.

Three older successful repairs failed registration because their proposals
included local paths. Clean replays of Overload::FileCheck, Hash::SharedMem
and Coro are now registered and pushed. Their rejected deliveries are
superseded with the original receipts retained. Data::Alias's AI call timed
out after preparing a working fix; a fresh installer replay validated and
published that preserved source work. No host package installation was
needed for these repairs.

The shared operational log is `tmp/xperl-rc-stack-install.log` in the
umbrella workspace. It includes the rebuild, tooling checks and replays.

## Build a separate RC interpreter

Use a new perlbrew name and library tree. Never reuse ordinary-stack XS
binaries. Leave existing installations intact. From the umbrella workspace:

```sh
unset PERL5LIB PERL5OPT PERL_LOCAL_LIB_ROOT PERL_MM_OPT PERL_MB_OPT
mkdir -p tmp
git clone --branch xperl/main https://github.com/demerphq/xperl.git tmp/xperl-rc-source
git -C tmp/xperl-rc-source merge-base --is-ancestor 8903238ce7 HEAD

perlbrew install --as xperl-rc-stack --no-patchperl -j4 \
    -Dusedevel -Accflags=-DPERL_RC_STACK "$PWD/tmp/xperl-rc-source"
```

Choose another unused source directory if that one exists. Choose a unique
perlbrew name if an existing `xperl-rc-stack` belongs to another task. For a
deliberate rebuild of the same RC installation, stop its installer first.
Use the host's compiler and SDK; do not copy Linux gcc settings onto macOS.
If ccache is available, use a workspace-local `CCACHE_DIR` and optionally
add `-Dcc='ccache cc'` to perlbrew's Configure options. Ccache is optional.

The essential option is `-Accflags=-DPERL_RC_STACK`. This is a compile-time
setting. A runtime flag or a renamed ordinary interpreter is insufficient.
Keep full tests enabled. Do not use `--notest` or install past a failed suite.
Perlbrew prints its build-log path; `tail -F` that file for progress.

After a successful installation:

```sh
rc_perl=$(perlbrew exec --with xperl-rc-stack perl -e 'print $^X')
"$rc_perl" -MConfig -e '
    die "not XPerl\n" unless ${^XPERL_VERSION};
    die "not an RC stack\n" unless Internals::stack_refcounted() & 1;
    print "$^X\n$^V\n$Config{git_commit_id}\n";
'
"$rc_perl" -V
rc_prefix=$("$rc_perl" -MConfig -e 'print $Config{installprefix}')
```

Record the full test summary, commit, and build profile. This starting
configuration adds RC stack support without deliberately enabling threads,
debugging, long double, or quadmath. Record what Configure actually selected.
Those other options require their own validation, not extrapolation.

## Install and use the tooling normally

Update the installer and ports main branches, keeping unrelated local work.
Install the installer distribution with the installed RC interpreter:

```sh
cd xperl-installer
"$rc_perl" Makefile.PL INSTALLDIRS=site
make
make test
make install
cd ..
```

The installer is `xperl-install`; the interpreter is XPerl. Install and sign
in to the desired coding-agent CLI separately. No wrapper script is needed.
Codex defaults to `gpt-6.1-sol` with high reasoning effort. Claude defaults to
`sonnet` unless a TOML profile specifies a model. See the README's
configuration section for `model`, `effort`, `executable`, and `add_dirs`.

Example Darwin batch, using the interpreter's own site library:

```sh
"$rc_perl" "$rc_prefix/bin/xperl-install" install \
    --prefix "$rc_prefix" --registry "$PWD/xperl-cpan-ports" \
    --workdir "$PWD/tmp/darwin-rc-work" \
    --jobs 4 --repair-jobs 1 --agent claude \
    --from "$PWD/xperl-installer/planning/kensho-rc-split/claude.txt" \
    > "$PWD/tmp/darwin-rc-install.log" 2>&1
```

Run the long command in an available tmux window or equivalent. Use
`tail -F tmp/darwin-rc-install.log` from the umbrella directory. If choosing
an independent installation prefix instead, include its `lib/perl5` and
architecture directory correctly when using that interpreter. The running
interpreter's own prefix uses the `site` layout and already searches its
site directories. Do not import an ordinary build's local::lib environment.

Use the shared default download cache. Build directories and logs belong to
the explicitly chosen RC work directory. Start with four build workers and
one AI repair worker. Each repair has a ten-minute timeout and bounded
retries; independent builds proceed while failed releases enter repair.
Missing host dependencies become recorded user actions rather than repeated
source-free AI calls. In unattended mode, record the blocker and continue
independent work instead of waiting for an absent human.

From another terminal, gracefully stop and later resume the batch:

```sh
"$rc_perl" "$rc_prefix/bin/xperl-install" stop --workdir "$PWD/tmp/darwin-rc-work"
"$rc_perl" "$rc_prefix/bin/xperl-install" install --resume \
    --workdir "$PWD/tmp/darwin-rc-work"
```

Stop drains active work and exits with status 2. Resume clears the stop
request and retains provider configuration. An explicit `--agent` replaces
a saved provider or old custom wrapper. Ctrl-C is not the cooperative stop.

## Repair, validation and publication

Prefer a distribution repair, then an installer repair, then a justified
registry portability change, then a demonstrated core fix. During bootstrap,
core investigation is allowed when the checkout is available. Rebuild and
reinstall a core fix before continuing installation. Without a core checkout,
report a reproducible core issue for review rather than modifying an end
user's installed interpreter.

Keep one consolidated compatibility patch per release, preserving fixes for
all supported configurations. Conditional code handles configuration
differences. Separate build evidence records where that exact patch digest
passed. The agent receives copies of applied and historically known patches,
the actual build profile, failure logs and linked migration recipes.

Before editing, check the upstream repository, bug reports, pending PRs and
relevant fixes using the release metadata resources in the request. Verify
that any existing report matches this failure and build configuration.
Record findings and public links through `upstream_research_path`. If access
is unavailable, record that and continue local diagnosis.

Read `refcounted-stack-observation-v1` and
`refcounted-stack-callback-v1` in the ports recipes. Normal XS compatibility
stacks and instrumented callbacks may have different ownership contracts.
Check the actual call path. Do not hide a lifetime bug by changing expected
reference counts. Review the core refcounted-stack guidance before core work.

The installer writes successful distribution repairs to its publication
checkout, including the consolidated patch, selector and portable evidence.
Verify registration succeeded. Assess every repair for a new or improved
recipe. With the default `--publish auto`, each completed distribution
commits and pushes its record, including successful unmodified builds and
failures. Explicit permission refusals switch to a batched fork PR. Network
failures retain pending publication for resume. Summaries regenerate when
the run drains. Pull the supplied ports checkout to see the shared results:

```sh
git -C xperl-cpan-ports pull --ff-only
"$rc_perl" xperl-cpan-ports/bin/build-xs-index --check
```

Use `--publish off` for candidate validation. After acceptance, replay against
current ports main in a fresh work directory. Do not enable publication by
resuming an old candidate-registry session. A maintainer backfilling older
receipts should use a fresh publication context tied to current ports main,
retaining each original receipt's build profile.

Review generated records and diffs. Do not commit local home directories,
absolute build paths, raw logs, or duplicate identical observations. Do not
claim other configurations passed. Stage new source/registry files promptly
so `git clean` cannot discard them. Use `git-compose-commit`; commit and push
stable work, or open a PR when direct push is unavailable. Announce the
tested commit, build profile, modules completed, unresolved failures, and
patch/recipe PRs on the coordination channel.
