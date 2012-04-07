#!/Perl64/bin/perl
use strict;
use warnings;

use CGI qw(param -nosticky);
use CGI::Carp qw(fatalsToBrowser);
use ATM;
use Data::Dumper::Simple;

BEGIN
{
 use CGI::Carp qw(carpout);
 open(my $LOG, '>', "$0.log") or die __LINE__, ": Unable to open $0.log: $!\n";
 carpout($LOG);
}

# parameters from form
my $origin_form = CGI::param( 'form_name' );

warn __LINE__, ": Before if tests ... ", Dumper($origin_form);

# keep $template global
#   output $template at end of if logic
my $template;

if( !defined $origin_form or
             $origin_form =~ /\Alogout\z/i ) # called by browser or logout from any form
{

  warn __LINE__, ": Logout if test ... ", Dumper($origin_form);
  warn __LINE__, ": ", "\$origin_form = $origin_form\n" if defined $origin_form;

  $template = ATM_Template->new;
  $template -> param( login => 1 );

}
elsif( $origin_form eq 'customer_login' or
       $origin_form eq 'account_statement')
{
  my $account_number = CGI::param( 'account_number' );
  my $cleartext_pass = CGI::param( 'cleartext_pass' );

  warn __LINE__, ": ", Dumper($account_number);
  warn __LINE__, ": ", Dumper($cleartext_pass);

  $template = ATM_Template->new;
  atm_menu( $template );
}
elsif( $origin_form eq 'admin_login' )
{
  my $account_number = CGI::param( 'account_number' );
  my $cleartext_pass = CGI::param( 'cleartext_pass' );
  my $USER   = 'root';
  my $SERVER = 'localhost';
  my $DB     = 'ATM';
  my $dbh     = DBI->connect( "dbi:mysql:database=$DB;host=$SERVER",
                               $USER,
                               $cleartext_pass
                            );
  $template = ATM_Template->new;
  if( $dbh ) # if handle the password is valid
  {
    # display new account user input form
    $template->param( new_account => 1 );
  }
  else # bad password - refresh screen
  {
    $template->param( login => 1 );
  }
}
elsif( $origin_form eq 'new_account' )
{
  $template = ATM_Template->new;
  $template -> param( create => 1 );
  create( $template );
}
elsif( $origin_form eq 'menu' )
{
  $template = ATM_Template->new;
  atm_choose( $template );
}
else
{
  die  __LINE__, ": ", "\$origin_form not defined: $origin_form";
}
print $template->html_output;
exit;

sub atm_menu
{
 my $template = shift;

 my $account_number = CGI::param( 'account_number' );
 my $cleartext_pass = CGI::param( 'cleartext_pass' );
 my $origin_form    = CGI::param( 'form_name' );

 warn __LINE__, ": ", Dumper($account_number);
 warn __LINE__, ": ", Dumper($cleartext_pass);
 warn __LINE__, ": ", Dumper($origin_form);

 my $encrypted_pass = CGI::param( 'encrypted_pass' );

 warn($account_number) if $account_number;
 warn($cleartext_pass) if $cleartext_pass;
 warn($encrypted_pass) if $encrypted_pass;

 my ($account)  = ATM::Account->search( account_number => $account_number );
 warn Dumper($account);

 my $account_id = $account->{id};
 my ($customer) = ATM::Customer->search( account => $account_id );
 warn Dumper($customer);

 my $customer_iterator = ATM::Customer->search( account => $account_id );
 warn Dumper($customer_iterator);

 my $persons_on_account = $customer_iterator->count;
 warn Dumper($persons_on_account);

 my $pw_verified = 0;

 if( $cleartext_pass )
 {
   CHECK_PW:
   for ( my $i = 1; $i <= $persons_on_account; $i++ )
   {
     my $person = $customer_iterator->next;
     warn Dumper($person);
     my $person_password = $person->password;
     warn Dumper($person_password);
     $person_password =~ /\A(\w{2})/;       # extract encrypted password salt
     my $salt = $1;
     # create an encrypted string
     my $enc_pass = ATM::Customer::getEncPass( $cleartext_pass, $salt );
     if( $enc_pass eq $person_password )
     {
       $pw_verified = 1;
       $encrypted_pass = $enc_pass;
       last;
     }
   }
 }
 elsif( $encrypted_pass )
 {
   $pw_verified = 1;
 }
 else
 {
  return $template->param( login => 1 );
 }

 if( !$pw_verified ) # bad password - refresh screen
 {
   return $template->param( login  => 1 );
 }

 # account/password OK
 # $account->owners is defined in ATM::Account with a has_many relationship
 #   ATM::Account::has_many( owners->[ ATM::Customer=>person] )
 #   example: account 10001, id=1, has person(id) 1 and 2
 #            account 10002, id=2, has person(id) 3
 #
 $template->param( menu => 1 );
 # display account summary
 $template->param( owners => join ', ', map { $_->first_name . " " . $_->last_name } $account->owners );
 $template->param( account_number   => $account_number,
                   balance          => $account->get( 'balance' ) );

 # pass the encrypted password
 $template->param( encrypted_pass => $encrypted_pass );

 # list options available
 $template->param( action       => 'action' );
 $template->param( credit       => 'Credit' );
 $template->param( debit        => 'Debit' );
 $template->param( transfer     => 'Transfer' );

 # list accounts this account can transfer into
 my @acct_nums  = grep{ $_ ne $account_number } map{ $_->get( 'account_number' ) } ATM::Account->retrieve_all;
 $template->param( xfr_account_loop => [ map { { to_account => $_ } } @acct_nums ] );

 return $template->param( statement => 'Statement' );
 #print $template->html_output;
}

sub atm_choose
{
 my $template         = shift;

 my $admin            = CGI::param( 'admin' );
 my $account_number   = CGI::param( 'account_number' );
 my $encrypted_pass   = CGI::param( 'encrypted_pass' );
 my $action           = CGI::param( 'action' );
 my $amount           = CGI::param( 'amount' );
 my $to_account       = CGI::param( 'to_account' );

 $template->param( choose => 1 );
 $template->param( account_number => $account_number );
 $template->param( encrypted_pass => $encrypted_pass );

 my ($account) = ATM::Account->search( account_number => $account_number );

 $template->param( owners => join ', ', map { $_->first_name . " " . $_->last_name } $account->owners );
 $template->param( account_number => $account_number, balance => $account->get( 'balance' ) );

 if( $action =~ /statement\z/i )
 {
   $template->param( if_statement => 1 );
   my @ATTRS = qw(transaction_date type amount previous_balance new_balance);
   my @transactions = map { my $t = $_; +{ map { $_, $t->$_ } @ATTRS } } $account->transactions;
   if( @transactions )
   {
    $template->param( transactions_exist => 1 );
    $template->param( transaction_loop => \@transactions );
   }
   else
   {
    $template->param( transactions_exist => 0 );
    $template->param( no_history => 'No account history.' );
   }
 }
 elsif( $action =~ /credit|debit\z/i )
 {
   my ($account) = ATM::Account->search( account_number => $account_number );
   warn Dumper($account);

   $account->add_transaction( $action, $amount ) if $amount > 0;
   $template->param( if_transaction => 1 );
   $template->param( owners => join ', ', map { $_->first_name . " " . $_->last_name } $account->owners );
   $template->param( account_number => $account_number, balance => $account->get( 'balance' ) );
   $template->param( account_number => $account_number,
                     amount         => $amount,
                     type           => $action );
 }
 elsif( $action =~ /\Atransfer/i )
 {
   # account-to-account transfer
   #  input parameters:
   #  a. from account
   #  b. to account
   #  c. amount
   # perform transactions
   #  d. debit from account
   #  e. credit to account
   my $type = 'debit';
   my ($from_account) = ATM::Account->search( account_number => $account_number );
   $from_account->add_transaction( $type, $amount );

   $type = 'credit';
   my ($to_account) = ATM::Account->search( account_number => $to_account );
   $to_account->add_transaction( $type, $amount );
   my $to_account_number = $to_account->account_number;

   $template->param( if_transfer  => 1 );
   $template->param( owners => join ', ', map { $_->first_name . " " . $_->last_name } $account->owners );
   $template->param( account_number => $account_number, balance => $account->get( 'balance' ) );
   $template->param( amount       => $amount,
                     to_account   => $to_account_number,
                     from_account => $account_number );

 }
 else
 {
  die  __LINE__, ": ", 'sub atm_choose:  \$action undefined';
 }
 return $template;
}

sub create
{
  my $template = shift;
  my %in_params;
  for my $p ( qw(first_name last_name initial_deposit password) )
  {
   if( $p =~ /pass/ )
   {
     $in_params{ $p } = ATM::Customer::encryptPass( param( $p ) );
   }
   else
   {
     $in_params{ $p } = param( $p )
   }
  }
  my ($new_account_id) = ATM::Account->add_account( %in_params );
  my $account_number = $new_account_id->account_number;
  my ($account) = ATM::Account->search( account_number => $account_number );
  $template->param( owners => join ', ', map { $_->first_name . " " . $_->last_name } $account->owners );
  $template->param( account_number => $account_number, balance => $account->get( 'balance' ) );
  return $template;
}
