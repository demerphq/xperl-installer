use strict;
use warnings;
use feature 'signatures';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;

# A repair command may start a paid AI agent. A caller can cap the whole run,
# while the normal case gives every failed release its own repair allowance.

my $root = abs_path(tempdir(CLEANUP => 1,
                            DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $mirror = File::Spec->catdir($root, 'mirror');
my $cache = File::Spec->catdir($root, 'cache');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path(File::Spec->catdir($mirror, 'modules'), $releases);

my @index;
sub release ($name, @requires) {
    my $dist = "Example-$name-1.00";
    my $tar = Archive::Tar->new;
    $tar->add_data("$dist/Makefile.PL",
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Example::$name', VERSION => '1.00');\n");
    $tar->add_data("$dist/lib/Example/$name.pm",
        "package Example::$name;\nour \$VERSION = '1.00';\nsub value { 0 }\n1;\n");
    $tar->add_data("$dist/t/basic.t",
        "use Test::More tests => 1;\nuse Example::$name;\nis(Example::${name}::value(), 42);\n");
    $tar->add_data("$dist/META.json", JSON::PP->new->encode({
        'meta-spec' => { version => 2 }, name => "Example-$name", version => '1.00',
        abstract => 'fixture', author => ['XPerl'], license => ['perl_5'],
        generated_by => 'repair-limits.t', release_status => 'stable',
        dynamic_config => JSON::PP::false,
        prereqs => { runtime => { requires => { map { ("Example::$_" => 0) } @requires } } },
    }));
    $tar->write(File::Spec->catfile($releases, "$dist.tar.gz"), 1);
    push @index, "Example::$name 1.00 E/EX/EXAMPLE/$dist.tar.gz";
}
# Every release fails its test until repaired.
release('Leaf');
release('Stem', 'Leaf');
release('One');
release('Two');
release('Both', qw(One Two));
my $index = "File: 02packages.details.txt\n\n" . join("\n", sort @index) . "\n";
gzip \$index => File::Spec->catfile($mirror, 'modules', '02packages.details.txt.gz')
    or die $GzipError;

# The agent repairs any fixture module and logs when it ran.
my $agent = File::Spec->catfile($root, 'agent');
open my $agent_file, '>', $agent or die $!;
print {$agent_file} "#!$^X\n", <<'AGENT';
use strict;
use warnings;
use JSON::PP;
use Time::HiRes qw(time sleep);
my $request = do {
    open my $in, '<', $ARGV[0] or die $!;
    JSON::PP->new->decode(do { local $/; <$in> });
};
my $start = time;
sleep 1;
my $dir = "$request->{source}/lib/Example";
opendir my $dh, $dir or die $!;
for my $file (grep { /\.pm\z/ } readdir $dh) {
    my $path = "$dir/$file";
    open my $in, '<', $path or die $!;
    my $body = do { local $/; <$in> };
    close $in;
    $body =~ s/sub value \{ 0 \}/sub value { 42 }/;
    open my $out, '>', $path or die $!;
    print {$out} $body;
    close $out or die $!;
}
open my $log, '>>', $ENV{XPERL_AGENT_LOG} or die $!;
printf {$log} "%s %.3f %.3f\n", $request->{module}, $start, time;
close $log or die $!;
AGENT
close $agent_file or die $!;
chmod 0755, $agent or die $!;

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl-install');
my $run = 0;
sub install ($module, @extra) {
    ++$run;
    local $ENV{XPERL_AGENT_LOG} = File::Spec->catfile($root, "agent-$run.log");
    my $errors = File::Spec->catfile($root, "stderr-$run");
    open my $saved, '>&', \*STDERR or die $!;
    open STDERR, '>', $errors or die $!;
    open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
        '--cache', $cache, '--prefix', File::Spec->catdir($root, "prefix-$run"),
        '--workdir', File::Spec->catdir($root, "work-$run"),
        '--repair-command', $agent, '--repair-attempts', 1,
        '--repair-interval', 0, @extra, $module
        or die $!;
    open STDERR, '>&', $saved or die $!;
    my $output = do { local $/; <$pipe> };
    close $pipe;
    my $status = $? >> 8;
    $output .= do { open my $in, '<', $errors or die $!; local $/; <$in> };
    my @calls;
    if (open my $log, '<', $ENV{XPERL_AGENT_LOG}) {
        @calls = map { [split] } <$log>;
    }
    return ($status, \@calls, $output);
}

# Without a run-wide cap, both releases can use their own attempt allowance.
my ($status, $calls, $output) = install('Example::Stem');
is($status, 0, 'the run repairs both releases by default');
is(scalar @$calls, 2, 'each release receives its own repair call');

# An explicit run-wide cap still stops further calls.
($status, $calls, $output) = install('Example::Stem', '--repair-limit', 1);
isnt($status, 0, 'an explicit cap stops the second repair');
is(scalar @$calls, 1, 'the cap permits one agent call');
like($output, qr/repair limit/, 'the failure names the run-wide cap');

# Parallel builds never run two repairs at the same time.
($status, $calls) = install('Example::Both', '--jobs', 3, '--repair-limit', 3);
is($status, 0, 'parallel install with repairs succeeds');
is(scalar @$calls, 3, 'every broken release was repaired once');
my @sorted = sort { $a->[1] <=> $b->[1] } @$calls;
my $overlap = grep { $sorted[$_][1] < $sorted[$_ - 1][2] } 1 .. $#sorted;
is($overlap, 0, 'repair calls never overlap');

# A minimum interval spaces starts even when the agent finishes quickly.
($status, $calls) = install('Example::Stem', '--repair-interval', 2);
is($status, 0, 'a spaced run still repairs both releases');
@sorted = sort { $a->[1] <=> $b->[1] } @$calls;
cmp_ok($sorted[1][1] - $sorted[0][1], '>=', 1.9,
       'agent calls begin at least two seconds apart');

done_testing();
