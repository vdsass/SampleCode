#!/Perl64/bin/perl
use strict;
use warnings;

use lib qw( /users/dsass/mylib/lib/perl5 );
use DBI;
use File::Slurp;

my $USER     = 'root';
my $PASS     =  ask_pass();
my $SERVER   = 'localhost';
my $DB       = 'ATM';

my $DB_FILE = 'atm.mysql';
my $sql = read_file( $DB_FILE );
my $dbh = DBI->connect( "dbi:mysql:database=$DB;host=$SERVER", $USER, $PASS,
                      {  mysql_multi_statements => 1 } );
$dbh->do( $sql );

sub ask_pass
{
  #system "stty -echo";
  print "Password: ";
  chomp(my $word = <STDIN>);
  print "\n";
  #system "stty echo";
  return $word;
}
