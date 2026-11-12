package XPerl::Installer::Triage;

use strict;
use warnings;
use feature 'signatures';

# Keep public triage deliberately structured. Local notes and command paths
# belong in the receipt's work directory, not in the shared registry.
sub validate ($class, $report) {
    die "invalid triage: expected schema 1\n"
        unless ref($report) eq 'HASH' && ($report->{schema} // '') eq '1';
    my $disposition = $report->{disposition} // '';
    die "invalid triage disposition\n"
        unless !ref($disposition) && $disposition =~
            /\A(?:upstream-broken|unsupported-platform|obsolete-superseded|unresolved)\z/;
    my $reason = _text($report->{reason}, 'reason');
    die "invalid triage: expected evidence references\n"
        unless ref($report->{references}) eq 'ARRAY';
    my @references;
    for my $reference (@{$report->{references}}) {
        die "invalid triage reference\n"
            unless ref($reference) eq 'HASH' && !ref($reference->{url})
                && ($reference->{url} // '') =~
                    m{\Ahttps?://[^\s/\@:]+(?::[0-9]+)?(?:[/?#][^\s]*)?\z};
        push @references, { url => $reference->{url} };
    }
    my @baselines;
    die "invalid triage: baselines must be a list\n"
        if exists($report->{baselines}) && ref($report->{baselines}) ne 'ARRAY';
    for my $baseline (@{$report->{baselines} // []}) {
        die "invalid triage baseline: expected ordinary Perl\n"
            unless ref($baseline) eq 'HASH'
                && ($baseline->{implementation} // '') eq 'perl';
        my $version = $baseline->{perl_version} // '';
        die "invalid triage baseline: expected exact Perl version\n"
            unless !ref($version) && $version =~ /\Av?5\.\d+\.\d+\z/;
        my $result = $baseline->{result} // '';
        die "invalid triage baseline result\n"
            unless !ref($result) && $result =~ /\A(?:pass|same-failure|different-failure)\z/;
        my $build = $baseline->{build};
        die "invalid triage baseline: expected build configuration\n"
            unless ref($build) eq 'HASH';
        my %flags;
        for my $flag (qw(rc_stack useithreads usemultiplicity debugging
                         uselongdouble usequadmath)) {
            die "invalid triage baseline: missing boolean $flag\n"
                unless defined($build->{$flag}) && !ref($build->{$flag})
                    && $build->{$flag} =~ /\A[01]\z/;
            $flags{$flag} = 0 + $build->{$flag};
        }
        push @baselines, {
            implementation => 'perl', perl_version => $version,
            os => _text($baseline->{os}, 'baseline OS'),
            archname => _text($baseline->{archname}, 'baseline architecture'),
            result => $result, build => \%flags,
        };
    }
    # A red matrix cell alone does not establish the same failure. Require
    # the exact control version and configuration, plus accessible evidence.
    die "upstream-broken triage needs a matching ordinary Perl failure and evidence\n"
        if $disposition eq 'upstream-broken'
            && (!@references || !grep { $_->{result} eq 'same-failure' } @baselines);
    die "$disposition triage needs supporting references\n"
        if $disposition =~ /\A(?:unsupported-platform|obsolete-superseded)\z/
            && !@references;
    my %seen;
    @references = sort { $a->{url} cmp $b->{url} }
        grep { !$seen{$_->{url}}++ } @references;
    return { schema => 1, disposition => $disposition, reason => $reason,
             references => \@references, baselines => \@baselines };
}

sub _text ($value, $name) {
    die "invalid triage $name: expected portable single-line text\n"
        unless defined($value) && !ref($value) && length($value)
            && $value !~ /[\r\n\0]/
            && $value !~ m{(?:/(?:home|Users|tmp|var/tmp)/|[A-Za-z]:[\\/])};
    return $value;
}

1;

__END__

=head1 NAME

XPerl::Installer::Triage - Validate portable failure assessments

=head1 DESCRIPTION

C<validate($report)> checks and copies a schema-1 assessment. Dispositions
are C<upstream-broken>, C<unsupported-platform>, C<obsolete-superseded>, or
C<unresolved>. Every report has a portable C<reason>, C<references> with
HTTP(S) URLs, and optional C<baselines> describing ordinary Perl controls.

An C<upstream-broken> assessment requires a C<same-failure> baseline and
supporting references. Each baseline records C<implementation> (C<perl>),
an exact C<perl_version>, C<os>, C<archname>, C<result>, and boolean C<build>
fields C<rc_stack>, C<useithreads>, C<usemultiplicity>, C<debugging>,
C<uselongdouble>, and C<usequadmath>. Baseline results may instead be C<pass>
or C<different-failure>. These controls document observations, not a claim
that every ordinary Perl configuration behaves alike.

Confirmed XPerl or RC-stack incompatibilities should be repaired. They are
not deferral dispositions, including when ordinary RC-stack Perl fails too.

=cut
