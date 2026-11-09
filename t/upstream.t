use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;
use XPerl::Installer::Upstream;

my $root = tempdir(CLEANUP => 1,
    DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $json = JSON::PP->new;

sub write_file {
    my ($name, $content) = @_;
    my $path = File::Spec->catfile($root, $name);
    open my $output, '>:raw', $path or die $!;
    print {$output} $content;
    close $output or die $!;
    return $path;
}

# Missing or invalid metadata must not stop diagnosis of a failed build.
is_deeply(XPerl::Installer::Upstream->resources($root), {},
          'a distribution without metadata has no guessed upstream');
write_file('META.json', '{invalid');
is_deeply(XPerl::Installer::Upstream->resources($root), {},
          'invalid release metadata does not stop repair');

# Older META.yml resource strings normalize through the core metadata API.
write_file('META.yml', <<'META');
---
name: Example
version: '1.00'
abstract: Upstream fixture
author:
  - Example
license: perl
generated_by: fixture
meta-spec:
  version: 1.4
resources:
  repository: https://example.org/project.git
  bugtracker: https://example.org/issues
META
my $resources = XPerl::Installer::Upstream->resources($root);
is($resources->{repository}{url}, 'https://example.org/project.git',
   'legacy repository metadata is normalized');
is($resources->{bugtracker}{web}, 'https://example.org/issues',
   'YAML bug tracker is available when JSON is invalid');

# Search outcomes are explicit; missing output cannot claim a search occurred.
my $path = File::Spec->catfile($root, 'research.json');
is(XPerl::Installer::Upstream->read_research($path)->{status}, 'not_reported',
   'an older agent without research output does not claim a check');
my $report = { schema => 1, status => 'checked',
    summary => 'No relevant existing reports', references => [] };
write_file('research.json', $json->encode($report));
is_deeply(XPerl::Installer::Upstream->read_research($path), {
    status => 'checked', summary => $report->{summary}, references => [],
}, 'a completed search may find no relevant reports');

$report->{status} = 'unavailable';
$report->{summary} = 'The agent cannot access the network';
write_file('research.json', $json->encode($report));
is(XPerl::Installer::Upstream->read_research($path)->{status}, 'unavailable',
   'unavailable access is different from a completed search');

# Only public HTTP(S) links enter evidence, never local report filenames.
for my $url ('file:///home/example/log', 'https://user:secret@example.org/issue') {
    $report->{references} = [{ url => $url }];
    write_file('research.json', $json->encode($report));
    my $ok = eval { XPerl::Installer::Upstream->read_research($path); 1 };
    like($ok ? '' : $@, qr/expected an HTTP\(S\) reference/,
         "reject private or credential-bearing reference: $url");
}

is_deeply(XPerl::Installer::Upstream->evidence([{
    status => 'checked', summary => 'See /home/example/build',
    references => [{ url => 'https://example.org/commit/abc' }],
}]), [{ status => 'checked',
        references => [{ url => 'https://example.org/commit/abc' }] }],
    'portable evidence omits free-form explanations with local paths');

done_testing();
