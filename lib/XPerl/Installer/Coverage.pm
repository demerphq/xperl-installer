package XPerl::Installer::Coverage;

use strict;
use warnings;
use feature 'signatures';
use Archive::Tar;
use File::Basename qw(basename);
use File::Spec;
use IO::Uncompress::Unzip;
use JSON::PP;
use XPerl::Installer::Fetch;
use XPerl::Installer::Platform;
use XPerl::Installer::Ported;

my $JSON = JSON::PP->new->canonical;

sub scan ($class, %args) {
    my $registry = $args{registry} // die "registry is required\n";
    my $fetcher = $args{fetcher} // die "fetcher is required\n";
    my $platform = $args{platform} // XPerl::Installer::Platform::current();
    my $baseline_os = _platform_os($platform);
    my %excluded = map { $_ => 1 } @{$args{exclude} // []};
    my $records = $registry->status_records;
    die "coverage requires valid status records\n" if @{$records->{invalid}};
    my (@native, @unknown, %counts);

    # Previous successes on this OS define the distribution baseline, even
    # when a new build changes archname (for example, by enabling threads).
    # Select its release across all records exactly as install-ported does.
    for my $record (@{$records->{records}}) {
        next unless grep {
            _platform_os($_->{platform} // {}) eq $baseline_os
                && ($_->{status} // '') eq 'installed'
        } @{$record->{observations}};
        my $entry = XPerl::Installer::Ported::_select_release($record) or next;
        ++$counts{baseline};
        $args{progress}->($counts{baseline}, $entry->{key}) if $args{progress};
        my $identity = { map { $_ => $entry->{$_} }
            qw(key author distribution version module cpan_path source_sha256) };
        my $sources = eval { _native_sources($fetcher, $entry) };
        if (!$sources) {
            chomp(my $reason = $@ || 'archive inspection failed');
            my $portable = $reason =~ /\A(archive not cached|cached source digest differs)\z/
                ? $reason : 'archive inspection failed';
            warn "$entry->{key}: $reason\n" if $portable ne $reason;
            push @unknown, { %$identity, reason => $portable };
            ++$counts{unknown};
            next;
        }
        if (!@$sources) {
            ++$counts{no_native_source};
            next;
        }

        my $plan = XPerl::Installer::Ported::_plan_patches($registry, $entry);
        my $coverage = _validation($record, $entry, $plan, $platform);
        my $state = $excluded{$entry->{key}} ? 'deferred'
            : $plan->{error} ? 'registry_error' : $coverage->{state};
        push @native, {
            %$identity, native_sources => $sources,
            patch_sha256 => $plan->{patch_sha256} // [],
            state => $state,
            ($plan->{error} ? (reason => 'patch selection failed') : ()),
            rc_validations => $coverage->{rc_validations},
        };
        ++$counts{$state};
    }

    # Compiler and make paths are host details; build flags are already hashed.
    my %portable = %$platform;
    $portable{$_} = basename($portable{$_}) for grep { defined $portable{$_} }
        qw(cc make);
    return {
        schema => 1, xperl_version => "$^V", platform => \%portable,
        baseline_os => $baseline_os,
        counts => \%counts,
        native => [sort { $a->{key} cmp $b->{key} } @native],
        unknown => [sort { $a->{key} cmp $b->{key} } @unknown],
    };
}

sub _validation ($record, $entry, $plan, $platform) {
    my (%latest, $current);
    for my $observation (@{$record->{observations}}) {
        next unless ($observation->{cpan_path} // '') eq $entry->{cpan_path}
            && ($observation->{source_sha256} // '') eq $entry->{source_sha256};
        next unless $JSON->encode($observation->{patch_sha256} // [])
            eq $JSON->encode($plan->{patch_sha256} // []);
        my $observed = $observation->{platform} // {};
        next unless defined $observed->{build_id};
        $current = $observation
            if ($observed->{key} // '') eq $platform->{key}
                && $observed->{build_id} eq $platform->{build_id}
                && ($observation->{xperl_version} // '') eq "$^V";
        $latest{join '/', $observed->{key} // '', $observed->{build_id}} = $observation
            if $observed->{build}{rc_stack};
    }

    my @passes = grep { _passed($_) } values %latest;
    return {
        state => $current ? (_passed($current) ? 'validated' : 'failed_current')
            : 'needs_replay',
        rc_validations => [map {
            { build_id => $_->{platform}{build_id},
              platform => $_->{platform}{key},
              xperl_commit => $_->{platform}{build}{xperl_commit} }
        } sort { $a->{platform}{build_id} cmp $b->{platform}{build_id}
                     || $a->{platform}{key} cmp $b->{platform}{key} } @passes],
    };
}

sub _platform_os ($platform) {
    my ($os) = split m{/}, $platform->{key} // '';
    return $platform->{os} // $os // '';
}

sub _passed ($observation) {
    return ($observation->{status} // '') eq 'installed' && grep {
        $_->{name} eq 'test' && defined($_->{exit_status}) && !$_->{exit_status}
    } @{$observation->{phases} // []};
}

sub _native_sources ($fetcher, $entry) {
    XPerl::Installer::Fetch::_check_release_path($entry->{cpan_path});
    my $archive = File::Spec->catfile($fetcher->{cache}, 'authors', 'id',
                                      split m{/}, $entry->{cpan_path});
    die "archive not cached\n" unless -f $archive;
    die "cached source digest differs\n"
        unless XPerl::Installer::Fetch::_digest($archive) eq $entry->{source_sha256};
    my @sources;

    # Inspect member names and native-source contents without extracting or
    # executing the release. Missing archives remain unknown, never pure Perl.
    if ($archive =~ /\.zip\z/i) {
        my $zip = IO::Uncompress::Unzip->new($archive)
            or die "cannot read ZIP archive\n";
        my $next;
        do {
            my $path = $zip->getHeaderInfo->{Name};
            my $kind = _source_kind($path, sub {
                my $content = '';
                my $bytes;
                while (($bytes = $zip->read(my $part, 65536)) > 0) { $content .= $part }
                die "cannot read ZIP member\n" if $bytes < 0;
                return $content;
            });
            push @sources, { path => _relative($path), kind => $kind } if $kind;
            $next = $zip->nextStream;
        } while ($next > 0);
        die "cannot read ZIP archive\n" if $next < 0;
    }
    else {
        my $tar = Archive::Tar->new;
        $tar->read($archive, 1) or die "cannot read tar archive\n";
        for my $member ($tar->get_files) {
            next unless $member->is_file;
            my $kind = _source_kind($member->full_path,
                                    sub { $member->get_content });
            push @sources, { path => _relative($member->full_path), kind => $kind }
                if $kind;
        }
    }
    return [sort { $a->{path} cmp $b->{path} } @sources];
}

sub _relative ($path) {
    $path =~ s{\A\./}{};
    $path =~ s{\A[^/]+/}{};
    return $path;
}

sub _source_kind ($path, $content) {
    my $relative = _relative($path);
    return if $relative =~ m{\A(?:t|xt|tests?|eg|examples?|demos?|samples?|bench(?:marks)?)/}i
        || $relative =~ m{(?:\A|/)ppport\.h\z}i;
    return 'xs' if $relative =~ /\.xs(?:\.(?:in|PL))?\z/i;
    return unless $relative =~ /\.(?:c|cc|cpp|h|inc)\z/i;
    return 'perl_api' if $content->()
        =~ /\b(?:XS|XS_EXTERNAL|XS_INTERNAL)\s*\(|\#\s*include\s*["<](?:EXTERN|perl|XSUB)\.h[">]/;
    return;
}

1;

__END__

=head1 NAME

XPerl::Installer::Coverage - Native-source replay coverage for installed builds

=head1 DESCRIPTION

C<scan> inventories distributions with a recorded success on the current OS,
including other architecture names and build options. It selects exact
releases through the normal recorded-port rules,
then inspects cached source archives for XS inputs or native Perl API code.
No source is executed and no network request is made. Test and example
sources and C<ppport.h> do not identify a native distribution.

A validation requires the same release, source digest, ordered patch digests,
XPerl version and interpreter build identity, plus a successful test phase.
Other RC builds are reported separately. Missing or changed archives are
unknown. Source inspection identifies candidates, including optional XS,
rather than proving the build actually compiled an extension.

=cut
