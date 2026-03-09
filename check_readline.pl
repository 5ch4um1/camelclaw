#!/usr/bin/perl
use strict;
use warnings;
use lib '/usr/local/lib/x86_64-linux-gnu/perl/5.38.2';
use lib '/usr/local/share/perl/5.38.2';
use Term::ReadLine;

my $term = Term::ReadLine->new('test');
print "ReadLine Method: ", $term->ReadLine, "
";

eval {
    require Term::ReadLine::Gnu;
    print "Term::ReadLine::Gnu is LOADABLE
";
};
if ($@) {
    print "Term::ReadLine::Gnu LOAD ERROR: $@
";
}
