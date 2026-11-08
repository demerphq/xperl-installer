package XPerl::Installer::Platform;

use strict;
use warnings;
use feature 'signatures';
use Config;
use Digest::SHA qw(sha256_hex);
use File::Spec;
use JSON::PP;

# The platform key identifies the OS and architecture. The separate build
# digest distinguishes interpreter configurations within that platform.
sub current () {
    my $compiler = $Config{gccversion} || $Config{ccversion} || '';
    my $flags = $Config{ccflags} // '';
    my $stack = eval { Internals::stack_refcounted() & 1 };
    my $build = {
        schema => 1,
        xperl_commit => $Config{git_commit_id} // '',
        useithreads => $Config{useithreads} ? 1 : 0,
        usemultiplicity => $Config{usemultiplicity} ? 1 : 0,
        use64bitall => $Config{use64bitall} ? 1 : 0,
        use64bitint => $Config{use64bitint} ? 1 : 0,
        usemymalloc => defined($Config{usemymalloc})
            ? ($Config{usemymalloc} eq 'y' ? 1 : 0) : undef,
        uselongdouble => $Config{uselongdouble} ? 1 : 0,
        usequadmath => $Config{usequadmath} ? 1 : 0,
        debugging => $flags =~ /(?:^|\s)-DDEBUGGING(?:\s|$)/ ? 1 : 0,
        rc_stack => defined($stack) ? 0 + $stack : undef,
        ptrsize => $Config{ptrsize},
        ivsize => $Config{ivsize},
        nvsize => $Config{nvsize},
        nvtype => $Config{nvtype},
        byteorder => $Config{byteorder},
        compiler_version => $compiler,
    };
    # Flags can contain local paths. Hash them for identity without publishing
    # those paths in portable registry evidence.
    $build->{flags_sha256} = sha256_hex(JSON::PP->new->canonical->encode({
        map { $_ => $Config{$_} // '' } qw(cc ccflags optimize ld ldflags)
    }));
    my $build_id = sha256_hex(JSON::PP->new->canonical->encode($build));
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
        build_id     => $build_id,
        build        => $build,
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
