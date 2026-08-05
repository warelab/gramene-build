#!/usr/bin/env perl
use strict;
use warnings;

# merge_reg_pm.pl — merge Ensembl registry (reg.pm) files.
#
#   merge_reg_pm.pl base.pm override.pm [more.pm ...] > merged.pm 2> conflicts.txt
#
# Entries are keyed on (species, group). When the same key appears in more than one file the LAST
# file wins; every collision is reported on stderr with file:line and the dbname on each side.
# stdout is the merged registry; nothing is written in place.
#
# This LOADS each registry with Perl rather than parsing it as text, so a file is free to build its
# adaptors any way it likes -- the loop form
#
#     for my $core (@core_10_108_2) {
#         Bio::EnsEMBL::DBSQL::DBAdaptor->new('-species' => $core, ... );
#     }
#
# registers exactly like a hand-written stanza, and comes back out as one flat stanza per genome.
# Conditionals, subs, config read from elsewhere: all fine, because we inspect what was registered
# instead of guessing from source. Commented-out stanzas simply never register.
#
# DBAdaptor->new does not connect (the DBConnection is lazy), so this runs fine against servers that
# are down or unreachable, and never needs database credentials to work.
#
# LIMITATION worth knowing: the output is regenerated from the registry, not spliced from the
# inputs. Anything an input does BESIDES registering adaptors, adding aliases, and setting
# no_version_check / no_cache_warnings is not carried over -- it had its effect while loading and is
# then gone. Loops and variables are resolved away by design; a file that, say, monkey-patches an
# adaptor class would lose that. Nothing in the registries here does anything of the sort.
#
# Because every value is resolved and emitted literally, the merged file has no variables at all,
# which removes an entire class of bug: registries routinely share variable NAMES with different
# VALUES ($grm_host is 'colden' in the live REST registry and 'cabot' in the v11 release registry,
# and both spell their stanzas -host => $grm_host), so any textual merge risks silently repointing
# one file's databases at the other file's server.

use File::Spec;
use File::Basename qw(basename);
use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Utils::ConfigRegistry;

my $USAGE = <<"END";
usage: merge_reg_pm.pl [--provenance] base.pm override.pm [more.pm ...] > merged.pm

  Later files take precedence on (species, group). Conflicts are listed on stderr.

  --provenance   annotate each stanza with the file:line it came from
  -h, --help     this message
END

my $provenance = 0;
my @files;
for my $a (@ARGV) {
    if    ($a eq '--provenance')            { $provenance = 1 }
    elsif ($a eq '-h' or $a eq '--help')    { print $USAGE; exit 0 }
    elsif ($a =~ /^-/)                      { print STDERR "unknown option: $a\n\n$USAGE"; exit 2 }
    else                                    { push @files, $a }
}
unless (@files) { print STDERR $USAGE; exit 2 }

# ---------------------------------------------------------------- capture registrations

# Registry->add_DBAdaptor is the single choke point every adaptor passes through, whoever built it
# and however. Wrapping it gets us the caller's file and line even when the call came from inside a
# loop -- which is the whole point of doing this in Perl.
my $CURRENT;        # path of the file being loaded
my @EVENTS;         # registrations that actually landed in the registry, in order
my @ATTEMPTS;       # every adaptor construction, including ones the registry absorbs
my @ALIASES;        # explicit add_alias calls
our $CUR_ATTEMPT;   # package-scoped so the hook can localise it (and unwind safely on die)

# Innermost stack frame belonging to the registry file itself -- for a loop-built adaptor this is
# the line inside the loop body, which is what you want to be told about.
sub caller_line {
    for (my $i = 0; my @c = caller($i); $i++) {
        return $c[2] if defined $CURRENT && $c[1] eq $CURRENT;
    }
    return undef;
}

{
    no strict 'refs';
    no warnings 'redefine';

    # gen_load sees every construction. It does NOT always register: an adaptor whose species,
    # group AND connection all match one already present is returned as-is (ConfigRegistry.pm:147),
    # and one that clashes on species+group with a DIFFERENT connection gets its species silently
    # renamed to "<species>1" (:155). Both are worth reporting, and neither is visible from
    # add_DBAdaptor alone.
    my $orig_load = \&Bio::EnsEMBL::Utils::ConfigRegistry::gen_load;
    *Bio::EnsEMBL::Utils::ConfigRegistry::gen_load = sub {
        my ($dba) = @_;
        my $a = {
            species    => lc($dba->species // ''),
            group      => lc($dba->group // ''),
            dbname     => scalar eval { $dba->dbc->dbname },
            line       => caller_line(),
            registered => 0,
        };
        push @ATTEMPTS, $a;
        local $CUR_ATTEMPT = $a;
        return $orig_load->(@_);
    };

    my $orig_add = \&Bio::EnsEMBL::Registry::add_DBAdaptor;
    *Bio::EnsEMBL::Registry::add_DBAdaptor = sub {
        my ($class, $species, $group, $adap) = @_;
        my $ret = $orig_add->(@_);
        $CUR_ATTEMPT->{registered} = 1 if $CUR_ATTEMPT;
        # resolved after the original ran, so the self-alias it adds is already in place
        my $resolved = Bio::EnsEMBL::Registry->get_alias($species);
        push @EVENTS, {
            species => lc($resolved // $species),
            group   => lc($group // ''),
            class   => ref($adap),
            adap    => $adap,
            line    => ($CUR_ATTEMPT ? $CUR_ATTEMPT->{line} : caller_line()),
            renamed => ($CUR_ATTEMPT && lc($resolved // '') ne $CUR_ATTEMPT->{species})
                       ? $CUR_ATTEMPT->{species} : undef,
        };
        return $ret;
    };

    # Aliases must be captured here rather than read back with get_all_aliases, which can only be
    # asked about one species at a time: an alias for a species with no adaptor in this file would
    # simply never be found and would be dropped from the merge.
    my $orig_alias = \&Bio::EnsEMBL::Registry::add_alias;
    *Bio::EnsEMBL::Registry::add_alias = sub {
        my ($class, $species, $key) = @_;
        # Skip self-aliases: add_DBAdaptor registers one for every species, and a hand-written
        # add_alias('sorghum_bicolor','Sorghum_bicolor') is also one, because the registry stores
        # aliases lowercased -- it resolves through lc() at lookup time, so a case-only alias is
        # already a no-op in the input and dropping it changes nothing.
        push @ALIASES, { species => lc($species), alias => $key, line => caller_line() }
            if defined $species && defined $key && lc($species) ne lc($key);
        return $orig_alias->(@_);
    };
}

sub conn_of {
    my ($e) = @_;
    my $a = $e->{adap};
    my $c = eval { $a->dbc };
    return {} unless $c;
    my %h = (
        host   => scalar eval { $c->host },
        port   => scalar eval { $c->port },
        user   => scalar eval { $c->username },
        pass   => scalar eval { $c->password },
        dbname => scalar eval { $c->dbname },
        driver => scalar eval { $c->driver },
    );
    $h{species_id}   = eval { $a->species_id };
    $h{multispecies} = eval { $a->is_multispecies } ? 1 : 0;
    return \%h;
}

# ---------------------------------------------------------------- load each file

my $problems = 0;
sub warnline { print STDERR "$_[0]\n" }
sub issue    { $problems++; print STDERR "$_[0]\n" }

my %seen_base;
$seen_base{ basename($_) }++ for @files;
my $uniq_base = (grep { $seen_base{$_} > 1 } keys %seen_base) ? 0 : 1;
# Registry files are routinely all named "reg.pm", so a basename would be actively misleading.
sub nameof { my $i = shift; $uniq_base ? basename($files[$i]) : $files[$i] }
sub tag    { '[' . ($_[0] + 1) . ']' }
sub where  { my ($i, $l) = @_; tag($i) . ' ' . nameof($i) . ':' . (defined $l ? $l : '?') }

my (@per_file, @alias_events, @attempts_per_file, @warn_per_file);
my ($want_no_version_check, $want_no_cache_warnings) = (0, 0);

print STDERR 'merging ' . scalar(@files) . " registry file(s), later wins:\n";

for my $i (0 .. $#files) {
    my $path = File::Spec->rel2abs($files[$i]);
    die "cannot read $files[$i]: no such file\n" unless -r $path;

    Bio::EnsEMBL::Registry->clear();
    @EVENTS = @ATTEMPTS = @ALIASES = ();
    $CURRENT = $path;

    my @loadwarn;
    my $ok = do {
        local $SIG{__WARN__} = sub { push @loadwarn, $_[0] };
        do $path;
    };
    if ($@)                 { die "error loading $files[$i]:\n$@" }
    if (!defined $ok && $!) { die "error reading $files[$i]: $!\n" }

    $want_no_version_check  ||= (Bio::EnsEMBL::Registry->no_version_check()   ? 1 : 0);
    $want_no_cache_warnings ||= (Bio::EnsEMBL::Registry->no_cache_warnings() ? 1 : 0);

    # snapshot before the next clear() wipes it
    my @entries = map { { %$_, conn => conn_of($_), from => $i } } @EVENTS;
    push @per_file, \@entries;
    push @alias_events, { from => $i, aliases => [ @ALIASES ] };
    push @attempts_per_file, [ @ATTEMPTS ];
    push @warn_per_file, \@loadwarn;

    printf STDERR "  %s %s  (%d registrations, %d aliases)\n",
        tag($i), $files[$i], scalar(@entries), scalar(@ALIASES);
}
$CURRENT = undef;
Bio::EnsEMBL::Registry->clear();
print STDERR "\n";

# ---------------------------------------------------------------- merge

my (%entry, @order);
for my $i (0 .. $#per_file) {
    for my $e (@{ $per_file[$i] }) {
        my $key = $e->{species} . "\t" . $e->{group};

        if (my $prev = $entry{$key}) {
            $e->{history} = [ @{ $prev->{history} }, $prev ];
            $e->{order}   = $prev->{order};
        } else {
            $e->{history} = [];
            $e->{order}   = scalar @order;
            push @order, $key;
        }
        $entry{$key} = $e;
    }
}

# aliases: union, later files win when an alias points somewhere else
my (%alias_of, @alias_order);
for my $ev (@alias_events) {
    for my $a (@{ $ev->{aliases} }) {
        my $k = lc $a->{alias};
        if (exists $alias_of{$k} && $alias_of{$k}{species} ne $a->{species}) {
            issue("ALIAS '$a->{alias}' maps to '$alias_of{$k}{species}' in "
                . where($alias_of{$k}{from}, $alias_of{$k}{line})
                . " but to '$a->{species}' in " . where($ev->{from}, $a->{line}) . '   <- later wins');
            warnline('');
        }
        push @alias_order, $k unless exists $alias_of{$k};
        $alias_of{$k} = { %$a, from => $ev->{from} };
    }
}
my @alias_list = map { $alias_of{$_} } @alias_order;

# ---------------------------------------------------------------- report

my $dbof = sub { my $e = shift; $e->{conn}{dbname} // '?' };

# Duplicates inside one file never reach the registry -- Ensembl either absorbs them (identical
# connection) or renames the species. Report both from the attempt log, since a renamed species is
# a phantom entry that will appear in the merged output under a name nobody asked for.
for my $i (0 .. $#attempts_per_file) {
    my %first;
    for my $a (@{ $attempts_per_file[$i] }) {
        my $key = $a->{species} . "\t" . $a->{group};
        if (my $p = $first{$key}) {
            issue("DUPLICATE within " . nameof($i) . "  species=$a->{species} group=$a->{group}");
            warnline('    ' . where($i, $p->{line}) . '  dbname=' . ($p->{dbname} // '?'));
            warnline('    ' . where($i, $a->{line}) . '  dbname=' . ($a->{dbname} // '?')
                . ($a->{registered}
                    ? '   <- registered separately (Ensembl renamed the species)'
                    : '   <- identical, absorbed by Ensembl (never registered)'));
            warnline('');
        }
        $first{$key} ||= $a;
    }
}

for my $i (0 .. $#per_file) {
    for my $e (@{ $per_file[$i] }) {
        next unless $e->{renamed};
        issue('RENAMED ' . where($i, $e->{line}) . "  '$e->{renamed}' was already taken for group "
            . "'$e->{group}' with a different connection, so Ensembl registered this as "
            . "'$e->{species}' -- fix the input, the merged file will carry the invented name");
        warnline('');
    }
}

for my $i (0 .. $#warn_per_file) {
    for my $w (@{ $warn_per_file[$i] }) {
        chomp(my $t = $w);
        next unless length $t;
        issue('WARNING from ' . tag($i) . ' ' . nameof($i) . ': ' . join(' ', split ' ', $t));
    }
}

for my $key (@order) {
    my $e = $entry{$key};
    my @chain = grep { $_->{from} != $e->{from} } @{ $e->{history} };
    next unless @chain;
    my $same = !grep { ($dbof->($_) ne $dbof->($e)) } @chain;
    issue("CONFLICT species=$e->{species} group=$e->{group}" . ($same ? '   (same dbname)' : ''));
    warnline('    ' . where($_->{from}, $_->{line}) . '  dbname=' . $dbof->($_)) for @{ $e->{history} };
    warnline('    ' . where($e->{from}, $e->{line}) . '  dbname=' . $dbof->($e) . '   <- WINS');
    warnline('');
}

# ---------------------------------------------------------------- emit

sub q1 {   # single-quoted Perl literal
    my $v = shift;
    $v = '' unless defined $v;
    $v =~ s/\\/\\\\/g;
    $v =~ s/'/\\'/g;
    return "'$v'";
}

my @merged = map { $entry{$_} } @order;

my %bygroup;
$bygroup{ $_->{group} }++ for @merged;
my $summary = join ', ', map { "$bygroup{$_} $_" } sort keys %bygroup;

my @out;
push @out, '# Ensembl registry merged by build/merge_reg_pm.pl -- do not hand-edit, re-merge.';
push @out, '#   ' . tag($_) . ' ' . $files[$_] . '  (' . scalar(@{ $per_file[$_] }) . ' registrations)'
    for 0 .. $#files;
push @out, '# later files take precedence on (species, group)';
push @out, "#   " . scalar(@merged) . " entries: $summary";
push @out, '# values are resolved literals: any loops and variables in the inputs are expanded here.';
push @out, '';

my %classes = map { $_->{class} => 1 } @merged;
push @out, "use $_;" for sort keys %classes;
push @out, 'use Bio::EnsEMBL::Registry;';
push @out, '';
push @out, 'Bio::EnsEMBL::Registry->no_version_check(1);'   if $want_no_version_check;
push @out, 'Bio::EnsEMBL::Registry->no_cache_warnings(1);'  if $want_no_cache_warnings;
push @out, '';

for my $e (@merged) {
    my $c = $e->{conn};
    push @out, '# ' . (@{ $e->{history} } ? 'overrides ' . join(',', map { tag($_->{from}) } @{ $e->{history} }) . ' -- ' : '')
        . 'from ' . where($e->{from}, $e->{line}) if $provenance;
    push @out, $e->{class} . '->new(';
    push @out, "    '-species' => " . q1($e->{species}) . ',';
    push @out, "    '-group'   => " . q1($e->{group}) . ',';
    push @out, "    '-host'    => " . q1($c->{host}) . ',';
    push @out, "    '-port'    => " . (defined $c->{port} && $c->{port} =~ /^\d+$/ ? $c->{port} : q1($c->{port})) . ',';
    push @out, "    '-user'    => " . q1($c->{user}) . ',';
    push @out, "    '-pass'    => " . q1($c->{pass}) . ',';
    push @out, "    '-driver'  => " . q1($c->{driver}) . ','
        if defined $c->{driver} && lc $c->{driver} ne 'mysql';
    push @out, "    '-multispecies_db' => 1," if $c->{multispecies};
    push @out, "    '-species_id' => " . ($c->{species_id} + 0) . ','
        if $c->{multispecies} && defined $c->{species_id};
    push @out, "    '-dbname'  => " . q1($c->{dbname}) . ',';
    push @out, ');';
    push @out, '';
}

if (@alias_list) {
    push @out, "my \$REG = 'Bio::EnsEMBL::Registry';";
    push @out, '';
    my $w = 0;
    for (@alias_list) { $w = length($_->{species}) if length($_->{species}) > $w }
    push @out, sprintf("\$REG->add_alias( %-*s %s );", $w + 3, q1($_->{species}) . ',', q1($_->{alias}))
        for @alias_list;
    push @out, '';
}

push @out, '1;';
print join("\n", @out), "\n";

printf STDERR "merged %d entries (%s), %d aliases; %d item(s) reported above\n",
    scalar(@merged), $summary, scalar(@alias_list), $problems;
