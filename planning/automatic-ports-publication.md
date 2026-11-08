# Publish every completed distribution

Publication belongs to the installer. A supervising human or coding agent
must not be responsible for noticing completed work and pushing it later.

Every completed distribution produces portable status evidence: successful
builds without changes, successful patched builds, and unresolved failures.
Preserve release identity, source and patch hashes, interpreter version,
actual build profile, test results and actionable blockers. Identical facts
create neither another observation nor an empty Git commit. An already
available module is not a new build result.

For users with direct push permission, commit and push each completed
distribution as its result becomes available. Repairs publish their complete
patch and applicable recipes with the evidence. Successful builds needing no
patch publish status just as promptly. Yves and Matt both have direct ports
push permission; their ordinary completed work should go directly to ports
main rather than await a batch PR.

Without direct permission, retain results on a contribution branch or fork
and submit a batch pull request. Distinguish lack of push permission from
network failure, a concurrent remote update, or missing credentials. A
transient failure must not silently change publication mode or discard work.

Keep publication state separate from build state. A push failure does not
make a successfully tested distribution fail its build. Retain a durable
publication queue, report the exact blocker, and retry without repeating
the build. Independent builds and repairs should continue. Stop/resume must
preserve pending publication work as well as build work.

Serialize Git mutations across build and repair workers. Stage only the
completed distribution's changes and related recipes; preserve unrelated
working-tree and index contents. Handle concurrent status observations by
merging facts and applying the existing semantic deduplication. Conflicting
source patches need review and revalidation, not last-writer-wins replacement.
Never use a force push to resolve publication races.

Use Git's configured branch upstream to identify the remote and destination.
Do not assume that a remote named origin is the ports repository, or that
the caller's current branch is the publication destination. Use an isolated
publication checkout when needed to protect a developer's unrelated work.
Include a clear explanation of the publication mode and destination in logs.

Import a completed receipt incrementally rather than rescanning every cached
build and every status record. Generated human summaries and the native
patch catalog must be refreshed from coherent published data. They must not
reference another worker's uncommitted patch or candidate result.

The normal CPAN installation path remains usable without a Git checkout,
ports registry, or AI provider. Read-only registry snapshots remain valid
patch sources. Their results still need a clear local contribution location
when publication is requested and a remote destination is unavailable.

Unreviewed candidates are separate from validated portable repairs. A worker
must not claim that regenerating expected output for one host establishes a
patch valid on previously tested hosts. Keep such investigations visible,
with reproducible evidence and a human handoff when necessary.
