#!/usr/bin/perl
use strict;
use warnings;

use FindBin;
use Getopt::Long;

use Carp;

use Config::General;

use Data::Dumper::Simple;

use feature qw( switch );

use File::Path qw(make_path remove_tree);
use File::Spec;

use lib '/projects/mob_tools/lib/perl';
use CORP::LDAP;

use Log::Log4perl qw( get_logger :levels );

use Readonly;

use Sys::Hostname;
use System::Command;

use Time::Piece;
use Time::Seconds;

use utf8;

use XML::LibXML;

# WARN: relative position of 'use Clearquest' has error consequences.
#       The interaction with other use statements has not been debugged;
#       placing this last seems to be 'safe'
#
use lib "/projects/mobcom_andrwks/users/dsass/clone/Clearquest/v218lib";
use Clearquest;

local $| = 1;
my( $script ) = $FindBin::Script =~ /(.*)\.pl$/x;

Readonly::Scalar my $configFilePath  => "$FindBin::Bin/../config/$script.xml";

# GLOBAL VARS
#   input arguments
my( $cqProject, $stream, $cid, $fileName, $testMode, $logLevel, $help );
#   global vars
my( $g_logDirectory_test, $g_logDirectory_production, $g_restMessageRegex,
    $g_modificationAgeThreshold, $g_projectLeadsFile, $g_xEmailLoginFile, $g_pwConfigFile,
    $g_defaultManager, $g_p4Admin, $g_p4AdminRegex, $g_adminEmailRegex, $g_scmPw, $g_ldapPw,
    $g_ownerLoginRegex, $g_blameRegex, $g_mpsRegex, $g_dateTimeRegex,
    $g_javaReplyRegex, $g_corpRegex
  );
#   constants
my( $FALSE, $TRUE, $LINELENGTH, $COMMA, $SLASH, $DASH, $SPACE, $EQUAL, $CR, $LF,
    $REST_OK, $REST_NOT_FOUND, $MAX_ERRORS, $MAX_RETRIES, $ERRREF_TIMEOUT,
    $DIRWAIT_TIMEOUT, $MAX_DIRWAIT_COUNT, $CQDATABASE
  );

# read the script's config file
#   assign paths and other initialization variables
#
setGlobalParameters( getConfig( $configFilePath ) );

# read the password file; extract the pw for swcm_user
#
my $pwHRef   = getPwValues( $g_pwConfigFile );

   $g_scmPw  = $pwHRef->{ 'scm-password' };
   $g_scmPw  =~ s{^'}{}x;
   $g_scmPw  =~ s{'$}{}x;

   $g_ldapPw = $pwHRef->{ 'LDAP-passwd'  };
   $g_ldapPw =~ s{^'}{}x;
   $g_ldapPw =~ s{'$}{}x;

getInputParameters();

my $loggerMain_logLevel = getLoggerLevel( $logLevel );
createLogDirectory( $testMode );
Log::Log4perl::init( loggerInit( $testMode ? $g_logDirectory_test : $g_logDirectory_production ) );

my $loggerMain = get_logger( $script );
   $loggerMain->level( $loggerMain_logLevel );
   $loggerMain->info( '$Sys::Hostname::hostname = ', hostname );
   $loggerMain->info( '$Clearquest::VERSION     = ', $Clearquest::VERSION );

$CQDATABASE         = q{t_sbx} unless $CQDATABASE;
my $g_cqObject      = getCQObject( $CQDATABASE );

# get SW lead from project config file
#
my $projectDataHRef = getProjectData( );

my $xEmailLoginHRef = getExceptionalEmailLogin( $g_xEmailLoginFile );

my( $blameEmail, $dateModified ) = getBlameEmail();

my( $assigneeFullName, $cqHybridName, $assigneeEmail, $assigneeLoginName );

# author in corp domain?
#
if( $blameEmail =~ $g_corpRegex )
{
  # line modified more than <threshold> days ago?
  #
  my $now = localtime;
  my $aDateInThePast  = $now;
     $aDateInThePast -= ONE_DAY * $g_modificationAgeThreshold;

  $loggerMain->info( '$now               = ', $now );
  $loggerMain->info( '$aDateInThePast = ', $aDateInThePast );

  if( $dateModified < $aDateInThePast )
  {
    $loggerMain->info( '$dateModified  = ', $dateModified );
    ( $assigneeEmail, $assigneeFullName, $assigneeLoginName ) =  getSWLead( $cqProject, "Modified: $dateModified" );
    $cqHybridName = $assigneeFullName . ' - ' . $assigneeLoginName;
  }
  else
  {
    $loggerMain->info( $DASH x $LINELENGTH );
    $loggerMain->info( '$blameEmail = ', $blameEmail );

    my( $loginName ) = $blameEmail =~ $g_ownerLoginRegex;
    $loggerMain->info( '$loginName  = ', $loginName );

    # check/replace exceptional name
    #
    $loginName   = $xEmailLoginHRef->{ lc $loginName } if( exists $xEmailLoginHRef->{ lc $loginName } );
    $loggerMain->info( '$loginName  = ', $loginName );

    my( $assigneeHRef ) = validateAssignee( $cqProject, $loginName );

    $assigneeFullName  = $assigneeHRef->{ fullname  };
    $assigneeLoginName = $assigneeHRef->{ loginname };
    $assigneeEmail     = $assigneeHRef->{ email     };
    $cqHybridName      = $assigneeFullName . ' - ' . $assigneeLoginName;

  }

  $loggerMain->info( '$assigneeFullName  = ', $assigneeFullName );
  $loggerMain->info( '$cqHybridName      = ', $cqHybridName );
  $loggerMain->info( '$assigneeEmail     = ', $assigneeEmail );
  $loggerMain->info( '$assigneeLoginName = ', $assigneeLoginName );
  $loggerMain->info( $DASH x $LINELENGTH );

  print $assigneeLoginName . "\n";
}
else
{
  $loggerMain->info( 'Author not in corp domain: $blameEmail = ', $blameEmail );
  print ' ' . "\n";
}


END
{
  $g_cqObject->disconnect if $g_cqObject; # disconnect instantiated Clearquest object
}

exit 0;

################################################################################

# Coverity provides line numbers for a file that are associated with a Coverity ID.
# getBlameEmail uses the file and line numbers to extract defect information:
#    time of the line modification
#    email address of the modifier
#
# Modification timestamps are compared and the email address associated with the
# most recent modification is returned
#
sub getBlameEmail
{
  # $cid is an input argument (global)
  #
  # my @lineNumbers = qx{java -jar /projects/mobcom_andrwks_ext29/users/albertc/CovJavaAppsV6/GetLineNos.jar --host scm-coverity --port 8080 --user swcm_user --password mcsi02test --stream AP-sdb-common-android-jb-4.2.2-android_hawaii_edn010 --cid $cid};

  my $hRef = getLineNumbersCmd(
                                {
                                  cid    => $cid,
                                  stream => $stream,
                                }
                               );

  my @lineNumbers;

  if( $hRef->{ status } )
  {
    @lineNumbers = $hRef->{ data }
  }
  else
  {
    croak '__CROAK__ Fatal status from getLineNumbersCmd(): ', $!;
  }

  my @results;

  while( my $line = <@lineNumbers> )
  {
    chomp $line;

    # The Blame line to parse:
    # 2013/02/11 11:12:48 160 INFO $stdOutRef $_ = fecb48fe (<dsass@corp.com> 2013-01-15 09:39:07 -0800    3) # This script reproduces the functionality of the AndroidAutoBuild_SyncFromCentralRepo.sh
    #
    my $blameResultHRef = gitBlameCmd(
                                      {
                                        filepath => $fileName,
                                        line     => $line,
                                        regex    => $g_blameRegex,
                                        logger   => $loggerMain,
                                      }
                                     );

    if( $blameResultHRef->{status} )
    {
      push @results, $blameResultHRef->{data};
    }
    else
    {
      # dummy-up a git blame response line
      #    that will insure an assignment to the project lead
      #
      my $dummy = '^bc611bf (<pga@corp.com> 2011-03-04 18:04:43 -0800 200)';
      push @results, $dummy;
      $loggerMain->error( 'Error from gitBlameCmd(). Using default assignment' );
    }

  } # for line numbers

  $loggerMain->debug( Dumper( @results ) );

  my %defectRecord;

  for( my $i=0; $i<scalar @results; $i++ )
  {
    my( $sha1Key, $email, $date, $time, $utc, $line ) = $results[$i] =~ $g_blameRegex;
    my $timestamp = $date . ' ' . $time;
    my $t = Time::Piece->strptime( $timestamp, "%Y-%m-%d %H:%M:%S" );
    $defectRecord{ $sha1Key } = {
                                  time => $t,
                                  email => $email,
                                };
  }

  # create an arbitrary baseline timestamp
  #
  my $timeModified = Time::Piece->strptime( '2000-02-29T12:34:56', "%Y-%m-%dT%H:%M:%S" );
  my $email;

  # find the latest timestamp
  #
  for my $key( keys %defectRecord )
  {
    if( $defectRecord{ $key }{ time } > $timeModified  )
    {
      $timeModified =  $defectRecord{ $key }{ time  };
      $email        =  $defectRecord{ $key }{ email };
    }
  }
  return $email, $timeModified;
}

sub getLoggerLevel
{
  my $level = shift;
  my $loggerLevel;

  given( $level )
  {
    when ( 'DEBUG' ) { $loggerLevel = $DEBUG }
    when ( 'INFO'  ) { $loggerLevel = $INFO  }
    when ( 'WARN'  ) { $loggerLevel = $WARN  }
    when ( 'ERROR' ) { $loggerLevel = $ERROR }
    when ( 'FATAL' ) { $loggerLevel = $FATAL }
    default          { $loggerLevel = $WARN  }
  }
  return $loggerLevel;
}

# my @lineNumbers = qx{java -jar /projects/mobcom_andrwks_ext29/users/albertc/CovJavaAppsV6/GetLineNos.jar --host scm-coverity --port 8080 --user swcm_user --password mcsi02test --stream AP-sdb-common-android-jb-4.2.2-android_hawaii_edn010 --cid $cid};

sub getLineNumbersCmd
{
  my $pHashRef  = shift;
  my $covId     = $pHashRef->{ cid    };
  my $covStream = $pHashRef->{ stream };

  local $|      = 1;

  my $jarPath = '/projects/GetLineNos.jar';
  my $host    = 'scm-coverity';
  my $port    = '8080';
  my $user    = 'swcm_user';

  my $cmdString  = "java -jar $jarPath --host $host --port $port --user $user --password $g_scmPw --stream $covStream --cid $covId";

  my $success    = $FALSE;
  my $status     = $FALSE;
  my $retryCount = 0;

  my @array;

  RETRYLOOP: while( $success == $FALSE )
  {
    $loggerMain->debug( '$cmdString  = ', $cmdString  );
    $loggerMain->debug( '$retryCount = ', $retryCount );

    my $cmdObj = System::Command->new( $cmdString );

    # these are globs
    #
    my $stdOutRef = $cmdObj->stdout();
    my $stdErrRef = $cmdObj->stderr();

    # find out if the child process died
    #   the handles are not closed yet
    #     but $cmdObj->exit() et al. are available
    #
    if( $cmdObj->is_terminated() )
    {
      $loggerMain->fatal( 'is_terminated:  $cmdObj->cmdline() = ', $cmdObj->cmdline() );

      # display exit data if it exists
      #
      $loggerMain->fatal( '$cmdObj->exit()   = ', $cmdObj->exit()   ) if $cmdObj->exit();
      $loggerMain->fatal( '$cmdObj->signal() = ', $cmdObj->signal() ) if $cmdObj->signal();
      $loggerMain->fatal( '$cmdObj->core()   = ', $cmdObj->core()   ) if $cmdObj->core();

      $success = $TRUE;
      $status  = $FALSE;

      $cmdObj->close();

      last RETRYLOOP ; # there are no retries for a terminated child
    }
    else
    {
      # verify/display STDERR text
      #
      ERRREFLOOP: while( my $errorText = <$stdErrRef> )
      {
	chomp $errorText;
	$loggerMain->error( '$errorText = ', $errorText ) unless $errorText =~ $g_javaReplyRegex;
      } # ERRREFLOOP

      # display STDOUT text
      #
      STDOUTLOOP: while( my $stdouttext = <$stdOutRef> )
      {
	chomp $stdouttext;
        push @array, $stdouttext;
      }

      $success = $TRUE;
      $status  = $TRUE;

    } # cmd executed OK

    $cmdObj->close();

  } # RETRYLOOP

  return(
          {
            status => $status,
            data   => @array,
          }
        );

} # getLineNumbersCmd


sub gitBlameCmd
{
  my $pHashRef = shift;

  my $filePath   = $pHashRef->{ filepath };
  my $gitRegex   = $pHashRef->{ regex    };
  my $codeline   = $pHashRef->{ line     };

  my $logger     = $pHashRef->{ logger   };

  local $|      = 1;

  my $logGitBlameCmd = $FALSE;

  my( $vol, $dir, $file ) = File::Spec->splitpath( $filePath );

  $logger->debug( '$dir   = ', $dir  )  if $logGitBlameCmd;
  $logger->debug( '$file  = ', $file  ) if $logGitBlameCmd;

  croak "__CROAK__ Cannot chdir to $dir" unless chdir $dir;
  my @array;
  my $gitBlameStatus;
  my $retryCount      = 0;

  my $cmdString = "git blame --show-email -L $codeline,$codeline $file";

  my $gitBlameSuccess = $FALSE;

  RETRYLOOP: while( $gitBlameSuccess == $FALSE )
  {
    $logger->debug( '$cmdString  = ', $cmdString  ) if $logGitBlameCmd;
    $logger->debug( '$retryCount = ', $retryCount ) if $logGitBlameCmd;

    my $cmdObj = System::Command->new( $cmdString );

    # these are globs
    #
    my $stdOutRef = $cmdObj->stdout();
    my $stdErrRef = $cmdObj->stderr();

    # find out if the child process died
    #   the handles are not closed yet
    #     but $cmdObj->exit() et al. are available
    #
    if( $cmdObj->is_terminated() )
    {
      $logger->fatal( 'is_terminated:  $cmdObj->cmdline() = ', $cmdObj->cmdline() );

      # display exit data if it exists
      #
      $logger->fatal( '$cmdObj->exit()   = ', $cmdObj->exit()   ) if $cmdObj->exit();
      $logger->fatal( '$cmdObj->signal() = ', $cmdObj->signal() ) if $cmdObj->signal();
      $logger->fatal( '$cmdObj->core()   = ', $cmdObj->core()   ) if $cmdObj->core();

      $gitBlameSuccess = $TRUE;
      $gitBlameStatus  = $FALSE;

      $cmdObj->close();

      last RETRYLOOP ; # there are no retries for a terminated child
    }
    else
    {
      # verify/display STDERR text
      #
      ERRREFLOOP: while( my $errorText = <$stdErrRef> )
      {
	chomp $errorText;

	given( $errorText )
	{
          # fatal: file path/file.ext has only xxx lines
          #
          when ( m{file\s.+?\shas\sonly\s\d+\slines}x )
	  {
	    $logger->fatal( '$stdErrRef $_ = ', $_ );

            $gitBlameStatus  = $FALSE;
	    last RETRYLOOP ;
	  }

	  default
	  {
	    $logger->info( '$_ = ', $_ );

            push @array, $filePath;    # save the entire path
	    $gitBlameStatus  = $FALSE;

	    last RETRYLOOP ;
	  }

	} #given
      } # ERRREFLOOP

      while( my $stdoutdata = <$stdOutRef> )
      {
	chomp $stdoutdata;
	$logger->debug( '$stdoutdata = ', $stdoutdata ) if $logGitBlameCmd;
        push @array, $stdoutdata;
      }

      $gitBlameSuccess = $TRUE;
      $gitBlameStatus  = $TRUE;

    } # not is_terminated

    $cmdObj->close();

  } # RETRYLOOP

  croak "__CROAK__ Cannot chdir to home directory" unless chdir;

  return(
          {
            status => $gitBlameStatus,
            data   => @array,
          }
        );

} # gitBlameCmd

#
# loggerInit: Log::Log4perl Setup
#
# message filter levels
#
# FATAL < highest
# ERROR
# WARN
# INFO
# DEBUG < lowest
#
# Initialize Logger
# PatternLayout: http://jakarta.apache.org/log4j/docs/api/org/apache/log4j/PatternLayout.html
#
# %c Category of the logging event.
# %C Fully qualified package (or class) name of the caller
# %d Current date in yyyy/MM/dd hh:mm:ss format
# %d{...} Current date in customized format (see below)
# %F File where the logging event occurred
# %H Hostname (if Sys::Hostname is available)
# %l Fully qualified name of the calling method followed by the
#    callers source the file name and line number between
#    parentheses.
# %L Line number within the file where the log statement was issued
# %m The message to be logged
# %m{chomp} The message to be logged, stripped off a trailing newline
# %M Method or function where the logging request was issued
# %n Newline (OS-independent)
# %p Priority of the logging event (%p{1} shows the first letter)
# %P pid of the current process
# %r Number of milliseconds elapsed from program start to logging
#    event
# %R Number of milliseconds elapsed from last logging event to
#    current logging event
# %T A stack trace of functions called
# %x The topmost NDC (see below)
# %X{key} The entry 'key' of the MDC (see below)
# %% A literal percent (%) sign
#
sub loggerInit
{
  my $dir = shift;
  my $logFileName = $dir . '/' . formattedDateTime()->{ yyyymmddhhmmss } . '_' . $script . '.log';

  # create a log file configuration definition
  # $testMode writes to the screen as well as a file
  #
  my $log_conf;
  if( $testMode )
  {
    $log_conf = << "__EOT__";
log4perl.rootLogger                               = DEBUG, LOG1, SCREEN
log4perl.appender.SCREEN                          = Log::Log4perl::Appender::Screen
log4perl.appender.SCREEN.stderr                   = 0
log4perl.appender.SCREEN.layout                   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.SCREEN.layout.ConversionPattern = %d %M %L %p %m %n
log4perl.appender.LOG1                            = Log::Log4perl::Appender::File
log4perl.appender.LOG1.filename                   = ${logFileName}
log4perl.appender.LOG1.mode                       = write
log4perl.appender.LOG1.layout                     = Log::Log4perl::Layout::PatternLayout
log4perl.appender.LOG1.layout.ConversionPattern   = %d %M %L %p %m %n
__EOT__

}
else
{
  $log_conf = << "__EOT__";
log4perl.rootLogger                               = DEBUG, LOG1
log4perl.appender.LOG1                            = Log::Log4perl::Appender::File
log4perl.appender.LOG1.filename                   = ${logFileName}
log4perl.appender.LOG1.mode                       = write
log4perl.appender.LOG1.layout                     = Log::Log4perl::Layout::PatternLayout
log4perl.appender.LOG1.layout.ConversionPattern   = %d %M %L %p %m %n
__EOT__

}
  return \$log_conf;
}

sub createLogDirectory
{
  my $p_test = shift;
  if( $p_test )
  {
    make_path $g_logDirectory_test unless -e $g_logDirectory_test;
  }
  else
  {
    make_path $g_logDirectory_production unless -e $g_logDirectory_production;
  }
  return;
}

sub formattedDateTime
{
  my $t = shift || time;
  my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime( $t );
  $year += 1900;
  ++$mon;
  my $yyyymmdd        = sprintf( '%d%02d%02d', $year, $mon, $mday );
  my $yyyymmdd_hhmmss = sprintf( '%d%02d%02d_%02d%02d%02d', $year, $mon, $mday, $hour, $min, $sec );
  my $mm_dd_yyyy      = sprintf( '%02d/%02d/%d', $mon, $mday, $year );
  return(
         {
          yyyymmdd       => $yyyymmdd,
          yyyymmddhhmmss => $yyyymmdd_hhmmss,
          mmddyyyy       => $mm_dd_yyyy,
         }
        );
}

sub getCQObject
{
  my $database = shift;
  my $cq = Clearquest->new( CQ_DATABASE => $database, );
  $cq->connect()
    or croak '__CROAK__: Cannot connect to cq database: ', $CQDATABASE;
  return $cq;
}

#   if the Assignee, which is a user login name, is no longer an employee
#     the project's SW lead is the Assignee
#

sub validateAssignee
{
  my $project = shift;
  my $login   = shift || 'Admin';

  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  my $logger = get_logger( $subroutine );
  $logger->level( $loggerMain_logLevel );
  $logger->debug( '$login : ', $login);

  # 'LIKE' is NOT SUPPORTED BY REST...
  #    Andrew deFaria: "As for like, you'll probably need to do something like
  #    "<fieldname> like '%var%'" for the condition."
  #

  my %dBRecord = $g_cqObject->get( 'users', $login, qw( is_active email fullname login_name misc_info ) );
  my( $restStatus, $restMsg ) = checkRESTError();

  my( $validatedEmail, $validatedFullName, $validatedLoginName );

  unless( $restStatus == $REST_OK )
  {
    if( $restStatus == $REST_NOT_FOUND and $restMsg =~ $g_restMessageRegex )
    {
      $logger->info( 'Can not find $login = ', $login, ' $restStatus = ', $restStatus, ' Using SW lead.'  );
      ( $validatedEmail, $validatedFullName, $validatedLoginName ) =  getSWLead( $project, "Not in CQ: $login" );
    }
    else
    {
      $logger->error( '$restMsg = ', $restMsg ) if $restMsg;
      croak '__CROAK__: Unexpected CQ REST failure: $restStatus = ', $restStatus;
    }
  }
  else
  {
    # REST status is OK
    # user record could be in the dB, but not active
    #   or could be in the dB, active but not assigned to the MPS department
    #

    $logger->info( '$dBRecord{ is_active } = ', $dBRecord{ is_active } );
    $logger->info( '$dBRecord{ misc_info } = ', $dBRecord{ misc_info }  );

    if( $dBRecord{ is_active } )
    {
      $logger->info( $login, ' is active' );

      if( $dBRecord{ misc_info } =~ $g_mpsRegex )
      {
        $logger->info( $login, ' is active and in MPS' );

        # the P4 branch admin is associated with all P4 branch creations...
        #   so assign the defect to Project lead
        #
        if( $login =~ $g_p4AdminRegex )
        {
          $logger->info( $login, ' is p4 admin. Using SW Lead.' );
          ( $validatedEmail, $validatedFullName, $validatedLoginName ) =  getSWLead( $project, "P4 admin: $login" );
        }
        # else login is valid, so get details
        else
        {
          $validatedEmail       = $dBRecord{ email      };
          $validatedFullName    = $dBRecord{ fullname   };
          $validatedLoginName   = $dBRecord{ login_name };
        }
      } # in MPS
      else
      {
        $logger->info( $login, ' is active but not in MPS. Using Manager.' );
        $logger->info( '$dBRecord{ is_active } = ', $dBRecord{ is_active } );
        $logger->info( '$dBRecord{ misc_info } = ', $dBRecord{ misc_info } );

        my $managerLogin =  getManager( $dBRecord{ email } );

        # $managerLogin will be undef in case of an LDAP timeout
        #
        if( $managerLogin )
        {
          my( $assignedHRef ) = validateAssignee( $cqProject, $managerLogin );

          $validatedFullName  = $assignedHRef->{ fullname  };
          $validatedLoginName = $assignedHRef->{ loginname };
          $validatedEmail     = $assignedHRef->{ email     };
        }
        else
        {
          #2.) When communicating with the LDAP server there are occasional
          #    timeouts. As a workaround for this failure the script returns
          #    the ‘defaultManager’ listed in the gitBlameAssignment.xml
          #    configuration script.
          #
          #ERROR EXAMPLE:
          #2013/04/12 15:24:40 main::getManager 811 ERROR Bind to LDAP
          #database failed! $error = IO::Socket::INET: connect: timeout
          #
          #returns->   'manager login' # from gitBlameAssignment.xml
          # AC:
          # For the 2nd situation, I prefer an inconclusive return. So,
          # triageBlame.jar ignores this defect for the time being. The
          # coverity defect stays as new in status. The triageBlame.jar runs
          # on it again next day in the new coverity build and scan cycle.
          #
          return(
                  {
                    email         => '',
                    fullname      => '',
                    loginname     => '',
                  }
                );
        }
      }
    } # is_active
    else
    {
      $logger->info( $login, ' is not an active corp employee. Using SW Lead.' );
      $logger->info( '$dBRecord{ is_active } = ', $dBRecord{ is_active } );
      $logger->info( '$dBRecord{ misc_info } = ', $dBRecord{ misc_info } );

      ( $validatedEmail, $validatedFullName, $validatedLoginName ) =  getSWLead( $project, "Not an active employee: $login" );
    }

  } # REST OK

  $logger->debug( '$validatedEmail     = ', $validatedEmail );
  $logger->debug( '$validatedFullName  = ', $validatedFullName );
  $logger->debug( '$validatedLoginName = ', $validatedLoginName );

  return(
          {
            email         => $validatedEmail,
            fullname      => $validatedFullName,
            loginname     => $validatedLoginName,
          }
        );

} # validateAssignee

sub getManager
{
  my $userEmail = shift; # must be full email: user@domain

  my( $subroutine ) = (caller(0))[3];
  local $|   = 1;
  my $logger = get_logger( $subroutine );
  $logger->level( $loggerMain_logLevel );

  # get manager name from LDAP server record for employee

  my %options = ( 'LDAP-passwd' => $g_ldapPw );

  my( $ldap, $error ) = CORP::LDAP->new( %options );
  if( $error )
  {
    $logger->error( 'Bind to LDAP database failed! $error = ', $error );
    return;
  }

  my $get_user_bymail_Start = Time::HiRes::time();
  my $userARef;
  ( $userARef, $error ) = $ldap->get_user_bymail( $userEmail );
  if( $error)
  {
    croak '_CROAK_ LDAP Search error = ', $error;
  }
  my $get_user_bymail_End      = Time::HiRes::time();
  my $get_user_bymail_Duration = $get_user_bymail_End - $get_user_bymail_Start;

  $logger->debug( '$get_user_bymail_Duration = ', $get_user_bymail_Duration );
  my $manager = $userARef->[0]{ manager }; # login name
  $logger->debug( '$manager = ', $manager );
  return $manager;
}

sub getSWLead
{
  my $project = shift;
  my $reason  = shift;

  my( $subroutine ) = (caller(0))[3];
  local $|   = 1;
  my $logger = get_logger( $subroutine );
  $logger->level( $loggerMain_logLevel );

  my( $validatedEmail, $validatedFullName, $validatedLoginName );

  # if   the project is defined use the config file data
  # else default to AdminAutoSubmit
  #
  if( exists $projectDataHRef->{ $project } )
  {
    $logger->info( 'Using SW lead for ', $project, ' Reason = ', $reason );

    $validatedLoginName = $projectDataHRef->{ $project }{ swLeadLogon };
    $validatedEmail     = $projectDataHRef->{ $project }{ swLeadEmail };
    $validatedFullName  = $projectDataHRef->{ $project }{ swLead      };
  }
  else
  {
    $logger->info( 'Using CQ AdminAutoSubmit email. ', $project, ' not in $g_projectLeadsFile = ', $g_projectLeadsFile );

    my %adminRecord    = $g_cqObject->get( 'users', 'AdminAutoSubmit', qw( login_name email fullname ) );
    my $adminEmail     = $adminRecord{ email };
    my $adminFullName  = $adminRecord{ fullname };

    $logger->debug( '$adminEmail    = ', $adminEmail );
    $logger->debug( '$adminFullName = ', $adminFullName );

    my %userRecord      = $g_cqObject->get( 'users', $adminEmail, qw( login_name email fullname ) );
    $validatedEmail     = $userRecord{ email };
    $validatedFullName  = $userRecord{ fullname };
    $validatedLoginName = $userRecord{ login_name };

    $logger->debug( '$validatedEmail     = ', $validatedEmail );
    $logger->debug( '$validatedFullName  = ', $validatedFullName );
    $logger->debug( '$validatedLoginName = ', $validatedLoginName );
  }

  return $validatedEmail, $validatedFullName, $validatedLoginName;
}

# Coverity uses names that are non-conformant wrt the CQ user table login field.
#
# Exceptional email names include '.' and ' ' within the user field of
# the user@domain string, but also maps a name into something different -
# exceptional characters or not.
#
# getExceptionalEmailLogin reads an xml configuration file that maps a known
# exceptional user name to a login name in the CQ users table
#
sub getExceptionalEmailLogin
{
  my $file = shift;

  my $parser = XML::LibXML->new();
  my $doc = $parser->parse_file( $file );

  my %hash;
  for my $keywordNode( $doc->findnodes( '/map/keyword' ) )
  {
    my $emailName = $keywordNode->getAttribute( 'emailname' );
    $hash{ $emailName } = $keywordNode->getAttribute( 'login' );
  }
  return \%hash;
}


# retrieve Project data: SW lead name & SW lead email name
#                        from xml configuration file.
#
sub getProjectData
{
  my $parser = XML::LibXML->new();
  my $doc = $parser->parse_file( $g_projectLeadsFile );

  my %hash;
  for my $projectNode( $doc->findnodes( '/projects/project' ) )
  {
    my $projectName = $projectNode->getAttribute( 'name' );

    $hash{ $projectName }{ swLead }      = $projectNode->getAttribute( 'swLead' );
    $hash{ $projectName }{ swLeadEmail } = $projectNode->getAttribute( 'swLeadEmail' );
    $hash{ $projectName }{ swLeadLogon } = $projectNode->getAttribute( 'swLeadLogon' );
  }
  return \%hash;
}

sub getInputParameters
{
  my $tmp = @_;

  my $USAGE = << "_EOT_";
"Usage: $script
-project 'CQ project'
-cid 'Coverity id'
-filename 'file path'
-linenumber 'line number'
[-test]
[-loglevel [DEBUG|INFO|WARN|ERROR|FATAL]]
[-h|?|help]"
_EOT_

  $USAGE = join $SPACE, split m{\n}x, $USAGE;
  $USAGE .= "\n";

  croak $USAGE unless GetOptions(
                                  "project=s"     => \$cqProject,
                                  "stream=s"      => \$stream,
                                  "cid=s"         => \$cid,
                                  "filename=s"    => \$fileName,
                                  "test"          => \$testMode,
                                  "loglevel=s"    => \$logLevel,
                                  "h|?|help"      => \$help,
                                );

  print $USAGE and exit if $help;
  croak "__CROAK__: project argument required\n$USAGE"        unless $cqProject;
  croak "__CROAK__: file name argument required\n$USAGE"      unless $fileName;
  croak "__CROAK__: Coverity id argument required\n$USAGE"    unless $cid;

  return;
}

sub setGlobalParameters
{
  my $hRef = shift;

  # CONSTANTS
  #
  Readonly::Scalar $FALSE                       => 0;
  Readonly::Scalar $TRUE                        => 1;

  Readonly::Scalar $LINELENGTH                  => 80;

  Readonly::Scalar $COMMA                       => q{,};
  Readonly::Scalar $CR                          => chr(13);
  Readonly::Scalar $DASH                        => q{-};
  Readonly::Scalar $EQUAL                       => q{=};
  Readonly::Scalar $LF                          => chr(10);
  Readonly::Scalar $SLASH                       => q{/};
  Readonly::Scalar $SPACE                       => chr(32);

  Readonly::Scalar $CQDATABASE                  => q{MobC};
  Readonly::Scalar $REST_OK                     => 0;
  Readonly::Scalar $REST_NOT_FOUND              => 404;

  Readonly::Scalar $MAX_ERRORS                  => 5;
  Readonly::Scalar $MAX_RETRIES                 => 5;
  Readonly::Scalar $ERRREF_TIMEOUT              => 5; # seconds
  Readonly::Scalar $DIRWAIT_TIMEOUT             => 5; # seconds
  Readonly::Scalar $MAX_DIRWAIT_COUNT           => 12;

  Readonly::Scalar $g_modificationAgeThreshold  => $hRef->{ acceptableAgeOfModification }; # days
  Readonly::Scalar $g_defaultManager            => $hRef->{ defaultManager              };

  Readonly::Scalar $g_logDirectory_production   => $hRef->{ productionlogs    };
  Readonly::Scalar $g_logDirectory_test         => $hRef->{ testlogs          };

  Readonly::Scalar $g_projectLeadsFile          => $hRef->{ projectleads      };
  Readonly::Scalar $g_xEmailLoginFile           => $hRef->{ exceptionalLogins };

  Readonly::Scalar $g_p4Admin                   => $hRef->{ p4admin           };

  Readonly::Scalar $g_pwConfigFile              => $hRef->{ pwconfig          };



  # REGULAR EXPRESSIONS
  #
  Readonly::Scalar $g_restMessageRegex          => qr{Resource\snot\sfound}x;
  Readonly::Scalar $g_p4AdminRegex              => qr{$g_p4Admin|swcm_user}ix;
  Readonly::Scalar $g_adminEmailRegex           => qr{^(.+?)@}x;
  Readonly::Scalar $g_ownerLoginRegex           => qr{^(.+?)@}x;
  Readonly::Scalar $g_mpsRegex                  => qr{MPS|Data\sModule|EMBEDDED}x;

  Readonly::Scalar $g_corpRegex             => qr{corp}ix;

  Readonly::Scalar $g_javaReplyRegex            => qr{Picked\sup\s_JAVA_OPTIONS:}x;


  # lexical regexes used to build $g_blameRegex
  #
  Readonly::Scalar my $gitSha1     => qr{(\S+).+?}x;              # $1
  Readonly::Scalar my $emailAddr   => qr{\(<(.+?)>\s}x;           # $2
  Readonly::Scalar my $yyyymmdd    => qr{(\d{4}-\d{2}-\d{2})\s}x; # $3
  Readonly::Scalar my $hhmmss      => qr{(\d{2}:\d{2}:\d{2})\s}x; # $4
  Readonly::Scalar my $utcOffset   => qr{[+|-]\d{4}\s+}x;
  Readonly::Scalar my $line        => qr{(\d+)\)}x;               # $5

  Readonly::Scalar $g_dateTimeRegex => qr{$yyyymmdd $hhmmss}ix;

  Readonly::Scalar $g_blameRegex   => qr{^$gitSha1            # git sha1
                                         $emailAddr           # email
                                         $yyyymmdd            # yyyy-mm-dd
                                         $hhmmss              # hh:mm:ss
                                         $utcOffset           # UTC offset
                                         $line}ix;            # line number

  return;
}

sub checkRESTError
{
  my $errNum = $g_cqObject->error();
  my $errMsg;
  $errMsg = $g_cqObject->errmsg() unless( $errNum == $REST_OK );
  return $errNum, $errMsg;
}

sub getConfig
{
  my $xmlFilePath = shift;
  local $| = 1;
  my $doc;
  my $parser = XML::LibXML->new();

  # the eval logic courtesy of:
  #   Perl::Critic::Policy::ErrorHandling::RequireCheckingReturnValueOfEval
  #
  if( eval{ $doc = $parser->parse_file( $xmlFilePath ); 1 } )
  {
    if( ref( $@ ) )
    {
      reportXMLError();
      croak '__CROAK__: NOT an XML::LibXML::Error object $@->dump() = ', $@->dump();
    }
    elsif( $@ )
    {
      # error, but not an XML::LibXML::Error object
      #
      croak '__CROAK__: NOT an XML::LibXML::Error object $@ = ', $@;
    }
  }

  my %config;
  for my $node( $doc->findnodes( '/config/*' ) )
  {
    my $name  = $node->getAttribute( 'name' );
    my $value = $node->getAttribute( 'value' );
    $config{ $name } = $value;
  }
  return \%config;
}

sub getPwValues
{
  my $file = shift;
  my $conf = Config::General->new( $file );
  my %hash = $conf->getall;
  return \%hash;
}


__END__
