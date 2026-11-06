Help develop the XPerl package manager. Start by creating a light workspace:

```sh
mkdir perldev
cd perldev
git clone --branch xperl/main https://github.com/demerphq/xperl.git xperl
git clone https://github.com/demerphq/xperl-installer.git xperl-installer
git clone https://github.com/demerphq/xperl-cpan-ports.git xperl-cpan-ports
git clone https://github.com/demerphq/perl_core_skillz.git perl_core_skillz
git clone https://github.com/demerphq/git-compose-commit.git git-compose-commit
cp xperl-installer/planning/perldev-AGENTS.md AGENTS.md
```

Read `AGENTS.md` and follow the complete assignment in
`xperl-installer/planning/collaborator-bootstrap.md`. Read each repository's
instructions before changing it. If Rust and Cargo are available, install the
commit tool with `cargo install --path ./git-compose-commit`; otherwise ask Yves
for it.

Install XPerl into a dedicated Perlbrew installation named `xperl` where
Perlbrew is available. Always run the installer and CPAN builds with that
installed XPerl, with the installation target's `lib/perl5` on `PERL5LIB`.
Adapt the setup to your platform and record any differences.

Implement a resumable batch command that installs every distribution recorded
as successful in `xperl-cpan-ports`, including unpatched successes. Select the
recorded author and exact release; never silently substitute the current CPAN
version. Continue after failures, retain receipts and logs, and produce a
readable and machine-readable report. Share your selection rules with Yves
early, add focused tests, then run the command against a fresh installation
prefix to check the full recorded set.

Diagnose each failure from its receipt and log. Prefer a patch to a faulty
CPAN distribution, then a general installer fix, then a necessary registry
structure fix. Change XPerl core only when a minimal reproducer establishes a
core defect; rebuild and reinstall XPerl before continuing the installer run.
Record successful and failed results in the ports registry. Keep the installer
usable without an AI agent or registry for ordinary installs.

Work on named branches and coordinate shared files. Use `git-compose-commit`
for commits; ask Yves for it if unavailable. Leave Task::Kensho and its
dependencies to Yves.
