use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Digest::SHA qw(sha256_hex);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;
use XPerl::Installer::Fetch;

my $root = tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $mirror = File::Spec->catdir($root, 'mirror');
my $cache = File::Spec->catdir($root, 'cache');
my $index_dir = File::Spec->catdir($mirror, 'modules');
my $archive_dir = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path($index_dir, $archive_dir);

my $index = <<'INDEX';
File: 02packages.details.txt
URL: http://www.cpan.org/modules/02packages.details.txt

Example::Tiny 1.00 E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz
CPAN::02Packages::Search v1.0.0 S/SK/SKAJI/CPAN-02Packages-Search-v1.0.0.tar.gz
INDEX
gzip \$index => File::Spec->catfile($index_dir, '02packages.details.txt.gz')
    or die $GzipError;

my $archive = File::Spec->catfile($archive_dir, 'Example-Tiny-1.00.tar.gz');
my $tar = Archive::Tar->new;
$tar->add_data('Example-Tiny-1.00/META.json', '{"name":"Example-Tiny"}');
$tar->write($archive, 1);

my $fetcher = XPerl::Installer::Fetch->new(mirror => $mirror, cache => $cache);
is_deeply($fetcher->resolve('Example::Tiny'), {
    module => 'Example::Tiny',
    version => '1.00',
    cpan_path => 'E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz',
}, 'resolves a module through the package index');
is($fetcher->resolve('CPAN::02Packages::Search')->{cpan_path},
   'S/SK/SKAJI/CPAN-02Packages-Search-v1.0.0.tar.gz',
   'resolves a module with a numeric namespace segment');

my $result = $fetcher->fetch('Example::Tiny');
is($result->{archive_members}, 1, 'checks the fetched archive');
ok(-f $result->{archive}, 'caches the release archive');
open my $input, '<:raw', $archive or die $!;
my $sha = Digest::SHA->new(256)->addfile($input)->hexdigest;
is($result->{sha256}, $sha, 'records the source archive digest');

eval { $fetcher->resolve('../Example::Tiny') };
like($@, qr/invalid CPAN module name/, 'rejects an unsafe module name');

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl');
open my $pipe, '-|', $^X, $script, 'resolve', '--mirror', $mirror,
    '--cache', $cache, 'Example::Tiny' or die $!;
my $output = do { local $/; <$pipe> };
close $pipe or die 'resolver command failed';
is(JSON::PP->new->decode($output)->{cpan_path},
   'E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz',
   'dispatch/on routes the resolve command');

my $nested = File::Spec->catdir($archive_dir, 'older');
make_path($nested);
copy($archive, File::Spec->catfile($nested, 'Example-Tiny-1.00.tar.gz'))
    or die $!;
$index =~ s{E/EX/EXAMPLE/Example-Tiny-1\.00\.tar\.gz}{E/EX/EXAMPLE/older/Example-Tiny-1.00.tar.gz};
gzip \$index => File::Spec->catfile($index_dir, '02packages.details.txt.gz')
    or die $GzipError;
my $nested_result = $fetcher->fetch('Example::Tiny', refresh => 1);
is($nested_result->{cpan_path},
   'E/EX/EXAMPLE/older/Example-Tiny-1.00.tar.gz',
   'resolves a release inside an author subdirectory');
ok(-f $nested_result->{archive}, 'caches a nested release');

$index =~ s{E/EX/EXAMPLE/older/Example-Tiny-1\.00\.tar\.gz}{E/EX/EXAMPLE/../escape.tar.gz};
gzip \$index => File::Spec->catfile($index_dir, '02packages.details.txt.gz')
    or die $GzipError;
eval { $fetcher->resolve('Example::Tiny', refresh => 1) };
like($@, qr/unsafe or unsupported CPAN release path/,
     'rejects path traversal from CPAN metadata');

# The package index is parsed once per fetcher, not once per lookup, and is
# read again on refresh or when the cached file changes.
$index =~ s{E/EX/EXAMPLE/\.\./escape\.tar\.gz}{E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz};
gzip \$index => File::Spec->catfile($index_dir, '02packages.details.txt.gz')
    or die $GzipError;
my $once_cache = File::Spec->catdir($root, 'once-cache');
my $once = XPerl::Installer::Fetch->new(mirror => $mirror, cache => $once_cache);
is($once->resolve('Example::Tiny')->{version}, '1.00', 'first lookup reads the index');
my $cached_index = File::Spec->catfile($once_cache, '02packages.details.txt.gz');
my @stat = stat $cached_index;
open my $truncate, '>', $cached_index or die $!;
close $truncate or die $!;
utime $stat[8], $stat[9], $cached_index or die $!;
is(eval { $once->resolve('Example::Tiny')->{version} }, '1.00',
   'later lookups use the index already in memory');
(my $newer = $index) =~ s/Example::Tiny\s+1\.00/Example::Tiny 1.01/;
gzip \$newer => $cached_index or die $GzipError;
utime $stat[8], $stat[9] + 10, $cached_index or die $!;
is($once->resolve('Example::Tiny')->{version}, '1.01',
   'a changed index file is read again');
is($once->resolve('Example::Tiny', refresh => 1)->{version}, '1.00',
   'refresh downloads and reads the index again');

done_testing();
