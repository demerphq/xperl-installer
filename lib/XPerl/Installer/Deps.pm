package XPerl::Installer::Deps;

use strict;
use warnings;
use feature 'signatures';
use Archive::Tar;
use Config;
use CPAN::Meta;
use CPAN::Meta::Requirements;
use File::Spec;
use Module::Metadata;
use Parse::CPAN::Meta;

# Options:
#   fetcher, builder  required
#   prefer            optional code reference called with a module name; it
#                     returns a fetched release to use instead of the CPAN
#                     index answer, or undef. Batch installs use it to build
#                     recorded releases.
sub new ($class, %args) {
    die "fetcher and builder are required\n"
        unless $args{fetcher} && $args{builder};
    my $self = bless {
        fetcher => $args{fetcher},
        builder => $args{builder},
        prefer => $args{prefer},
        installed => {},    # cpan_path => receipt path
        failed => {},       # cpan_path => reason
        provided => {},     # module => version declared by an installed release
        receipts => [],
    }, $class;
    $self->reset_request;
    return $self;
}

# Forget the constraints and traversal state of a previous request while
# keeping what was installed or failed. A batch calls this between entries
# so unrelated requests cannot conflict with each other.
sub reset_request ($self) {
    $self->{needed} = CPAN::Meta::Requirements->new;
    $self->{visiting} = {};
    $self->{stack} = [];
    return;
}

sub install ($self, $module) {
    $self->_install($module, '0');
    return {
        module => $module,
        status => 'installed',
        receipts => $self->{receipts},
    };
}

# Build one exact, already fetched release and its prerequisites, even when
# the requested module is already available elsewhere on @INC.
sub install_release ($self, $release) {
    my $module = $release->{module};
    $self->{needed}->add_string_requirement($module, '0');
    $self->_enter($module);
    $self->_build($release, $module, force => 1);
    die "installed distribution does not provide required $module\n"
        unless $self->_satisfied($module);
    $self->_leave($module);
    return $self->{installed}{$release->{cpan_path}};
}

sub mark_installed ($self, $cpan_path, $receipt) {
    $self->{installed}{$cpan_path} = $receipt;
    return;
}

sub _install ($self, $module, $constraint) {
    $self->{needed}->add_string_requirement($module, $constraint);
    return if $self->_satisfied($module);
    $self->_enter($module);

    # A prerequisite's own failure is reported to its dependents as a
    # dependency failure that names the release that failed, so no parent is
    # blamed (or recorded as failed) for it.
    my $nested = @{$self->{stack}} > 1;
    my $release = $self->{prefer} ? $self->{prefer}->($module) : undef;
    if (!$release) {
        $release = $self->{fetcher}->fetch($module);
        die "CPAN index version $release->{version} does not satisfy $module $constraint\n"
            unless $self->{needed}->accepts_module($module, $release->{version});
    }
    if ($nested) {
        eval { $self->_build($release, $module); 1 } or do {
            my $error = $@ || "installation failed\n";
            die $error if $error =~ /\Adependency (?:failed|cycle)/;
            my ($reason) = split /\n/, $error;
            die "dependency failed: $release->{cpan_path}: $reason\n";
        };
    }
    else {
        $self->_build($release, $module);
    }
    die "installed distribution does not provide required $module\n"
        unless $self->_satisfied($module);
    $self->_leave($module);
}

sub _enter ($self, $module) {
    if ($self->{visiting}{$module}) {
        my @stack = @{$self->{stack}};
        my ($start) = grep { $stack[$_] eq $module } 0 .. $#stack;
        die "dependency cycle: "
            . join(' -> ', @stack[$start .. $#stack], $module) . "\n";
    }
    $self->{visiting}{$module} = 1;
    push @{$self->{stack}}, $module;
}

sub _leave ($self, $module) {
    delete $self->{visiting}{$module};
    pop @{$self->{stack}};
}

sub _build ($self, $release, $module, %options) {
    my $path = $release->{cpan_path};
    die "dependency failed: $path: $self->{failed}{$path}\n"
        if exists $self->{failed}{$path};
    if ($self->{installed}{$path}) {
        return if $options{force} || $self->_satisfied($module);
        die "distribution $path was already installed but lacks $module\n";
    }
    my $built = eval {
        my $meta = eval { _metadata($release->{archive}) };
        die "invalid CPAN metadata for $module ($path): $@" if $@;
        if ($meta) {
            $release->{distribution} //= $meta->name;
            $release->{distribution_version} //= $meta->version;
            my $structure = $meta->as_struct;
            $release->{x_use_unsafe_inc} = $structure->{x_use_unsafe_inc} ? 1 : 0
                if exists $structure->{x_use_unsafe_inc};
            $self->_install_prereqs($meta);
        }
        elsif (!defined $release->{distribution}) {
            ($release->{distribution}, $release->{distribution_version}) =
                _identity_from_path($path);
        }
        return 1 if !$options{force} && $self->_satisfied($module);
        my $receipt = $self->{builder}->install($release,
            after_configure => sub ($source) {
                for my $name (qw(MYMETA.json MYMETA.yml)) {
                    my $meta_path = File::Spec->catfile($source, $name);
                    next unless -f $meta_path;
                    my $configured = CPAN::Meta->load_file($meta_path,
                        { lazy_validation => 1 });
                    $self->_install_prereqs($configured);
                    last;
                }
            });
        $self->{installed}{$path} = $receipt->{receipt};
        $self->_remember_provides($meta) if $meta;
        push @{$self->{receipts}}, $receipt->{receipt};
        1;
    };
    return if $built;
    my $error = $@ || "installation failed\n";
    # A failure inside a prerequisite is recorded against that prerequisite;
    # this release failed because of it.
    if ($error !~ /\Adependency (?:failed|cycle)/) {
        (my $reason = $error) =~ s/\s+\z//;
        $self->{failed}{$path} = (split /\n/, $reason)[0];
    }
    die $error;
}

sub _install_prereqs ($self, $meta) {
    my $required = $meta->effective_prereqs->merged_requirements(
        [qw(configure build test runtime)], ['requires']);
    for my $dependency (sort $required->required_modules) {
        my $range = $required->requirements_for_module($dependency);
        if ($dependency eq 'perl') {
            die "XPerl $^V does not satisfy perl $range\n"
                unless $required->accepts_module('perl', $^V);
            next;
        }
        $self->_install($dependency, $range);
    }
}

sub _satisfied ($self, $module) {
    my $prefix = $self->{builder}->{prefix};
    my $site = File::Spec->catdir($prefix, 'lib', 'perl5');
    my @inc = ($site, File::Spec->catdir($site, $Config{archname}), @INC);
    my $metadata = Module::Metadata->new_from_module($module, inc => \@inc);
    my $version = $metadata ? $metadata->version // '0'
        : $self->{provided}{$module};
    return 0 unless defined $version;
    return $self->{needed}->accepts_module($module,
                                           $version);
}

sub _remember_provides ($self, $meta) {
    my $site = File::Spec->catdir($self->{builder}->{prefix}, 'lib', 'perl5');
    my $provides = $meta->provides;
    for my $module (keys %$provides) {
        my $entry = $provides->{$module};
        my $file = $entry->{file} // '';
        next unless $file =~ m{\Alib/([A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*\.pm)\z};
        my @parts = split m{/}, $1;
        next unless -f File::Spec->catfile($site, @parts)
            || -f File::Spec->catfile($site, $Config{archname}, @parts);
        $self->{provided}{$module} = $entry->{version} // '0';
    }
}

sub _metadata ($archive) {
    my $tar = Archive::Tar->new;
    $tar->read($archive, 1) or die "cannot read $archive\n";
    my @files = $tar->get_files;
    for my $suffix (qw(META.json META.yml)) {
        my ($file) = grep { $_->full_path =~ m{\A[^/]+/\Q$suffix\E\z} }
            @files;
        next unless $file;
        my $data = $suffix eq 'META.json'
            ? Parse::CPAN::Meta->load_json_string($file->get_content)
            : Parse::CPAN::Meta->load_yaml_string($file->get_content);
        return CPAN::Meta->new($data, { lazy_validation => 1 });
    }
    return;
}

sub _identity_from_path ($path) {
    my ($name, $version) = $path =~
        m{/([A-Za-z0-9][A-Za-z0-9_.-]*)-([vV]?[0-9][A-Za-z0-9._-]*)\.(?:tar\.gz|tgz)\z};
    die "cannot determine distribution identity from $path\n"
        unless defined $name && defined $version;
    return ($name, $version);
}

1;
