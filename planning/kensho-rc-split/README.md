# Task::Kensho RC workload split

The 20 task wrappers, including Task::Catalyst, expand to 143 module targets
from 137 indexed distributions. The module targets are partitioned by
distribution so two modules from the same release have one repair owner:

| Owner | Platform | Distributions | Module targets | Input |
| --- | --- | ---: | ---: | --- |
| Codex | Linux | 68 | 74 | [codex.txt](codex.txt) |
| Claude | Darwin | 69 | 69 | [claude.txt](claude.txt) |

This balances distribution count, not estimated build time. These are task
targets, not the complete transitive dependency graph. The installer resolves
and schedules prerequisites normally, including dynamic requirements. Some
targets are bundled or already installed and require no build. Shared
prerequisites can be needed on both platforms; coordinate repairs by CPAN
author/distribution/version and announce a claim before editing a common patch.

[manifest.json](manifest.json) records every target's owner, indexed CPAN
release, minimum version requirement and originating task. It records wrapper
source hashes and the CPAN index digest used for generation. The `.txt` inputs
contain module names for the installer's `--from` option. Check the three
nonzero minimum requirements in the manifest when reusing an older installed
Catalyst, Catalyst::Devel, or Catalyst::Manual.

Follow [the RC handoff](../rc-stack-validation-handoff.md) to build and verify
the installed RC interpreter, install the tooling, configure the repair agent,
and record results. From the umbrella directory, Claude's command is:

```sh
"$rc_perl" "$rc_prefix/bin/xperl-install" install \
    --prefix "$rc_prefix" --registry "$PWD/xperl-cpan-ports" \
    --workdir "$PWD/tmp/kensho-rc-claude-work" \
    --jobs 4 --repair-jobs 1 --agent claude --config /path/to/agent.toml \
    --from "$PWD/xperl-installer/planning/kensho-rc-split/claude.txt" \
    > "$PWD/tmp/kensho-rc-claude.log" 2>&1
```

Matt selected `model = "claude-opus-5-5"` in `[agents.claude]` for this run.
Codex uses `codex.txt`, `--agent codex`, and its own work directory and log.
Do not start an additional Linux AI worker while the existing Linux batch
is repairing; finish or gracefully stop that batch before starting the list.
The live Linux batch already covers Dist::Zilla, Dancer, Plack, Catalyst and
Sereal; these roots stay on Codex where they occur in the unrolled list.

Preserve one portable consolidated patch per release and test that patch
on each platform before adding platform-specific validation evidence. Share
stalled repairs with source identity, failure excerpts, build profile,
current patch and blocked dependents. Successes must reach the ports registry.
Import failures and user actions too. After both halves finish, verify the
whole Task::Kensho selection separately; completing half does not establish
that the full task installs on that host.

Regenerate from the installer checkout with the installed RC interpreter:

```sh
"$rc_perl" planning/split-kensho --output planning/kensho-rc-split
```

The generator reads task release metadata using the normal shared cache. It
resolves leaf modules through the package index without downloading their
sources or executing distribution build scripts. A newer index or task
release can change the allocation; coordinate a replacement before publishing
it during an active run.
