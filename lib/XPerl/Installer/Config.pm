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
                       phase_timeout native_prefixes layout)], 'install');
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
    if (exists $install->{phase_timeout}) {
        die "config install.phase_timeout must be a non-negative integer\n"
            unless !ref($install->{phase_timeout}) && defined($install->{phase_timeout})
                && $install->{phase_timeout} =~ /\A\d+\z/;
    }
    if (exists $install->{native_prefixes}) {
        my $prefixes = $install->{native_prefixes};
        die "config install.native_prefixes must be a list of directories\n"
            unless ref($prefixes) eq 'ARRAY'
                && !grep { ref || !defined || !length } @$prefixes;
    }
    for my $key (grep { !/\A(?:jobs|repair_jobs|phase_timeout|native_prefixes)\z/ }
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
        _keys($profile, [qw(command attempts timeout limit)], "agents.$name");
        my $command = $profile->{command};
        die "config agents.$name.command must be a nonempty string\n"
            if !defined($command) || ref($command) || !length($command);
        $profile->{command} = File::Spec->rel2abs($command, $base)
            unless File::Spec->file_name_is_absolute($command);
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
    }

    return $config;
}

sub _keys ($table, $allowed, $where) {
    my %allowed = map { $_ => 1 } @$allowed;
    for my $key (keys %$table) {
        die "unknown config key $where.$key\n" unless $allowed{$key};
    }
}

1;
