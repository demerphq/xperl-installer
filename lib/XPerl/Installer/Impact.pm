package XPerl::Installer::Impact;

use strict;
use warnings;
use feature 'signatures';
use Encode qw(encode);
use HTTP::Tiny;
use JSON::PP;

our $VERSION = '0.01';

sub new ($class, %args) {
    return bless {
        base => $args{base} // 'https://grep.metacpan.org/api/search',
        get => $args{get} // sub ($url) {
            return HTTP::Tiny->new(timeout => 60)->get($url);
        },
        max_pages => $args{max_pages} // 20,
    }, $class;
}

sub scan ($self, %args) {
    my $patterns = $args{patterns} // [];
    die "scan-impact requires at least one --pattern\n" unless @$patterns;

    my $files = $args{files} // '*.c, *.xs, *.h, *.inc';
    my $ignore = $args{ignore} // 'ppport.h';
    my (%distros, @queries);
    my $incomplete = 0;

    for my $pattern (@$patterns) {
        die "scan-impact patterns must be nonempty\n"
            unless defined $pattern && length $pattern;

        my %seen;
        my ($total, $page) = (undef, 1);
        while ($page <= $self->{max_pages}) {
            my $response = $self->_page($pattern, $files, $ignore, $page);
            $total = $response->{match}{distros} // 0;
            $incomplete ||= $response->{is_incomplete} ? 1 : 0;

            for my $result (@{$response->{results} // []}) {
                my $name = $result->{distro};
                next unless defined $name;
                $seen{$name} = 1;
                next if $name eq 'perl';

                for my $match (@{$result->{matches} // []}) {
                    my $file = $match->{file};
                    next unless defined $file;
                    my $entry = ($distros{$name}{$file} //= {});
                    $entry->{patterns}{$pattern} = 1;
                    for my $block (@{$match->{blocks} // []}) {
                        $entry->{lines}{$_} = 1
                            for @{$block->{matchlines} // []};
                    }
                }
            }

            last if keys(%seen) >= $total || !@{$response->{results} // []};
            $page++;
        }

        $incomplete = 1 if defined($total) && keys(%seen) < $total;
        push @queries, { pattern => $pattern, distributions => scalar keys %seen };
    }

    my @candidates;
    for my $name (sort keys %distros) {
        my @matches;
        for my $file (sort keys %{$distros{$name}}) {
            my $entry = $distros{$name}{$file};
            push @matches, {
                file => $file,
                lines => [sort { $a <=> $b } keys %{$entry->{lines} // {}}],
                patterns => [sort keys %{$entry->{patterns}}],
            };
        }
        push @candidates, { distribution => $name, matches => \@matches };
    }

    return {
        source => $self->{base},
        files => $files,
        ignore => $ignore,
        queries => \@queries,
        incomplete => $incomplete ? JSON::PP::true : JSON::PP::false,
        candidates => \@candidates,
    };
}

sub _page ($self, $pattern, $files, $ignore, $page) {
    my $url = $self->{base} . '?' . join '&',
        _parameter(q => $pattern),
        _parameter(qft => $files),
        _parameter(qifl => $ignore),
        _parameter(p => $page);

    for (1 .. 5) {
        my $response = $self->{get}->($url);
        die "grep.metacpan.org request failed: $response->{status} $response->{reason}\n"
            unless $response->{success};
        my $body = eval { JSON::PP->new->decode($response->{content}) };
        die "invalid grep.metacpan.org response: $@\n" if $@;
        return $body unless $body->{search_in_progress};
        sleep 1;
    }

    die "grep.metacpan.org search did not finish; retry later\n";
}

sub _parameter ($name, $value) {
    my $bytes = encode('UTF-8', $value);
    $bytes =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return "$name=$bytes";
}

1;

__END__

=head1 NAME

XPerl::Installer::Impact - find CPAN source affected by an XPerl change

=head1 DESCRIPTION

Searches grep.metacpan.org for source patterns and returns candidate CPAN
distributions with matching files and line numbers. A source match is not a
build failure. Review the code and test the distribution before recording a
compatibility status or patch in the ports registry.

=cut
