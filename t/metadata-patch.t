use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;
use XPerl::Installer::Build;
use XPerl::Installer::Registry;

my $root = tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $workdir = File::Spec->catdir($root, 'work');
my $registry_dir = File::Spec->catdir($root, 'registry');
my $dist_dir = File::Spec->catdir($registry_dir, 'distributions',
                                 'Example-Metadata');
make_path($workdir, File::Spec->catdir($dist_dir, 'patches'));

# The release declares a version that the registry patch loosens. Planning
# must use the same requirement that the later build will use.
my $meta = JSON::PP->new->canonical->encode({
    'meta-spec' => { version => 2 },
    name => 'Example-Metadata', version => '1.00',
    abstract => 'metadata patch fixture', author => ['Example'],
    license => ['perl_5'], generated_by => 'metadata-patch.t',
    release_status => 'stable', dynamic_config => JSON::PP::false,
    prereqs => { test => { requires => {
        'Example::Dependency' => '== 1.00',
    } } },
}) . "\n";
my $patched = $meta;
$patched =~ s/"== 1\.00"/">= 1.00"/ or die 'fixture version missing';

my $tar = Archive::Tar->new;
$tar->add_data('Example-Metadata-1.00/META.json', $meta);
$tar->add_data('Example-Metadata-1.00/Makefile.PL',
               "use ExtUtils::MakeMaker; WriteMakefile(NAME => 'Example::Metadata');\n");
my $archive = File::Spec->catfile($root, 'Example-Metadata-1.00.tar.gz');
$tar->write($archive, 1);
open my $source, '<:raw', $archive or die $!;
my $source_sha = Digest::SHA->new(256)->addfile($source)->hexdigest;
close $source;

my $patch_text = "--- a/META.json\n+++ b/META.json\n@@ -1 +1 @@\n"
               . "-$meta+$patched";
my $patch_path = File::Spec->catfile($dist_dir, 'patches', 'prereq.patch');
open my $patch, '>:raw', $patch_path or die $!;
print {$patch} $patch_text;
close $patch;
my $index = {
    schema => 1, distribution => 'Example-Metadata',
    releases => [{
        version => '1.00',
        cpan_path => 'E/EX/EXAMPLE/Example-Metadata-1.00.tar.gz',
        source_sha256 => $source_sha,
        patch_sets => [{
            id => 'prereq',
            xperl => { min_inclusive => "$^V", max_exclusive => 'v99.0.0' },
            patches => [{ path => 'patches/prereq.patch',
                          sha256 => sha256_hex($patch_text) }],
        }],
    }],
};
open my $index_file, '>', File::Spec->catfile($dist_dir, 'index.json')
    or die $!;
print {$index_file} JSON::PP->new->encode($index);
close $index_file;

my $release = {
    module => 'Example::Metadata', version => '1.00',
    cpan_path => 'E/EX/EXAMPLE/Example-Metadata-1.00.tar.gz',
    archive => $archive, sha256 => $source_sha,
};
my $plain = XPerl::Installer::Build->new(
    prefix => File::Spec->catdir($root, 'prefix'), workdir => $workdir);
my $original = $plain->planned_metadata({ %$release });
ok(!$original->effective_prereqs->merged_requirements(
       ['test'], ['requires'])->accepts_module('Example::Dependency', '1.01'),
   'the original metadata rejects a newer dependency');

my $registry = XPerl::Installer::Registry->new(path => $registry_dir);
my $builder = XPerl::Installer::Build->new(
    prefix => File::Spec->catdir($root, 'prefix'), workdir => $workdir,
    registry => $registry);
my $planned = $builder->planned_metadata({ %$release });
ok($planned->effective_prereqs->merged_requirements(
       ['test'], ['requires'])->accepts_module('Example::Dependency', '1.01'),
   'planning reads the patched metadata');

done_testing();
