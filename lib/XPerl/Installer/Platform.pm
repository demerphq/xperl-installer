package XPerl::Installer::Platform;

use strict;
use warnings;
use feature 'signatures';
use Config;

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

1;
