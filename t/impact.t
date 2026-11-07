use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP;
use Test::More;
use XPerl::Installer::Impact;

my @requests;
my $scanner = XPerl::Installer::Impact->new(
    max_pages => 3,
    get => sub ($url) {
        push @requests, $url;
        my $page = $url =~ /[?&]p=2(?:&|\z)/ ? 2 : 1;
        my $body = $page == 1 ? {
            match => { distros => 3 },
            results => [
                {
                    distro => 'Example-XS',
                    matches => [{ file => 'XS.xs', blocks => [{
                        start_at => 10, matchlines => [12, 18], code => '',
                    }] }],
                },
                {
                    distro => 'perl',
                    matches => [{ file => 'hv.c', blocks => [{
                        start_at => 20, matchlines => [21], code => '',
                    }] }],
                },
            ],
        } : {
            match => { distros => 3 },
            results => [{
                distro => 'Another-XS',
                matches => [{ file => 'hash.inc', blocks => [{
                    start_at => 1, matchlines => [4], code => '',
                }] }],
            }],
        };
        return { success => 1, content => JSON::PP->new->encode($body) };
    },
);

# The second page is needed to cover every distribution in the API count.
# Perl core appears in that count but is not a CPAN porting candidate.
my $report = $scanner->scan(patterns => ['HvARRAY|HeNEXT']);
is(scalar @requests, 2, 'fetches both API pages');
like($requests[0], qr/q=HvARRAY%7CHeNEXT/, 'encodes the regex in the URL');
like($requests[0], qr/qft=%2A\.c%2C%20%2A\.xs%2C%20%2A\.h%2C%20%2A\.inc/,
    'searches C, XS, headers and include fragments');
like($requests[0], qr/qifl=ppport\.h/, 'ignores generated ppport.h');
is_deeply([map { $_->{distribution} } @{$report->{candidates}}],
    ['Another-XS', 'Example-XS'], 'keeps CPAN candidates in stable order');
is_deeply($report->{candidates}[1]{matches}[0]{lines}, [12, 18],
    'retains source line numbers');
ok(!$report->{incomplete}, 'reports complete pagination');

# A page cap must be visible to callers; it must not look like a complete
# census of affected distributions.
my $limited = XPerl::Installer::Impact->new(
    max_pages => 1,
    get => sub ($url) {
        return { success => 1, content => JSON::PP->new->encode({
            match => { distros => 2 },
            results => [{ distro => 'One-XS', matches => [] }],
        }) };
    },
)->scan(patterns => ['HvARRAY']);
ok($limited->{incomplete}, 'marks results incomplete when pagination stops');

done_testing;
