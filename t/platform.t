use strict;
use warnings;
use FindBin;
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
