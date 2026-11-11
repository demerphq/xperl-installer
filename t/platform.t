use strict;
use warnings;
use FindBin;
use Config;
use lib "$FindBin::Bin/../lib";
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use XPerl::Installer::Platform;

my $root = tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $brew = File::Spec->catdir($root, 'homebrew');
my $other = File::Spec->catdir($root, 'other');
make_path(File::Spec->catdir($brew, 'bin'), File::Spec->catdir($other, 'bin'));
open my $output, '>', File::Spec->catfile($brew, 'bin', 'brew') or die $!;
close $output or die $!;

sub detect { [XPerl::Installer::Platform::native_prefixes(@_)] }

my $platform = XPerl::Installer::Platform::current();
like($platform->{build_id}, qr/\A[0-9a-f]{64}\z/,
     'build configuration has a stable digest');
is($platform->{build}{rc_stack}, Internals::stack_refcounted() & 1,
   'build configuration records the reference-counted stack');
is($platform->{build}{usemymalloc},
   defined($Config{usemymalloc}) ? ($Config{usemymalloc} eq 'y' ? 1 : 0) : undef,
   'build configuration interprets the allocator setting as y or n');
is(XPerl::Installer::Platform::current()->{build_id}, $platform->{build_id},
   'the same interpreter reports the same build identity');

# The embedding library affects whether Apache can link, even when the
# interpreter version, architecture and ordinary flags are identical.
{
    no warnings 'once';
    local *XPerl::Installer::Platform::Config = {%Config::Config};
    $XPerl::Installer::Platform::Config{useshrplib} = 'false';
    my $static = XPerl::Installer::Platform::current();
    $XPerl::Installer::Platform::Config{useshrplib} = 'true';
    my $shared = XPerl::Installer::Platform::current();
    is($static->{build}{useshrplib}, 0, 'a false setting records static libperl');
    is($shared->{build}{useshrplib}, 1, 'a true setting records shared libperl');
    isnt($static->{build_id}, $shared->{build_id},
         'static and shared embedding libraries have distinct build identities');
}

is_deeply(detect(env => { HOMEBREW_PREFIX => $other }, os => 'linux',
                 candidates => [$brew]),
          [$other], 'HOMEBREW_PREFIX names the native prefix');
is_deeply(detect(env => {}, os => 'darwin', candidates => [$other, $brew]),
          [$brew], 'macOS finds the Homebrew installation by its brew program');
is_deeply(detect(env => {}, os => 'linux', candidates => [$brew]),
          [], 'other systems need HOMEBREW_PREFIX');
is_deeply(detect(env => { HOMEBREW_PREFIX => File::Spec->catdir($root, 'gone') },
                 os => 'darwin', candidates => []),
          [], 'a missing HOMEBREW_PREFIX directory is ignored');

done_testing();
