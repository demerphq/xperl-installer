use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;

my $root = abs_path(tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $mirror = File::Spec->catdir($root, 'mirror');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
my $native = File::Spec->catdir($root, 'native');
make_path(File::Spec->catdir($mirror, 'modules'), $releases,
          File::Spec->catdir($native, 'include'),
          File::Spec->catdir($native, 'lib'));

my $index = "File: 02packages.details.txt\n\n"
    . "Example::Native 1.00 E/EX/EXAMPLE/Example-Native-1.00.tar.gz\n";
gzip \$index => File::Spec->catfile($mirror, 'modules',
                                    '02packages.details.txt.gz')
    or die $GzipError;

# Configuration fails unless the compiler would search the native prefix,
# as it does for a distribution whose library is installed there. The
# directory to look for comes from the environment.
my $tar = Archive::Tar->new;
$tar->add_data('Example-Native-1.00/Makefile.PL', <<'MAKEFILE');
use Config;
use ExtUtils::MakeMaker;
my $want = $ENV{EXAMPLE_NATIVE_INCLUDE};
die "native include directory not searched\n"
    unless grep { $_ eq $want }
        split /\Q$Config{path_sep}\E/, $ENV{CPATH} // '';
WriteMakefile(NAME => 'Example::Native', VERSION => '1.00');
MAKEFILE
$tar->add_data('Example-Native-1.00/lib/Example/Native.pm',
    "package Example::Native;\nour \$VERSION = '1.00';\n1;\n");
$tar->add_data('Example-Native-1.00/t/basic.t',
    "use Test::More tests => 1; use_ok('Example::Native');\n");
$tar->write(File::Spec->catfile($releases, 'Example-Native-1.00.tar.gz'), 1);

my $include = File::Spec->catdir($native, 'include');

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl');
my $run = 0;
sub install (%args) {
    $run++;
    local %ENV = %ENV;
    delete @ENV{qw(CPATH LIBRARY_PATH PKG_CONFIG_PATH HOMEBREW_PREFIX)};
    $ENV{EXAMPLE_NATIVE_INCLUDE} = $include;
    @ENV{keys %{$args{env} // {}}} = values %{$args{env} // {}};
    open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
        '--cache', File::Spec->catdir($root, 'cache'),
        '--workdir', File::Spec->catdir($root, "work-$run"),
        '--prefix', File::Spec->catdir($root, "prefix-$run"),
        @{$args{options} // []}, 'Example::Native' or die $!;
    my $output = do { local $/; <$pipe> };
    close $pipe;
    my $result = eval { JSON::PP->new->decode($output) } // {};
    my $receipt = {};
    if (my $path = ($result->{receipts} // [])->[0]) {
        open my $input, '<', $path or die $!;
        $receipt = JSON::PP->new->decode(do { local $/; <$input> });
    }
    return ($result->{status} // 'failed', $receipt);
}

my ($status, $receipt) = install(options => ['--native-prefix', $native]);
is($status, 'installed', '--native-prefix makes its headers visible');
is_deeply($receipt->{native_prefixes}, [$native],
          'receipt records the native prefixes used');

($status) = install(env => { HOMEBREW_PREFIX => $native });
is($status, 'installed', 'HOMEBREW_PREFIX is used by default');

($status) = install(env => { HOMEBREW_PREFIX => $native },
                    options => ['--no-native-prefix']);
isnt($status, 'installed', '--no-native-prefix turns detection off');

my $config = File::Spec->catfile($root, 'config.toml');
open my $output, '>', $config or die $!;
print {$output} "schema = 1\n[install]\nnative_prefixes = ['$native']\n";
close $output or die $!;
($status, $receipt) = install(options => ['--config', $config]);
is($status, 'installed', 'config native_prefixes are used');
is_deeply($receipt->{native_prefixes}, [$native],
          'config prefixes replace detection');

done_testing();
