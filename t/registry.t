use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;
use XPerl::Installer::Registry;
use builtin qw(siphash_2_4);
no warnings 'experimental::builtin';

my $root = abs_path(tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $dist = File::Spec->catdir($root, qw(distributions Example-Tiny));
my $patch_dir = File::Spec->catdir($dist, 'patches');
my $recipe_dir = File::Spec->catdir($root, 'recipes');
make_path($patch_dir, $recipe_dir);
my $recipe_path = File::Spec->catfile($recipe_dir, 'fix-v1.md');
open my $recipe, '>', $recipe_path or die $!;
print {$recipe} "# Fix recipe\n";
close $recipe or die $!;
my $patch_path = File::Spec->catfile($patch_dir, 'fix.patch');
my $patch_text = "--- a/test\n+++ b/test\n";
open my $patch, '>:raw', $patch_path or die $!;
print {$patch} $patch_text;
close $patch or die $!;
my $patch_sha = sha256_hex($patch_text);
my $source_sha = 'a' x 64;
my $index = {
    schema => 1,
    distribution => 'Example-Tiny',
    releases => [{
        version => '1.00',
        cpan_path => 'E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz',
        source_sha256 => $source_sha,
        patch_sets => [{
            id => 'fix',
            xperl => {
                min_inclusive => "$^V",
                max_exclusive => 'v99.0.0',
            },
            patches => [{
                path => 'patches/fix.patch',
                sha256 => $patch_sha,
            }],
            recipes => ['fix-v1'],
        }],
    }],
};
open my $index_file, '>', File::Spec->catfile($dist, 'index.json')
    or die $!;
print {$index_file} JSON::PP->new->canonical->encode($index);
close $index_file or die $!;

my $release = {
    distribution => 'Example-Tiny',
    distribution_version => '1.00',
    cpan_path => 'E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz',
    sha256 => $source_sha,
};
my $registry = XPerl::Installer::Registry->new(path => $root);
my $selection = $registry->patches_for($release);
is($selection->{patch_set}, 'fix', 'selects the matching patch set');
is($selection->{purpose}, 'compatibility', 'existing patch sets default to compatibility');
is($selection->{patches}[0]{sha256}, $patch_sha,
   'checks and reports the patch digest');
is($selection->{recipes}[0]{path}, abs_path($recipe_path),
   'provides a matching migration recipe');
$index->{releases}[0]{patch_sets}[0]{purpose} = 'security';
$index->{releases}[0]{patch_sets}[0]{advisories} = ['CVE-2024-45321'];
open $index_file, '>', File::Spec->catfile($dist, 'index.json') or die $!;
print {$index_file} JSON::PP->new->canonical->encode($index);
close $index_file or die $!;
$selection = $registry->patches_for($release);
is($selection->{purpose}, 'security', 'security patch set is selected without author policy');
is_deeply($selection->{advisories}, ['CVE-2024-45321'],
          'security advisory is returned with the patch');
eval { $registry->patches_for({ %$release, sha256 => 'b' x 64 }) };
like($@, qr/source digest mismatch/, 'rejects a different source archive');
open $patch, '>>', $patch_path or die $!;
print {$patch} "tampered\n";
close $patch or die $!;
eval { $registry->patches_for($release) };
like($@, qr/patch digest mismatch/, 'rejects a modified patch');

my $sharded = abs_path(tempdir(CLEANUP => 1,
                      DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $config = {
    schema => 2,
    active_repositories => 1,
    placement => 'siphash24-zero-jump-v1',
    fanout => 'siphash24-zero-first-byte-v1',
    repositories => [{ id => 0, path => '.' }],
};
open my $config_file, '>', File::Spec->catfile($sharded, 'registry.json')
    or die $!;
print {$config_file} JSON::PP->new->encode($config);
close $config_file or die $!;
my $prefix = unpack 'H2',
    siphash_2_4('EXAMPLE/Example-Tiny', "\0" x 16);
my $sharded_dist = File::Spec->catdir($sharded, 'data', $prefix,
                                     'EXAMPLE', 'Example-Tiny');
make_path(File::Spec->catdir($sharded_dist, 'patches'),
          File::Spec->catdir($sharded, 'recipes'));
open my $sharded_index, '>', File::Spec->catfile($sharded_dist, 'index.json')
    or die $!;
print {$sharded_index} JSON::PP->new->encode($index);
close $sharded_index or die $!;
open my $sharded_patch, '>:raw',
    File::Spec->catfile($sharded_dist, 'patches', 'fix.patch') or die $!;
print {$sharded_patch} $patch_text;
close $sharded_patch or die $!;
open my $sharded_recipe, '>',
    File::Spec->catfile($sharded, 'recipes', 'fix-v1.md') or die $!;
print {$sharded_recipe} "# Fix recipe\n";
close $sharded_recipe or die $!;
my $sharded_registry = XPerl::Installer::Registry->new(path => $sharded);
my $sharded_selection = $sharded_registry->patches_for($release);
is($sharded_selection->{patch_set}, 'fix',
   'finds a patch under the author and SipHash prefix');
is($sharded_registry->_distribution_directory({
    %$release,
    cpan_path => 'E/EX/EXAMPLE/older/Example-Tiny-1.00.tar.gz',
}), $sharded_dist, 'author subdirectories retain the same registry key');
is(scalar @{$sharded_registry->patches_for({
    %$release, cpan_path => 'B/BO/BOB/Example-Tiny-1.00.tar.gz'
})->{patches}}, 0, 'does not use another author\'s patches');

# A status record outside its placement is reported as invalid, quietly,
# even when nothing exists at the placement it should have.
my $misplaced = File::Spec->catdir($sharded, qw(data zz EXAMPLE Misplaced));
make_path($misplaced);
open my $misplaced_status, '>', File::Spec->catfile($misplaced, 'status.json')
    or die $!;
print {$misplaced_status} JSON::PP->new->encode({
    schema => 2, author => 'EXAMPLE', distribution => 'Misplaced',
    observations => [],
});
close $misplaced_status or die $!;
my @warnings;
my $records = do {
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    $sharded_registry->status_records;
};
is(scalar @{$records->{invalid}}, 1, 'misplaced status record is invalid');
like($records->{invalid}[0]{reason}, qr/not at its placement/,
     'invalid record names the placement problem');
is_deeply(\@warnings, [], 'checking placement emits no warnings');

done_testing();
