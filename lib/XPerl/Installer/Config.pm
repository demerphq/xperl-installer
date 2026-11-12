package XPerl::Installer::Config;

use strict;
use warnings;
use feature 'signatures';
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use TOML::Tiny;

sub load ($class, $path) {
    open my $input, '<:raw', $path or die "cannot read config $path: $!\n";
    my $source = do { local $/; <$input> };
    close $input or die "cannot close config $path: $!\n";
    my $config = eval { TOML::Tiny->new(strict => 1)->decode($source) };
    die "cannot parse config $path: $@" if $@;
    die "config $path must contain a table\n" unless ref($config) eq 'HASH';
    die "config $path requires schema = 1\n"
        unless defined($config->{schema}) && $config->{schema} eq '1';
    _keys($config, [qw(schema install agents)], 'config');

    my $install = $config->{install} // {};
    die "config install must be a table\n" unless ref($install) eq 'HASH';
    _keys($install, [qw(prefix mirror cache workdir registry jobs repair_jobs
                       phase_timeout phase_memory_mb phase_log_mb native_prefixes
                       configure_args layout publish)], 'install');
    $install->{configure_args} = $class->configure_args($install->{configure_args})
        if exists $install->{configure_args};
    if (exists $install->{publish}) {
        die "config install.publish must be auto, direct, pr or off\n"
            unless defined($install->{publish}) && !ref($install->{publish})
                && $install->{publish} =~ /\A(?:auto|direct|pr|off)\z/;
    }
    if (exists $install->{layout}) {
        die "config install.layout must be auto, site or install_base\n"
            unless !ref($install->{layout}) && defined($install->{layout})
                && $install->{layout} =~ /\A(?:auto|site|install_base)\z/;
    }
    if (exists $install->{jobs}) {
        die "config install.jobs must be a positive integer\n"
            unless !ref($install->{jobs}) && defined($install->{jobs})
                && $install->{jobs} =~ /\A[1-9]\d*\z/;
    }
    if (exists $install->{repair_jobs}) {
        die "config install.repair_jobs must be a positive integer\n"
            unless !ref($install->{repair_jobs})
                && defined($install->{repair_jobs})
                && $install->{repair_jobs} =~ /\A[1-9]\d*\z/;
    }
    for my $key (qw(phase_timeout phase_memory_mb phase_log_mb)) {
        next unless exists $install->{$key};
        die "config install.$key must be a non-negative integer\n"
            unless !ref($install->{$key}) && defined($install->{$key})
                && $install->{$key} =~ /\A\d+\z/;
    }
    if (exists $install->{native_prefixes}) {
        my $prefixes = $install->{native_prefixes};
        die "config install.native_prefixes must be a list of directories\n"
            unless ref($prefixes) eq 'ARRAY'
                && !grep { ref || !defined || !length } @$prefixes;
    }
    for my $key (grep { !/\A(?:jobs|repair_jobs|phase_timeout|phase_memory_mb|phase_log_mb|native_prefixes|configure_args)\z/ }
                 keys %$install) {
        die "config install.$key must be a nonempty string\n"
            if ref($install->{$key}) || !defined($install->{$key})
                || !length($install->{$key});
    }

    my $agents = $config->{agents} // {};
    die "config agents must be a table\n" unless ref($agents) eq 'HASH';
    my $base = dirname(abs_path($path));
    for my $name (keys %$agents) {
        die "invalid agent name $name\n"
            unless $name =~ /\A[A-Za-z][A-Za-z0-9_-]*\z/;
        my $profile = $agents->{$name};
        die "config agents.$name must be a table\n"
            unless ref($profile) eq 'HASH';
        _keys($profile, [qw(command provider executable model effort add_dirs
                           attempts timeout limit interval)], "agents.$name");
        if (exists $profile->{command}) {
            my $command = $profile->{command};
            die "config agents.$name.command must be a nonempty string\n"
                if !defined($command) || ref($command) || !length($command);
            die "config agents.$name cannot combine command with provider options\n"
                if grep { exists $profile->{$_} }
                    qw(provider executable model effort add_dirs);
            $profile->{command} = File::Spec->rel2abs($command, $base)
                unless File::Spec->file_name_is_absolute($command);
        }
        else {
            $profile->{provider} //= $name;
            die "config agents.$name.provider must be codex or claude\n"
                unless !ref($profile->{provider})
                    && $profile->{provider} =~ /\A(?:codex|claude)\z/;
            for my $key (qw(executable model effort)) {
                next unless exists $profile->{$key};
                die "config agents.$name.$key must be a nonempty string\n"
                    if ref($profile->{$key}) || !defined($profile->{$key})
                        || !length($profile->{$key});
            }
            if (exists $profile->{effort}) {
                my $allowed = $profile->{provider} eq 'codex'
                    ? qr/\A(?:minimal|low|medium|high|xhigh|max)\z/
                    : qr/\A(?:low|medium|high|xhigh|max)\z/;
                die "config agents.$name.effort is unsupported\n"
                    unless $profile->{effort} =~ $allowed;
            }
            if (exists $profile->{add_dirs}) {
                my $dirs = $profile->{add_dirs};
                die "config agents.$name.add_dirs must be a list of directories\n"
                    unless ref($dirs) eq 'ARRAY'
                        && !grep { ref || !defined || !length } @$dirs;
                $profile->{add_dirs} = [map {
                    File::Spec->rel2abs($_, $base)
                } @$dirs];
            }
            # A bare program name is searched on PATH. An explicit relative
            # path belongs to the config file, as custom commands do.
            if (defined $profile->{executable}
                && $profile->{executable} =~ m{[/\\]}) {
                $profile->{executable} = File::Spec->rel2abs(
                    $profile->{executable}, $base);
            }
        }
        if (exists $profile->{attempts}) {
            die "config agents.$name.attempts must be a non-negative integer\n"
                unless $profile->{attempts} =~ /\A\d+\z/;
        }
        if (exists $profile->{limit}) {
            die "config agents.$name.limit must be a non-negative integer\n"
                unless $profile->{limit} =~ /\A\d+\z/;
        }
        if (exists $profile->{timeout}) {
            die "config agents.$name.timeout must be a positive integer\n"
                unless $profile->{timeout} =~ /\A[1-9]\d*\z/;
        }
        if (exists $profile->{interval}) {
            die "config agents.$name.interval must be a non-negative integer\n"
                unless $profile->{interval} =~ /\A\d+\z/;
        }
    }

    return $config;
}

# Copy argument lists so a resumed build or worker cannot change its caller's
# configuration. Author-qualified keys keep unrelated distributions separate.
sub configure_args ($class, $table) {
    die "configure_args must be a table of AUTHOR/Distribution argument lists\n"
        unless ref($table) eq 'HASH';
    my %arguments;
    for my $key (keys %$table) {
        die "invalid configure_args distribution key $key\n"
            unless $key =~ m{\A[A-Z0-9_-]+/[A-Za-z0-9][A-Za-z0-9_.-]*\z};
        my $values = $table->{$key};
        die "configure_args.$key must be a list of strings without NUL bytes\n"
            unless ref($values) eq 'ARRAY'
                && !grep { !defined || ref || /\0/ } @$values;
        $arguments{$key} = [@$values];
    }
    return \%arguments;
}

sub _keys ($table, $allowed, $where) {
    my %allowed = map { $_ => 1 } @$allowed;
    for my $key (keys %$table) {
        die "unknown config key $where.$key\n" unless $allowed{$key};
    }
}

1;

__END__

=head1 NAME

XPerl::Installer::Config - Installer TOML configuration

=head1 METHODS

C<load($path)> reads and validates a schema 1 TOML configuration.
C<configure_args($table)> validates and copies a mapping from
C<AUTHOR/Distribution> keys to argument arrays. The builder passes each
element as one argument to the selected distribution's configuration script.
The builder replaces C<{prefix}> with its absolute installation prefix.

=cut
