use strict;
use warnings;
use ExtUtils::MakeMaker;

die "XPerl::Installer requires an installed XPerl interpreter\n"
    unless ${^XPERL_VERSION};

WriteMakefile(
    NAME             => 'XPerl::Installer',
    VERSION_FROM     => 'lib/XPerl/Installer.pm',
    ABSTRACT         => 'CPAN installer for XPerl',
    AUTHOR           => 'XPerl contributors',
    LICENSE          => 'perl',
    MIN_PERL_VERSION => '5.45.5',
    EXE_FILES        => ['bin/xperl'],
    PREREQ_PM        => {
        'Archive::Tar'             => 0,
        'CPAN::Meta'               => 0,
        'CPAN::Meta::Requirements' => 0,
        'Digest::SHA'              => 0,
        'HTTP::Tiny'               => 0,
        'JSON::PP'                 => 0,
        'Module::Metadata'         => 0,
        'Parse::CPAN::Meta'        => 0,
    },
    TEST_REQUIRES => {
        'IO::Compress::Gzip' => 0,
        'Test::More'         => 0,
    },
);
