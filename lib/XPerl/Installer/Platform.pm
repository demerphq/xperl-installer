package XPerl::Installer::Platform;

use strict;
use warnings;
use feature 'signatures';
use Config;
use File::Spec;

# Identity of the host and interpreter that produced a result. The key
# separates observations whose builds can differ: the operating system and
# the interpreter's architecture name, which already distinguishes thread
# and 64-bit variants. The remaining fields are descriptive.
sub current () {
    my $compiler = $Config{gccversion} || $Config{ccversion} || '';
    return {
        key          => "$^O/$Config{archname}",
        os           => $^O,
        osvers       => $Config{osvers} // '',
        archname     => $Config{archname},
        cc           => $Config{cc} // '',
        cc_version   => $compiler,
        make         => $Config{make} || 'make',
        usethreads   => $Config{usethreads} ? 1 : 0,
        use64bitall  => $Config{use64bitall} ? 1 : 0,
        xperl_commit => $Config{git_commit_id} // '',
    };
}

# Prefixes of a package manager whose C libraries builds should find. The
# system compiler does not search Homebrew's prefix on Apple silicon, so
# distributions that link a library installed there fail to configure or
# compile without it. HOMEBREW_PREFIX names the installation anywhere; on
# macOS the standard locations are found by their brew program.
sub native_prefixes (%args) {
    my $env = $args{env} // \%ENV;
    my $os = $args{os} // $^O;
    my $candidates = $args{candidates} // ['/opt/homebrew', '/usr/local'];
    if (defined $env->{HOMEBREW_PREFIX} && length $env->{HOMEBREW_PREFIX}) {
        return -d $env->{HOMEBREW_PREFIX} ? ($env->{HOMEBREW_PREFIX}) : ();
    }
    return () unless $os eq 'darwin';
    for my $prefix (@$candidates) {
        return ($prefix) if -e File::Spec->catfile($prefix, "bin", "brew");
    }
    return ();
}

1;
