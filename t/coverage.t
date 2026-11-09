use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Digest::SHA;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use XPerl::Installer::Coverage;
use XPerl::Installer::Fetch;

my $root = tempdir(CLEANUP => 1,
    DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $platform = { key => 'linux/test', build_id => 'current',
                 build => { rc_stack => 1, xperl_commit => 'current-core' } };
my @records;

{
    package FixtureRegistry;
    sub status_records { return { records => \@records, invalid => [] } }
    sub patches_for { return { patches => [] } }
}

sub release ($name, $members, $version = '1.00') {
    my $tar = Archive::Tar->new;
    $tar->add_data("$name-$version/$_", $members->{$_}) for sort keys %$members;
    my $directory = File::Spec->catdir($root, qw(authors id E EX EXAMPLE));
    make_path($directory);
    my $archive = File::Spec->catfile($directory, "$name-$version.tar.gz");
    $tar->write($archive, 1);
    my $hash = XPerl::Installer::Fetch::_digest($archive);
    my $observation = {
        id => $name, status => 'installed', module => "Example::$name",
        version => $version, xperl_version => "$^V",
        cpan_path => "E/EX/EXAMPLE/$name-$version.tar.gz", source_sha256 => $hash,
        patch_sha256 => [], platform => $platform,
        phases => [{ name => 'test', exit_status => 0 }],
    };
    my $record = { key => "EXAMPLE/$name", author => 'EXAMPLE',
                   distribution => $name, observations => [$observation] };
    push @records, $record;
    return $record;
}

# Source signatures distinguish real extension inputs from shipped examples
# and compatibility headers in an otherwise pure-Perl distribution.
release('Current', { 'lib/Current.xs' => 'MODULE = Example::Current' });
release('Generated', { 'extension.c' => '#include "perl.h"' });
release('Pure', { 'ppport.h' => '#include "perl.h"',
                  't/example.xs' => 'MODULE = Example',
                  'eg/Foo/lib/Foo.xs' => 'MODULE = Example',
                  'examples/demo.c' => '#include "perl.h"' });
my $old = release('OlderCore', { 'Old.xs' => 'MODULE = Old' });
$old->{observations}[0]{platform} = {
    key => 'linux/test', build_id => 'older',
    build => { rc_stack => 1, xperl_commit => 'older-core' },
};
my $other = release('OtherHost', { 'Host.xs' => 'MODULE = Host' });
my $newer = release('OtherHost', { 'Host.xs' => 'MODULE = Host' }, '2.00');
pop @records;
push @{$other->{observations}}, {
    %{$newer->{observations}[0]},
    platform => { %$platform, key => 'darwin/test' },
};
$other->{observations}[0]{platform} = {
    %$platform, build_id => 'ordinary', build => { rc_stack => 0 },
};
my $changed = release('ChangedPatch', { 'Patch.xs' => 'MODULE = Patch' });
$changed->{observations}[0]{patch_sha256} = ['superseded'];
my $failed = release('FailedAgain', { 'Failed.xs' => 'MODULE = Failed' });
push @{$failed->{observations}}, {
    %{$failed->{observations}[0]}, status => 'failed',
    phases => [{ name => 'test', exit_status => 1 }],
};
release('Deferred', { 'Deferred.xs' => 'MODULE = Deferred' });
my $unknown = release('Unknown', { 'Unknown.xs' => 'MODULE = Unknown' });
$unknown->{observations}[0]{source_sha256} = 'changed';

my $report = XPerl::Installer::Coverage->scan(
    registry => bless({}, 'FixtureRegistry'),
    fetcher => XPerl::Installer::Fetch->new(cache => $root),
    platform => $platform, exclude => ['EXAMPLE/Deferred'],
);
my %native = map { $_->{distribution} => $_ } @{$report->{native}};
is($report->{counts}{baseline}, 9, 'all recorded local successes are inventoried');
ok(!exists($native{Pure}), 'test XS and ppport.h do not classify pure Perl as native');
is($native{Current}{state}, 'validated', 'exact source, patch and build pass is covered');
is($native{Generated}{native_sources}[0]{kind}, 'perl_api',
   'generated Perl API C source identifies an extension without an XS file');
is($native{OlderCore}{state}, 'needs_replay', 'an older RC core is not current validation');
is(scalar @{$native{OlderCore}{rc_validations}}, 1, 'older RC evidence remains visible');
is($native{OtherHost}{state}, 'needs_replay', 'another platform cannot validate this host');
is($native{OtherHost}{version}, '2.00',
   'coverage selects the same newest recorded release as install-ported');
is($native{ChangedPatch}{state}, 'needs_replay', 'a different patch digest needs replay');
is($native{FailedAgain}{state}, 'failed_current', 'a newer failure supersedes an earlier pass');
is($native{Deferred}{state}, 'deferred', 'excluded repairs stay visible outside the queue');
is($report->{unknown}[0]{reason}, 'cached source digest differs',
   'a changed archive is unknown rather than assumed non-native');

done_testing();
