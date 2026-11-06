# XPerl Installer Contributor Guidance

Write colloquial, modern Perl. Use XPerl features where they make the code
clearer. Keep functions focused and give each logical block room to breathe.
Prefer a named helper to a long block that mixes scheduling, I/O, and state
changes.

Structure code and tests so a reader can follow the intent on the first pass.
Put a short `#` comment before a logical block whose purpose is not obvious
from its name and statements. Explain notable ordering, ownership, and error
handling decisions. Keep comments about why the code works as it does, rather
than narrating each line.

Use POD for public interfaces, command behavior, and contributor-facing
documentation. Use `#` comments for local implementation details. Apply the
same spacing, structure, and explanation to tests: name the behavior under
test, keep fixture setup separate from assertions, and make failures useful
to diagnose.

Run the installer and its tests with an **installed XPerl**. A core checkout
is for core fixes and focused core testing; reinstall XPerl before validating
the installer against a core change. Preserve ordinary CPAN installation
without an AI agent or a patch registry.

For changes in the perldev workspace, also follow the workspace `AGENTS.md`
and `style_rules/` guidance. Use `git-compose-commit` for commits.
