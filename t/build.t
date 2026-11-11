use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Archive::Tar::Constant qw(HARDLINK);
use Config;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Compress::Zip;
use JSON::PP;
use Test::More;
use XPerl::Installer::Build;
use XPerl::Installer::Deps;
use XPerl::Installer::Fetch;

my $root = tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $mirror = File::Spec->catdir($root, 'mirror');
my $cache = File::Spec->catdir($root, 'cache');
my $prefix = File::Spec->catdir($root, 'prefix');
my $modules = File::Spec->catdir($mirror, 'modules');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path($modules, $releases);

my $index = <<'INDEX';
File: 02packages.details.txt

Example::Tiny 1.00 E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz
Example::Broken 1.00 E/EX/EXAMPLE/Example-Broken-1.00.tar.gz
Example::NoMakefile 1.00 E/EX/EXAMPLE/Example-NoMakefile-1.00.tar.gz
Example::Zipped 1.00 E/EX/EXAMPLE/Example-Zipped-1.00.zip
INDEX
gzip \$index => File::Spec->catfile($modules, '02packages.details.txt.gz')
    or die $GzipError;

my $tar = Archive::Tar->new;
$tar->add_data('Example-Tiny-1.00/Makefile.PL', <<'MAKEFILE');
use ExtUtils::MakeMaker;
use JSON::PP;
my @custom = grep { /^XPERL_TEST_OPTION=/ } @ARGV;
@ARGV = grep { !/^XPERL_TEST_OPTION=/ } @ARGV;
open my $arguments, '>', 'configure-arguments.json' or die $!;
print {$arguments} JSON::PP->new->encode(\@custom);
close $arguments or die $!;
WriteMakefile(NAME => 'Example::Tiny', VERSION => '1.00');
MAKEFILE
$tar->add_data('Example-Tiny-1.00/lib/Example/Tiny.pm', <<'MODULE');
package Example::Tiny;
our $VERSION = '1.00';
sub answer { 42 }
1;
MODULE
$tar->add_data('Example-Tiny-1.00/t/basic.t', <<'TEST');
use Test::More tests => 1;
use Example::Tiny;
is(Example::Tiny::answer(), 42, 'module works');
TEST
$tar->write(File::Spec->catfile($releases, 'Example-Tiny-1.00.tar.gz'), 1);

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl-install');
open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, 'Example::Tiny' or die $!;
my $output = do { local $/; <$pipe> };
ok(close $pipe, 'installer completed');
my $result = eval { JSON::PP->new->decode($output) };
ok($result && $result->{status} eq 'installed', 'receipt reports installation');
my $receipt_path = $result->{receipts}[0];
open my $receipt_file, '<', $receipt_path or die $!;
my $receipt = JSON::PP->new->decode(do { local $/; <$receipt_file> });
is_deeply([map { $_->{name} } @{$receipt->{phases}}],
          [qw(configure build test install)], 'all build phases ran');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Tiny.pm)),
   'module installed into the selected prefix');
ok(-f $receipt_path, 'receipt written');
my $platform = $receipt->{platform} // {};
is($platform->{os}, $^O, 'receipt records the operating system');
is($platform->{archname}, $Config{archname},
   'receipt records the interpreter architecture');
is($platform->{key}, "$^O/$Config{archname}",
   'receipt records a stable platform key');
ok(exists $platform->{usethreads}, 'receipt records thread support');
ok(length($platform->{cc} // ''), 'receipt records the C compiler');

my $broken = Archive::Tar->new;
$broken->add_data('Example-Broken-1.00/Makefile.PL', <<'MAKEFILE');
use ExtUtils::MakeMaker;
WriteMakefile(NAME => 'Example::Broken', VERSION => '1.00');
MAKEFILE
$broken->add_data('Example-Broken-1.00/lib/Example/Broken.pm', <<'MODULE');
package Example::Broken;
our $VERSION = '1.00';
1;
MODULE
$broken->add_data('Example-Broken-1.00/t/basic.t', <<'TEST');
use Test::More tests => 1;
fail('test failure blocks installation');
TEST
$broken->write(File::Spec->catfile($releases, 'Example-Broken-1.00.tar.gz'), 1);
my $fetcher = XPerl::Installer::Fetch->new(mirror => $mirror, cache => $cache);
my $bad_release = $fetcher->fetch('Example::Broken');
my $bad_prefix = File::Spec->catdir($root, 'bad-prefix');
my $builder = XPerl::Installer::Build->new(prefix => $bad_prefix,
    workdir => File::Spec->catdir($root, 'bad-work'));
eval { $builder->install($bad_release) };
like($@, qr/test failed/, 'failed tests stop the installation');
ok(!-f File::Spec->catfile($bad_prefix, qw(lib perl5 Example Broken.pm)),
   'failed distribution is not installed');

my $no_makefile = Archive::Tar->new;
$no_makefile->add_data('Example-NoMakefile-1.00/Makefile.PL',
                       "exit 0;\n");
$no_makefile->add_data('Example-NoMakefile-1.00/lib/Example/NoMakefile.pm',
                       "package Example::NoMakefile;\n1;\n");
$no_makefile->write(File::Spec->catfile($releases,
                                       'Example-NoMakefile-1.00.tar.gz'), 1);
my $no_makefile_release = $fetcher->fetch('Example::NoMakefile');
eval { $builder->install($no_makefile_release) };
like($@, qr/configure did not produce Makefile/,
     'zero-exit configure without a Makefile is rejected');

# Some CPAN archives prefix every member with ./ before the source root.
# The prefix carries no path traversal, and metadata and extraction must
# agree on the resulting root.
my $dot_path = File::Spec->catfile($releases, 'Example-Dot-1.00.tar.gz');
my $dot_tar = Archive::Tar->new;
$dot_tar->add_data('./Example-Dot-1.00/META.json',
                   '{"name":"Example-Dot","version":"1.00"}');
$dot_tar->add_data('./Example-Dot-1.00/Makefile.PL', <<'MAKEFILE');
use ExtUtils::MakeMaker;
WriteMakefile(NAME => 'Example::Dot', VERSION => '1.00');
MAKEFILE
$dot_tar->add_data('./Example-Dot-1.00/lib/Example/Dot.pm',
                   "package Example::Dot;\nour \$VERSION = '1.00';\n1;\n");
$dot_tar->write($dot_path, 1);
is(XPerl::Installer::Fetch::_check_archive($dot_path), 3,
   'accepts an archive with a leading dot directory');
is(XPerl::Installer::Deps::_metadata($dot_path)->name, 'Example-Dot',
   'reads metadata below a leading dot directory');
my $dot_work = File::Spec->catdir($root, 'dot-work');
make_path($dot_work);
is(XPerl::Installer::Build::_unpack($dot_path, $dot_work),
   File::Spec->catdir($dot_work, 'Example-Dot-1.00'),
   'extracts a leading dot directory under the source root');

# An in-tree hard link can reuse an earlier regular member. A link outside
# the source root must fail before Archive::Tar touches the filesystem.
my $link_path = File::Spec->catfile($releases, 'Example-Link-1.00.tar.gz');
my $link_tar = Archive::Tar->new;
$link_tar->add_data('Example-Link-1.00/pod.t', "original\n");
$link_tar->add_data('Example-Link-1.00/t/pod.t', '',
    { type => HARDLINK, linkname => 'Example-Link-1.00/pod.t' });
$link_tar->write($link_path, 1);
is(XPerl::Installer::Fetch::_check_archive($link_path), 2,
   'accepts a hard link to an earlier in-tree file');
my $link_work = File::Spec->catdir($root, 'link-work');
make_path($link_work);
my $link_source = XPerl::Installer::Build::_unpack($link_path, $link_work);
open my $linked_file, '<', File::Spec->catfile($link_source, 't', 'pod.t')
    or die $!;
is(do { local $/; <$linked_file> }, "original\n",
   'extracts the hard link with the original content');

my $escape_path = File::Spec->catfile($releases, 'Example-Escape-1.00.tar.gz');
my $escape_tar = Archive::Tar->new;
$escape_tar->add_data('Example-Escape-1.00/t/pod.t', '',
    { type => HARDLINK, linkname => '../outside' });
$escape_tar->write($escape_path, 1);
eval { XPerl::Installer::Fetch::_check_archive($escape_path) };
like($@, qr/unsafe hard link/, 'rejects a hard link outside the source root');

# ZIP releases follow the same configure, build, test, and install path.
my $zip_path = File::Spec->catfile($releases, 'Example-Zipped-1.00.zip');
my $zip = IO::Compress::Zip->new($zip_path,
    Name => 'Example-Zipped-1.00/Makefile.PL')
    or die $IO::Compress::Zip::ZipError;
print {$zip} "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Example::Zipped', VERSION => '1.00');\n"
    or die $!;
$zip->newStream(Name => 'Example-Zipped-1.00/lib/Example/Zipped.pm')
    or die $IO::Compress::Zip::ZipError;
print {$zip} "package Example::Zipped;\nour \$VERSION = '1.00';\n1;\n"
    or die $!;
$zip->newStream(Name => 'Example-Zipped-1.00/META.json')
    or die $IO::Compress::Zip::ZipError;
print {$zip} '{"name":"Example-Zipped","version":"1.00"}' or die $!;
$zip->newStream(Name => 'Example-Zipped-1.00/bin/probe',
                ExtAttr => 0100755 << 16)
    or die $IO::Compress::Zip::ZipError;
print {$zip} "#!/usr/bin/env perl\nprint qq(probe\\n);\n" or die $!;
$zip->close or die $IO::Compress::Zip::ZipError;

my $zip_release = $fetcher->fetch('Example::Zipped');
is(XPerl::Installer::Deps::_metadata($zip_release->{archive})->name,
   'Example-Zipped', 'reads CPAN metadata from a ZIP release');
my $zip_receipt = $builder->install($zip_release);
is($zip_receipt->{status}, 'installed', 'ZIP release installs successfully');
ok(-f File::Spec->catfile($bad_prefix, qw(lib perl5 Example Zipped.pm)),
   'ZIP module installed into the selected prefix');
ok(-x File::Spec->catfile($zip_receipt->{workdir},
                         'Example-Zipped-1.00', 'bin', 'probe'),
   'ZIP extraction preserves an executable Unix mode');

# Configure arguments reach only the selected author/distribution and stay
# single argv elements. Resume must preserve them after the TOML disappears.
my $configured_prefix = File::Spec->catdir($root, 'configured prefix');
my $configured_work = File::Spec->catdir($root, 'configured-work');
my $configuration = File::Spec->catfile($root, 'configured.toml');
my $argument = 'XPERL_TEST_OPTION={prefix}/apache; literal $(text)';
open my $toml, '>', $configuration or die $!;
print {$toml} "schema = 1\n[install.configure_args]\n"
    . "\"EXAMPLE/Example-Tiny\" = ['$argument']\n"
    . "\"OTHER/Example-Tiny\" = ['XPERL_TEST_OPTION=wrong-author']\n";
close $toml or die $!;
my @install_command = ($^X, $script, 'install', '--config', $configuration,
    '--mirror', $mirror, '--cache', $cache, '--prefix', $configured_prefix,
    '--workdir', $configured_work, '--jobs', 1, 'Example::Tiny');

for my $resumed (0, 1) {
    if ($resumed) {
        unlink $configuration or die $!;
        unlink File::Spec->catfile($configured_prefix, qw(lib perl5 Example Tiny.pm))
            or die $!;
        @install_command = ($^X, $script, 'install', '--resume',
                            '--workdir', $configured_work);
    }
    open my $install, '-|', @install_command or die $!;
    my $output = do { local $/; <$install> };
    ok(close($install), $resumed ? 'configured installation resumes' : 'configured installation succeeds');
    my $result = JSON::PP->new->decode($output);
    open my $receipt_file, '<', $result->{receipts}[0] or die $!;
    my $record = JSON::PP->new->decode(do { local $/; <$receipt_file> });
    close $receipt_file;
    my $expected = "XPERL_TEST_OPTION=$configured_prefix/apache; literal \$(text)";
    is_deeply($record->{configure_args}, [$expected],
        'receipt records one expanded argument for the matching author');
    open my $arguments, '<', File::Spec->catfile($record->{workdir},
        'Example-Tiny-1.00', 'configure-arguments.json') or die $!;
    is_deeply(JSON::PP->new->decode(do { local $/; <$arguments> }), [$expected],
        'Makefile.PL receives spaces and shell characters literally');
    close $arguments;
}

done_testing();
