use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;
use XPerl::Installer::Deps;

my $root = tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $mirror = File::Spec->catdir($root, 'mirror');
my $cache = File::Spec->catdir($root, 'cache');
my $workdir = File::Spec->catdir($root, 'build-work');
my $prefix = File::Spec->catdir($root, 'prefix');
my $modules = File::Spec->catdir($mirror, 'modules');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path($modules, $releases);

my $index = <<'INDEX';
File: 02packages.details.txt

Example::Dependency 1.00 E/EX/EXAMPLE/Example-Dependency-1.00.tar.gz
Example::Application 1.00 E/EX/EXAMPLE/Example-Application-1.00.tar.gz
Example::Legacy 1.00 E/EX/EXAMPLE/Example-Legacy-1.00.tar.gz
Example::Internal undef E/EX/EXAMPLE/Example-Multi-1.00.tar.gz
INDEX
gzip \$index => File::Spec->catfile($modules, '02packages.details.txt.gz')
    or die $GzipError;

for my $name (qw(Dependency Application Legacy)) {
    my $root_name = "Example-$name-1.00";
    my $tar = Archive::Tar->new;
    my $unsafe_inc_check = $name eq 'Application'
        ? 'die "unsafe-inc metadata ignored" if $ENV{PERL_USE_UNSAFE_INC};' . "\n"
        : '';
    my $dynamic_prereq = $name eq 'Application'
        ? ", PREREQ_PM => {'Example::Dependency' => '1.00'}"
        : '';
    $tar->add_data("$root_name/Makefile.PL",
        "use ExtUtils::MakeMaker;\n" . $unsafe_inc_check
        . "WriteMakefile(NAME => 'Example::$name', VERSION => '1.00'"
        . "$dynamic_prereq);\n");
    my $body = $name ne 'Application'
        ? "package Example::$name;\nour \$VERSION = '1.00';\nsub value { 42 }\n1;\n"
        : "package Example::Application;\nour \$VERSION = '1.00';\nuse Example::Dependency;\nsub value { Example::Dependency::value() }\n1;\n";
    $tar->add_data("$root_name/lib/Example/$name.pm", $body);
    $tar->add_data("$root_name/t/basic.t",
        "use Test::More tests => 1; use Example::$name; is(Example::${name}::value(), 42);\n");
    my $meta = {
        'meta-spec' => { version => 2 },
        name => "Example-$name", version => '1.00',
        abstract => 'Local installer test', author => ['XPerl'],
        generated_by => 'XPerl installer test', release_status => 'stable',
        license => ['perl_5'], dynamic_config => JSON::PP::false,
        prereqs => {},
    };
    $meta->{x_use_unsafe_inc} = JSON::PP::false if $name eq 'Application';
    $tar->add_data("$root_name/META.json", JSON::PP->new->encode($meta))
        unless $name eq 'Legacy';
    $tar->write(File::Spec->catfile($releases, "$root_name.tar.gz"), 1);
}

my $multi_tar = Archive::Tar->new;
$multi_tar->add_data('Example-Multi-1.00/Makefile.PL',
    "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Example::Multi', VERSION => '1.00');\n");
$multi_tar->add_data('Example-Multi-1.00/lib/Example/Multi.pm',
    "package Example::Multi;\nour \$VERSION = '1.00';\n"
    . "package Example::Internal;\nsub value { 42 }\n1;\n");
$multi_tar->add_data('Example-Multi-1.00/t/basic.t',
    "use Test::More tests => 1; use Example::Multi; is(Example::Internal::value(), 42);\n");
$multi_tar->add_data('Example-Multi-1.00/META.json', JSON::PP->new->encode({
    'meta-spec' => { version => 2 },
    name => 'Example-Multi', version => '1.00',
    abstract => 'Local installer test', author => ['XPerl'],
    generated_by => 'XPerl installer test', release_status => 'stable',
    license => ['perl_5'], dynamic_config => JSON::PP::false,
    prereqs => {},
    provides => {
        'Example::Multi' => { file => 'lib/Example/Multi.pm', version => '1.00' },
        'Example::Internal' => { file => 'lib/Example/Multi.pm' },
    },
}));
$multi_tar->write(File::Spec->catfile($releases,
    'Example-Multi-1.00.tar.gz'), 1);

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl-install');
local %ENV = %ENV;
delete $ENV{PERL_USE_UNSAFE_INC};
open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--workdir', $workdir, '--prefix', $prefix,
    'Example::Application' or die $!;
my $output = do { local $/; <$pipe> };
ok(close $pipe, 'application installation completed');
my $result = eval { JSON::PP->new->decode($output) };
ok($result && $result->{status} eq 'installed', 'dependency run succeeded');
like($result->{receipts}[0], qr{\Q$workdir\E/},
     'build work is kept separate from the download cache');
my %receipts;
for my $path (@{$result->{receipts}}) {
    open my $input, '<', $path or die $!;
    my $receipt = JSON::PP->new->decode(do { local $/; <$input> });
    $receipts{$receipt->{module}} = $receipt;
}
my ($dependency_install) = grep { $_->{name} eq 'install' }
    @{$receipts{'Example::Dependency'}{phases}};
my ($application_configure) = reverse grep { $_->{name} eq 'configure' }
    @{$receipts{'Example::Application'}{phases}};
ok($dependency_install->{finished} <= $application_configure->{started},
   'configured dependency installed before its parent build');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Application.pm)),
   'application installed into selected prefix');

my $registry = File::Spec->catdir($root, 'registry');
make_path($registry);
open my $legacy_pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--workdir', $workdir, '--prefix', $prefix,
    '--registry', $registry, 'Example::Legacy' or die $!;
my $legacy_output = do { local $/; <$legacy_pipe> };
ok(close $legacy_pipe, 'metadata-free release installation completed');
my $legacy = eval { JSON::PP->new->decode($legacy_output) };
ok($legacy && $legacy->{status} eq 'installed',
   'metadata-free release installs with registry lookup');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Legacy.pm)),
   'metadata-free release installed into selected prefix');

open my $internal_pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--workdir', $workdir, '--prefix', $prefix,
    'Example::Internal' or die $!;
my $internal_output = do { local $/; <$internal_pipe> };
ok(close $internal_pipe, 'internal package installation completed');
my $internal = eval { JSON::PP->new->decode($internal_output) };
ok($internal && $internal->{status} eq 'installed',
   'metadata provides a package without its own file');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Multi.pm)),
   'distribution file containing internal package was installed');
ok(!-f File::Spec->catfile($prefix, qw(lib perl5 Example Internal.pm)),
   'internal package has no separate file');

my $old_archive = File::Spec->catfile($root, 'old-meta.tar.gz');
my $old_tar = Archive::Tar->new;
$old_tar->add_data('Old-Meta-0.03/META.yml', <<'META');
--- #YAML:1.0
name: Old-Meta
version: 0.03
abstract: ~
author: []
license: unknown
requires:
    Test::More: 0
meta-spec:
    version: 1.4
META
$old_tar->write($old_archive, 1);
my $old_meta = XPerl::Installer::Deps::_metadata($old_archive);
is($old_meta->name, 'Old-Meta', 'old metadata with no abstract is accepted');
is($old_meta->effective_prereqs->merged_requirements(
       [qw(configure build test runtime)], ['requires'])
       ->requirements_for_module('Test::More'),
   '0', 'old metadata still provides its requirements');

# Old ExtUtils::MakeMaker releases wrote JSON into META.yml and used the main
# module's name as the distribution name.
my $legacy_mirror = File::Spec->catdir($root, 'legacy-mirror');
my $legacy_releases = File::Spec->catdir($legacy_mirror, qw(authors id E EX EXAMPLE));
make_path(File::Spec->catdir($legacy_mirror, 'modules'), $legacy_releases);
sub legacy_release {
    my ($dist, $module, $meta_yml) = @_;
    my $tar = Archive::Tar->new;
    (my $file = $module) =~ s{::}{/}g;
    $tar->add_data("$dist-1.00/Makefile.PL",
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => '$module', VERSION => '1.00');\n");
    $tar->add_data("$dist-1.00/lib/$file.pm",
        "package $module;\nour \$VERSION = '1.00';\n1;\n");
    $tar->add_data("$dist-1.00/t/basic.t",
        "use Test::More tests => 1; use_ok('$module');\n");
    $tar->add_data("$dist-1.00/META.yml", $meta_yml);
    my $path = File::Spec->catfile($legacy_releases, "$dist-1.00.tar.gz");
    $tar->write($path, 1);
    return $path;
}
legacy_release('Example-ColonName', 'Example::ColonName', <<'META');
# http://module-build.sourceforge.net/META-spec.html
name:         Example::ColonName
version:      1.00
distribution_type: module
META
my $json_yml = legacy_release('Example-JsonYaml', 'Example::JsonYaml',
    JSON::PP->new->pretty->encode({
        name => 'Example-JsonYaml', version => '1.00',
        abstract => 'JSON in META.yml', author => ['XPerl'], license => 'perl',
        'meta-spec' => { version => '1.4' },
        requires => { 'Example::ColonName' => 0 },
    }));
my $legacy_index = "File: 02packages.details.txt\n\n"
    . "Example::ColonName 1.00 E/EX/EXAMPLE/Example-ColonName-1.00.tar.gz\n"
    . "Example::JsonYaml 1.00 E/EX/EXAMPLE/Example-JsonYaml-1.00.tar.gz\n";
gzip \$legacy_index => File::Spec->catfile($legacy_mirror, 'modules',
                                           '02packages.details.txt.gz')
    or die $GzipError;

my $json_meta = eval { XPerl::Installer::Deps::_metadata($json_yml) };
is($json_meta && $json_meta->name, 'Example-JsonYaml',
   'JSON content in META.yml is read as metadata');

for my $jobs (1, 2) {
    my $legacy_prefix = File::Spec->catdir($root, "legacy-prefix-$jobs");
    open my $pipe, '-|', $^X, $script, 'install', '--mirror', $legacy_mirror,
        '--cache', File::Spec->catdir($root, "legacy-cache-$jobs"),
        '--workdir', File::Spec->catdir($root, "legacy-work-$jobs"),
        '--prefix', $legacy_prefix, '--registry', $registry, '--jobs', $jobs,
        'Example::JsonYaml' or die $!;
    my $output = do { local $/; <$pipe> };
    my $closed = close $pipe;
    my $result = eval { JSON::PP->new->decode($output) } // {};
    ok($closed && ($result->{status} // '') eq 'installed',
       "legacy metadata releases install ($jobs jobs)");
    ok(-f File::Spec->catfile($legacy_prefix, qw(lib perl5 Example ColonName.pm)),
       "the prerequisite named only in JSON META.yml is installed ($jobs jobs)");
}

done_testing();
