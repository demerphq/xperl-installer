package XPerl::Installer::Upstream;

use strict;
use warnings;
use feature 'signatures';
use CPAN::Meta;
use File::Spec;
use JSON::PP;

sub testers ($class, $release) {
    my $query = "$release->{distribution} $release->{distribution_version}";
    $query =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/eg;
    return "https://fast2-matrix.cpantesters.org/?dist=$query";
}

# Release metadata supplies starting points, not a reason to contact the
# network during ordinary installs. The repair agent does the investigation.
sub resources ($class, $source) {
    for my $name (qw(META.json META.yml)) {
        my $path = File::Spec->catfile($source, $name);
        next unless -f $path;
        my $meta = eval { CPAN::Meta->load_file($path) };
        next unless $meta;
        my $resources = $meta->resources;
        return { map { $_ => $resources->{$_} }
                 grep { exists $resources->{$_} }
                 qw(repository bugtracker homepage) };
    }
    return {};
}

# A separate report lets an agent record research alongside either a source
# fix or a human handoff. Older custom agents need not implement it.
sub read_research ($class, $path) {
    return { status => 'not_reported', references => [] } unless -f $path;
    open my $input, '<:raw', $path or die "cannot read upstream research $path: $!\n";
    my $report = JSON::PP->new->decode(do { local $/; <$input> });
    close $input or die "cannot close upstream research $path: $!\n";
    die "invalid upstream research: expected schema 1\n"
        unless ref($report) eq 'HASH' && ($report->{schema} // '') eq '1';
    die "invalid upstream research: expected checked or unavailable\n"
        unless !ref($report->{status})
            && ($report->{status} // '') =~ /\A(?:checked|unavailable)\z/;
    die "invalid upstream research: expected a summary and references\n"
        unless defined($report->{summary}) && !ref($report->{summary})
            && length($report->{summary})
            && ref($report->{references}) eq 'ARRAY';

    my @references;
    for my $reference (@{$report->{references}}) {
        die "invalid upstream research: expected an HTTP(S) reference\n"
            unless ref($reference) eq 'HASH' && !ref($reference->{url})
                && ($reference->{url} // '')
                    =~ m{\Ahttps?://[^\s/\@:]+(?::[0-9]+)?(?:[/?#][^\s]*)?\z};
        push @references, { url => $reference->{url} };
    }
    return { status => $report->{status}, summary => $report->{summary},
             references => \@references };
}

# Free-form agent explanations may contain local paths. Publish only the
# check outcome and public links; the full explanation stays in the receipt.
sub evidence ($class, $reports) {
    return [map { { status => $_->{status}, references => $_->{references} } }
            @$reports];
}

1;

__END__

=head1 NAME

XPerl::Installer::Upstream - Upstream context and repair research

=head1 DESCRIPTION

C<resources> reads repository, bug-tracker and homepage details from release
metadata without network access. C<read_research> loads the agent's optional
schema-1 report. Its status is C<checked> or C<unavailable>, with a C<summary>
and an array of C<references> containing HTTP(S) C<url> values. A missing
report is recorded as C<not_reported>, never as a completed search.

C<evidence> retains only check outcomes and reference URLs for publication.
Free-form summaries stay in local build receipts to avoid publishing paths
or other host details from the agent's explanation.

=cut
