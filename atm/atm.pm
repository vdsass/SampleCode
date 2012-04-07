package ATM;
use strict;
use warnings;

use lib qw(/users/dsass/mylib/lib/perl5);
use base 'Class::DBI';
use Cwd;
use CGI::Carp qw(fatalsToBrowser);
# for user interface
use CGI qw(param);
# for admin interface
use DBI;
use Data::Dumper::Simple;

BEGIN
{
 use CGI::Carp qw(carpout);
 open(my $LOG, '>', "$0.log") or die("Unable to open $0.log: $!\n");
 carpout($LOG);
}

my $USER     = 'root';
my $PASS     = 'aurskdat9';
my $SERVER   = 'localhost';
my $DB       = 'ATM';

__PACKAGE__->connection( "dbi:mysql:database=$DB;host=$SERVER", $USER, $PASS );

package ATM::Account;
use base 'ATM';

__PACKAGE__->table( 'account' );
__PACKAGE__->columns( All => qw(id account_number balance) );
__PACKAGE__->has_many( owners => [ 'ATM::Customer' => 'person' ] );
__PACKAGE__->has_many( transactions => [ 'ATM::Transactions' => 'single_transaction' ] );
__PACKAGE__->autoupdate( 1 );


sub add_account
{
  my $self = shift;
  my %hash = @_;
  my $first_name      = $hash{first_name};
  my $last_name       = $hash{last_name};
  my $initial_deposit = $hash{initial_deposit};
  my $password        = $hash{password};

  my ( $last_id, $last_account_number, $account_id );
  my $accounts = ATM::Account->retrieve_all;
  while( my $id = $accounts->next )
  {
    $last_account_number = $id->account_number;
  }

  my $new_account_number = $last_account_number + 1;
  my ($account_obj) = ATM::Account->insert( { account_number => "$new_account_number",
                                               balance        => 0 } );

  $account_id = $account_obj->{id};

  my ($person_obj) = ATM::Person->insert( { first_name => $first_name,
                                             last_name  => $last_name } );
  my $person_id = $person_obj->{id};

  my ($customer_obj) = ATM::Customer->insert( { account   => $account_id,
                                                 person    => $person_id,
                                                 password  => $password } );

  my $type = 'credit';
  $account_obj->add_transaction( $type, $initial_deposit );

  return ($account_obj);
}

sub add_transaction
{
  my $self = shift;
  my ($type, $amount) = @_;

  my $id    = $self->{id};
  my $class = ref $self;

  my ($acct) = $class->search( id => $id );
  my $account_number = $acct->account_number;

  my ($account) = ATM::Account->search( account_number => $account_number );
  my $balance = $account->get( 'balance' );
  my ($trans_type) = ATM::Transaction::Type->search( name => $type );
  my $new_balance = $balance + ($type =~ /credit/i ? 1 : -1) * $amount;
  my $single_trans = ATM::Transaction::Single->insert( { amount           => $amount,
                                                         transaction_type => $trans_type,
                                                         previous_balance => $balance,
                                                         new_balance      => $new_balance,
                                                        } );
  ATM::Transactions->insert( { single_transaction => $single_trans,
                               account => $account } );
  my $account_balance = $account->set( balance => $new_balance );

  return;
}

package ATM::Customer;
use base 'ATM';

__PACKAGE__->table( 'customer' );
__PACKAGE__->columns( Primary => qw(account person password) );
__PACKAGE__->has_a( person => 'ATM::Person' );
__PACKAGE__->has_a( account => 'ATM::Account' );

sub encryptPass {
  my ($pass) = shift;
  my @chars = ('.', '/', 'a'..'z', 'A'..'Z', '0'..'9');
  my $salt;
  $salt .= $chars[rand(63)] for( 0..1 );
  return crypt($pass, $salt);
}

sub getEncPass {
  my ($pass, $salt) = @_;
  return crypt($pass, $salt);
}

package ATM::Person;
use base 'ATM';

__PACKAGE__->table( 'person' );
__PACKAGE__->columns( All => qw(id first_name last_name) );
__PACKAGE__->has_many( accounts => [ 'ATM::Customer' => 'account' ] );

package ATM::Transactions;
use base 'ATM';

__PACKAGE__->table( 'transactions' );
__PACKAGE__->columns( Primary => qw(account single_transaction) );
__PACKAGE__->has_a( single_transaction => 'ATM::Transaction::Single' );
__PACKAGE__->has_a( account => 'ATM::Account' );

package ATM::Transaction::Single;
use base 'ATM';

__PACKAGE__->table( 'single_transaction' );
__PACKAGE__->columns( All => qw(id amount transaction_type previous_balance new_balance transaction_date) );
__PACKAGE__->has_a( transaction_type => 'ATM::Transaction::Type' );
__PACKAGE__->has_many( accounts => [ 'ATM::Transactions' => 'account' ] );

sub type
{
  return shift->get( 'transaction_type' )->name;
}

package ATM::Transaction::Type;
use base 'ATM';

__PACKAGE__->table( 'transaction_type' );
__PACKAGE__->columns( All => qw(id name) );


package ATM_Template;
use base 'HTML::Template';
use CGI qw(header);

sub new
{
  return shift->SUPER::new( filename          => "atm.tmpl",
                            die_on_bad_params => 0 );
}

sub html_output
{
  return header() . (shift->SUPER::output);
}

1;
