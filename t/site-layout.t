use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Config;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;
use XPerl::Installer::Build;
use XPerl::Installer::Deps;
use XPerl::Installer::Fetch;
use XPerl::Installer::Parallel;

my $root = abs_path(tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $mirror = File::Spec->catdir($root, 'mirror');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path(File::Spec->catdir($mirror, 'modules'), $releases);

my $index = "File: 02packages.details.txt\n\n"
    . "Example::Base 1.00 E/EX/EXAMPLE/Example-Base-1.00.tar.gz\n"
    . "Example::Top 1.00 E/EX/EXAMPLE/Example-Top-1.00.tar.gz\n"
    . "Example::Built 1.00 E/EX/EXAMPLE/Example-Built-1.00.tar.gz\n";
gzip \$index => File::Spec->catfile($mirror, 'modules',
                                    '02packages.details.txt.gz')
    or die $GzipError;

sub release ($dist, $module, $configure, %requires) {
    my $tar = Archive::Tar->new;
    (my $file = $module) =~ s{::}{/}g;
    my $prereqs = join ', ', map { "'$_' => '$requires{$_}'" } sort keys %requires;
    if ($configure eq 'Makefile.PL') {
        $tar->add_data("$dist-1.00/Makefile.PL",
            "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => '$module', "
            . "VERSION => '1.00', PREREQ_PM => { $prereqs });\n");
    }
    else {
        $tar->add_data("$dist-1.00/Build.PL",
            "use Module::Build;\nModule::Build->new(module_name => '$module', "
            . "dist_version => '1.00', license => 'perl', "
            . "requires => { $prereqs })->create_build_script;\n");
    }
    my $body = "package $module;\nour \$VERSION = '1.00';\n";
    $body .= "use $_;\n" for sort keys %requires;
    $tar->add_data("$dist-1.00/lib/$file.pm", "$body\nsub value { 42 }\n1;\n");
    $tar->add_data("$dist-1.00/t/basic.t",
        "use Test::More tests => 1; use $module; is($module\::value(), 42);\n");
    $tar->add_data("$dist-1.00/META.json", JSON::PP->new->encode({
        'meta-spec' => { version => 2 }, name => $dist, version => '1.00',
        abstract => 'site layout test', author => ['XPerl'],
        generated_by => 'XPerl installer test', release_status => 'stable',
        license => ['perl_5'], dynamic_config => JSON::PP::false,
        prereqs => { runtime => { requires => \%requires } },
    }));
    $tar->write(File::Spec->catfile($releases, "$dist-1.00.tar.gz"), 1);
}
release('Example-Base', 'Example::Base', 'Makefile.PL');
release('Example-Top', 'Example::Top', 'Makefile.PL', 'Example::Base' => '1.00');
release('Example-Built', 'Example::Built', 'Build.PL');

my $run = 0;
sub fixture (%args) {
    $run++;
    my $prefix = $args{prefix} // File::Spec->catdir($root, "prefix-$run");
    my $site = File::Spec->catdir($root, "site-$run");
    my %dirs = (
        lib => File::Spec->catdir($site, 'lib'),
        arch => File::Spec->catdir($site, 'arch'),
        bin => File::Spec->catdir($site, 'bin'),
        script => File::Spec->catdir($site, 'bin'),
        man1dir => File::Spec->catdir($site, 'man1'),
        man3dir => File::Spec->catdir($site, 'man3'),
    );
    my $builder = XPerl::Installer::Build->new(
        prefix => $prefix,
        workdir => File::Spec->catdir($root, "work-$run"),
        interpreter_prefix => $args{interpreter_prefix} // $prefix,
        site_dirs => \%dirs,
        (defined $args{layout} ? (layout => $args{layout}) : ()),
    );
    my $fetcher = XPerl::Installer::Fetch->new(mirror => $mirror,
        cache => File::Spec->catdir($root, "cache-$run"));
    return ($builder, $fetcher, \%dirs, abs_path($prefix));
}

sub receipt ($path) {
    open my $input, '<', $path or die "$path: $!";
    return JSON::PP->new->decode(do { local $/; <$input> });
}

# Layout selection.
{
    my $interpreter = File::Spec->catdir($root, 'interpreter');
    my ($builder) = fixture(prefix => $interpreter,
                            interpreter_prefix => $interpreter);
    is($builder->{layout}, 'site',
       "the interpreter's own prefix uses the site layout");
    ($builder) = fixture(interpreter_prefix => $interpreter);
    is($builder->{layout}, 'install_base',
       'any other prefix keeps the INSTALL_BASE layout');
    ($builder) = fixture(prefix => $interpreter,
                         interpreter_prefix => $interpreter,
                         layout => 'install_base');
    is($builder->{layout}, 'install_base',
       'install_base can be chosen for the interpreter prefix');
    ($builder) = fixture(interpreter_prefix => $interpreter, layout => 'site');
    is($builder->{layout}, 'site', 'site can be chosen for any prefix');
    ok(!eval { fixture(layout => 'flat'); 1 }, 'an unknown layout is rejected');
    like($@, qr/layout must be auto, site or install_base/,
         'the unknown layout error names the choices');
    my $default = XPerl::Installer::Build->new(
        prefix => File::Spec->catdir($root, 'default-prefix'),
        workdir => File::Spec->catdir($root, 'default-work'));
    is($default->{layout}, 'install_base',
       'a prefix outside the interpreter defaults to INSTALL_BASE');
}

# A site install of a release and its prerequisite goes where the site
# library is, not under the prefix, and the prerequisite is recognised.
for my $jobs (1, 2) {
    my ($builder, $fetcher, $dirs, $prefix) = fixture(layout => 'site');
    local $ENV{PERL_MM_OPT} = "INSTALL_BASE=$root/elsewhere";
    local $ENV{PERL_MB_OPT} = "--install_base $root/elsewhere";
    my @receipts;
    if ($jobs == 1) {
        my $deps = XPerl::Installer::Deps->new(fetcher => $fetcher,
                                               builder => $builder);
        @receipts = @{$deps->install('Example::Top')->{receipts}};
    }
    else {
        my $parallel = XPerl::Installer::Parallel->new(fetcher => $fetcher,
            builder => $builder, jobs => $jobs);
        my $result = $parallel->run({ module => 'Example::Top' });
        @receipts = map { $_->{receipt} // () } @{$result->{nodes}};
    }
    ok(-f File::Spec->catfile($dirs->{lib}, qw(Example Top.pm)),
       "site layout installs the release into the site library ($jobs jobs)");
    ok(-f File::Spec->catfile($dirs->{lib}, qw(Example Base.pm)),
       "site layout installs the prerequisite into the site library ($jobs jobs)");
    ok(!-e File::Spec->catdir($prefix, qw(lib perl5)),
       "site layout writes nothing under prefix/lib/perl5 ($jobs jobs)");
    ok(!-e File::Spec->catdir($root, 'elsewhere'),
       "caller PERL_MM_OPT cannot redirect a site install ($jobs jobs)");
    is(scalar(@receipts), 2, "each release is built once ($jobs jobs)");
    is_deeply([sort map { receipt($_)->{layout} } @receipts],
              [qw(site site)], "receipts record the site layout ($jobs jobs)");
}

SKIP: {
    skip 'Module::Build is not installed', 2
        unless eval { require Module::Build; 1 };
    my ($builder, $fetcher, $dirs, $prefix) = fixture(layout => 'site');
    my $deps = XPerl::Installer::Deps->new(fetcher => $fetcher,
                                           builder => $builder);
    $deps->install('Example::Built');
    ok(-f File::Spec->catfile($dirs->{lib}, qw(Example Built.pm)),
       'a Build.PL release installs into the site library');
    ok(!-e File::Spec->catdir($prefix, qw(lib perl5)),
       'a Build.PL site install writes nothing under prefix/lib/perl5');
}

# A copy left in the old layout would hide the new one when PERL5LIB
# includes it, so the receipt says so.
{
    my ($builder, $fetcher, $dirs, $prefix) = fixture(layout => 'site');
    my $old = File::Spec->catfile($prefix, qw(lib perl5 Example Base.pm));
    make_path(File::Spec->catdir($prefix, qw(lib perl5 Example)));
    open my $output, '>', $old or die $!;
    print {$output} "package Example::Base;\nour \$VERSION = '0.50';\n1;\n";
    close $output or die $!;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $record = $builder->install($fetcher->fetch('Example::Base'));
    is_deeply($record->{shadowed_by}, [$old],
              'receipt names an older copy under prefix/lib/perl5');
    like(join('', @warnings), qr/\Q$old\E hides the Example::Base just installed/,
         'the installer warns about the hiding copy');
}

# The INSTALL_BASE layout is unchanged.
{
    my ($builder, $fetcher, $dirs, $prefix) = fixture(layout => 'install_base');
    my $deps = XPerl::Installer::Deps->new(fetcher => $fetcher,
                                           builder => $builder);
    my $result = $deps->install('Example::Top');
    ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Top.pm)),
       'install_base layout installs under prefix/lib/perl5');
    ok(!-e $dirs->{lib}, 'install_base layout leaves the site library alone');
    is(receipt($result->{receipts}[0])->{layout}, 'install_base',
       'receipts record the install_base layout');
}

{
    my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl-install');
    open my $pipe, '-|', "$^X $script install --layout flat --prefix "
        . File::Spec->catdir($root, 'cli-prefix') . " Example::Base 2>&1"
        or die $!;
    my $output = do { local $/; <$pipe> };
    ok(!close $pipe, 'the CLI rejects an unknown layout');
    like($output, qr/layout must be auto, site or install_base/,
         'the CLI names the layout choices');
}

done_testing();
