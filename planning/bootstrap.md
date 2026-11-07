# Bootstrap the current XPerl installer

This guide starts from a clean workspace and uses an installed XPerl for every
installer command and CPAN build. The installer, core, and ports registry are
separate repositories. Perlbrew is the reference setup on Unix-like hosts;
it is not an installer dependency.

## Get the source

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

Keep `CCACHE_DIR` in the shell used for XPerl and CPAN builds when ccache is
installed. If your shell startup or build service starts a fresh environment,
set it there too. The installer does not require ccache.

Read `AGENTS.md`, then the target repository's instructions. Install
`git-compose-commit` from its repository before making commits. The old
[collaborator handoff](collaborator-bootstrap.md) records the original
`install-ported` assignment; that command is implemented now.

## Install XPerl

Install Perlbrew using its [official instructions](https://perlbrew.pl/Installation.html)
and initialize it in your shell. From `perldev/`:

```sh
perlbrew install --as xperl "$PWD/xperl"
prefix="${PERLBREW_ROOT:-$HOME/perl5/perlbrew}/perls/xperl"
"$prefix/bin/perl" -e 'die "not XPerl\n" unless ${^XPERL_VERSION}; print "$^V XPerl ${^XPERL_VERSION}\n"'
"$prefix/bin/perl" -V
```

Use this installed binary for the installer and CPAN builds. A core checkout
is only for developing and testing a core fix. After a core fix, reinstall
XPerl into Perlbrew and resume with the installed binary. Do not add
`xperl/lib` to `PERL5LIB`.

On a platform without Perlbrew, build and install XPerl into a dedicated
prefix with that platform's normal tools. Use the resulting installed binary
in the commands below. XS modules need a working compiler and build tools.

## Install the installer

From `perldev/xperl-installer/`:

```sh
"$prefix/bin/perl" Makefile.PL
make
make test
make install
"$prefix/bin/perl" "$prefix/bin/xperl-install" help
```

Use the make program printed by `"$prefix/bin/perl" -MConfig -e
'print $Config{make}'` if it is not `make`. The installer is installed into
XPerl's site library, which the installed interpreter searches automatically.
No `PERL5LIB` entry is needed for the installer itself.

## Try an isolated CPAN installation

From `perldev/`, choose a new validation prefix and work directory. The
target's `lib/perl5` must be visible when the installer checks prerequisites
and when you later load the installed modules:

```sh
validation_prefix="$PWD/tmp/validation-prefix"
workdir="$PWD/tmp/validation-work"
mkdir -p "$validation_prefix"
export PERL5LIB="$validation_prefix/lib/perl5"
"$prefix/bin/perl" "$prefix/bin/xperl-install" install \
    --prefix "$validation_prefix" --workdir "$workdir" \
    --registry "$PWD/xperl-cpan-ports" Sereal::Decoder
```

The registry is optional for ordinary CPAN installs. A shared download cache
defaults to `$HOME/.xperl/cache`; keep it across runs. Use a fresh prefix and
work directory when checking whether a recorded port still works. The
installer writes phase logs and receipts under the work directory. If a run
reports a missing host dependency, install it and resume with
`"$prefix/bin/perl" "$prefix/bin/xperl-install" install --resume --workdir "$workdir"`.

To check all recorded successful ports, first preview the selection, then
run the batch with four build workers. An AI repair worker runs only when an
agent is explicitly selected in the [configuration](../README.md#configuration).

```sh
validation_prefix="$PWD/tmp/ported-prefix"
workdir="$PWD/tmp/ported-work"
mkdir -p "$validation_prefix"
export PERL5LIB="$validation_prefix/lib/perl5"
"$prefix/bin/perl" "$prefix/bin/xperl-install" install-ported --dry-run \
    --registry "$PWD/xperl-cpan-ports"
"$prefix/bin/perl" "$prefix/bin/xperl-install" install-ported \
    --registry "$PWD/xperl-cpan-ports" --prefix "$validation_prefix" \
    --workdir "$workdir" --jobs 4
```

For test failures, inspect the receipt and phase log. Set
`PERL_DIAG_RENDER=json` when structured XPerl exception output would help.
Review the owning layer before changing code: a distribution patch first,
then a general installer fix, then a registry structure change, and finally
a demonstrated XPerl core fix. Record the outcome in the ports registry.

## Keep the repositories separate

The [installer README](../README.md) describes layouts, caches, repairs,
configuration, and receipts. The ports registry's `README.md`, `FORMAT.md`,
and `status/README.md` describe patch and status records. Commit reviewed
changes in the owning repository using `git-compose-commit`, and push the
registry after updating it.
