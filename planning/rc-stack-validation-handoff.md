# Refcounted-stack validation handoff

This is the shared task for Codex on Linux and Claude on Darwin. The goal is
to test the normal installed-XPerl workflow with `PERL_RC_STACK`, preserve
reusable repairs, and record exactly which configurations validated them.

## Repositories and current checkpoints

- [XPerl](https://github.com/demerphq/xperl), branch `xperl/main`:
  `573a695628` fixes aliased binary-operand stack ownership. Earlier fixes
  are `33344c78f5` (XGraph lifetime), `583875fe4a` (dispatch callbacks and
  custom `isa`), and `2e6cc28cfd` (`die`/`PROPAGATE` stack handling).
- [Installer](https://github.com/demerphq/xperl-installer), branch `main`:
  `05e5d45` adds built-in Codex/Claude adapters and graceful stop/resume.
- [Ports](https://github.com/demerphq/xperl-cpan-ports), branch `main`:
  `08fee801` records the Devel::Cover callback repair and recipe. Prior
  `a8227c38` includes Data::Printer/Data::Peek RC fixes and corrected build
  evidence. Use the latest main, including subsequent reviewed changes.

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

The immediate review task for Claude, while build authorization is pending,
is to review the installer adapters, especially the Claude CLI invocation,
TOML profiles, and resume. Fixture tests make no paid AI calls. Report
findings before editing files Codex may be changing.

Use the installer repository's `agent-comms` branch. Acknowledge the task,
state what is running or the exact blocker, and claim a distribution before
editing its shared patch. Poll about once a minute during active work. Keep
branches current, publish stable changes, and announce commits and PRs.
Do not assume a sent message has been accepted until there is a reply.

## Build a separate RC interpreter

Use a new perlbrew name and library tree. Never reuse ordinary-stack XS
binaries. Leave existing installations intact. From the umbrella workspace:

```sh
unset PERL5LIB PERL5OPT PERL_LOCAL_LIB_ROOT PERL_MM_OPT PERL_MB_OPT
mkdir -p tmp
git clone --branch xperl/main https://github.com/demerphq/xperl.git tmp/xperl-rc-source
git -C tmp/xperl-rc-source merge-base --is-ancestor 573a695628 HEAD

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
Codex defaults to `gpt-6.1-sol` with high reasoning effort. Claude uses its
configured CLI model unless a TOML profile specifies one. See the README's
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

Read `refcounted-stack-observation-v1` and
`refcounted-stack-callback-v1` in the ports recipes. Normal XS compatibility
stacks and instrumented callbacks may have different ownership contracts.
Check the actual call path. Do not hide a lifetime bug by changing expected
reference counts. Review the core refcounted-stack guidance before core work.

The installer writes successful distribution repairs to a writable registry,
including the consolidated patch, selector and portable evidence. Verify
registration succeeded. Assess every repair for a new or improved recipe.
Retain failures and human actions as well as successes:

```sh
"$rc_perl" xperl-cpan-ports/bin/import-receipts --cache "$PWD/tmp/darwin-rc-work"
"$rc_perl" xperl-cpan-ports/bin/build-xs-index
"$rc_perl" xperl-cpan-ports/bin/build-xs-index --check
```

Review generated records and diffs. Do not commit local home directories,
absolute build paths, raw logs, or duplicate identical observations. Do not
claim other configurations passed. Stage new source/registry files promptly
so `git clean` cannot discard them. Use `git-compose-commit`; commit and push
stable work, or open a PR when direct push is unavailable. Announce the
tested commit, build profile, modules completed, unresolved failures, and
patch/recipe PRs on the coordination channel.
