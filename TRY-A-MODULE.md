# Try a CPAN module with XPerl

Pick a module you actually use. A passing install is useful evidence, and a
failure gives us a concrete compatibility problem to investigate.

First complete the [XPerl and installer setup](planning/bootstrap.md) through
"Install the installer." You should have an installed Perlbrew XPerl, an
`xperl-install` command, and an `xperl-cpan-ports` checkout next to the
installer. The commands below run from the parent `perldev/` directory.

```sh
module='Your::Favourite::Module'
xperl_prefix="${PERLBREW_ROOT:-$HOME/perl5/perlbrew}/perls/xperl"
install_prefix="$PWD/tmp/try-prefix"
workdir="$PWD/tmp/try-work"
mkdir -p "$install_prefix"
export PERL5LIB="$install_prefix/lib/perl5"
"$xperl_prefix/bin/perl" "$xperl_prefix/bin/xperl-install" install \
    --prefix "$install_prefix" --workdir "$workdir" \
    --registry "$PWD/xperl-cpan-ports" "$module"
```

Replace `Your::Favourite::Module` with the module name you want to try. The
installer downloads the current CPAN release, installs its required CPAN
dependencies, applies any matching reviewed patches, and builds and tests
before installing. It does not start an AI agent unless you select one.

The final JSON result names the requested module and gives the receipt and
reason for any failure. Build and test logs live under `workdir`. If the
installer asks for a system package, install it and resume the same run:

```sh
"$xperl_prefix/bin/perl" "$xperl_prefix/bin/xperl-install" install \
    --resume --workdir "$workdir"
```

To check whether the module loads from the isolated prefix, run:

```sh
"$xperl_prefix/bin/perl" -M"$module" -e '(my $file = $ARGV[0]) =~ s{::}{/}g; $file .= ".pm"; print "$ARGV[0] loaded from $INC{$file} on $^V\n"' "$module"
```

Tell us the module name, your operating system, the XPerl version printed
by `"$xperl_prefix/bin/perl" -V`, and whether the install and load check
passed. If it failed, include the reason from the final result and the path
to the receipt and relevant phase log. A source search match or a failure on
another platform does not prove your module is broken on this one.

Use a new `install_prefix` and `workdir` for another clean trial. The download
cache stays shared at `$HOME/.xperl/cache`, so source archives can be reused.
The [ports build summary](https://github.com/demerphq/xperl-cpan-ports/blob/main/status/SUMMARY.md)
shows results that have already been reviewed and committed.
