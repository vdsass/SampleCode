#!/usr/bin/perl
use strict;
use warnings;

use lib q{/projects/mobile/users/dsass/lib};
use Blame;

use Carp;

use Data::Dumper::Simple;

use feature qw( switch );
#use File::Basename;
use File::Path qw(make_path remove_tree);
use FindBin;

use Getopt::Long;

use Log::Log4perl qw( get_logger :levels );

use P4;

use Readonly;

use Sys::Hostname;

use Time::Piece;

use utf8;

# WARN: relative position of 'use Clearquest' has error consequences.
#       The interaction with other use statements has not been debugged;
#       placing this last seems to be 'safe'
#
use lib "/projects/mobile/users/dsass/clone/Clearquest/v218lib";
use Clearquest;

local $| = 1;
my( $script ) = $FindBin::Script =~ /(^.+?)\.pl$/x;

my $debugTrace                  = 1;
my $debugTrace_Level_0          = 0;

Readonly::Scalar my $configFilePath  => "$FindBin::Bin/../config/$script.xml";

# GLOBAL VARS
#   input arguments
#
my( $cqProject, $g_p4Client, $g_p4File, $g_logLevel, $g_testMode, $g_help );

#   global vars
#
my( $g_logDirectory_test,
    $g_logDirectory_production,
    $g_xEmailLoginFile,
    $g_modificationAgeThreshold,
    $g_projectLeadsFile,
    $g_defaultManager,
    $g_p4Admin,
    $g_p4EnvPort,
    $g_p4EnvUser,
    $g_p4EnvPath,
    $g_p4Exe,
    $g_pwConfigFile,
    $g_broadcomRegex,
    $g_ignoreRegex,
    $g_changeRegex,
    $g_restMessageRegex,
    $g_p4AdminRegex,
    $g_adminEmailRegex,
    $g_ownerLoginRegex
  );

#   constants
#
my( $FALSE, $TRUE, $LINELENGTH, $COMMA, $SLASH, $DASH, $SPACE, $EQUAL, $CR, $LF,
    $MAX_ERRORS, $MAX_RETRIES, $ERRREF_TIMEOUT, $DIRWAIT_TIMEOUT, $MAX_DIRWAIT_COUNT,
    $CQDATABASE
  );

#   assign paths and other initialization variables
#
setGlobalParameters( Blame::getConfig( $configFilePath ) );
getInputParameters();
createLogDirectory( $g_testMode );
Log::Log4perl::init( loggerInit( $g_testMode ? $g_logDirectory_test : $g_logDirectory_production ) );

my $loggerMain_LogLevel = $g_logLevel;

my $loggerMain = get_logger( $script );
   $loggerMain->level( $loggerMain_LogLevel );

$CQDATABASE    = q{t_sbx} unless $CQDATABASE;
my $g_cqObject = Blame::getCQObject( $CQDATABASE );

# get SW leads from project config file
#
my $projectDataHRef = Blame::getProjectData( { projectleadsfile => $g_projectLeadsFile, } );

# get unique email names from config file
#
my $xEmailLoginHRef = Blame::getExceptionalEmailLogin( $g_xEmailLoginFile );

my( $g_p4Pass, $g_scmPass, $g_ldapPass ) = Blame::getPasswords( $g_pwConfigFile );

my $p4 = P4->new;

$loggerMain->debug( 'P4::Identify()  = ', P4::Identify() );
$loggerMain->debug( '$P4::OS         = ', $P4::OS );
$loggerMain->debug( '$P4::VERSION    = ', $P4::VERSION );
$loggerMain->debug( '$P4::PATCHLEVEL = ', $P4::PATCHLEVEL );

my( $p4Status, $p4Severity ) = Blame::p4Login(
                                        {
                                          p4obj    => $p4,
                                          p4port   => $g_p4EnvPort,
                                          p4user   => $g_p4EnvUser,
                                          p4pass   => $g_p4Pass,
                                          p4client => $g_p4Client,
                                        }
                                      );
croak '__CROAK__ p4Login failed. $p4Severity = ', $p4Severity unless $p4Status;

my $p4FileLogHRef = Blame::p4FileLogCmd(
                                        {
                                         filepath => $g_p4File,
                                        }
                                       );

my $p4FileLogStatus = $p4FileLogHRef->{ status };

my( $cid, $action, $date, $time, $user );

if( $p4FileLogStatus )
{
  my $p4DataARef = $p4FileLogHRef->{ data };

  $loggerMain->debug( Dumper( $p4DataARef ) );

  LINELOOP: for( my $i=0; $i<@{$p4DataARef}; $i++ )
  {
    my $line = $p4DataARef->[$i];
    next LINELOOP if $line =~ $g_ignoreRegex;

    undef $cid;
    undef $action;
    undef $date;
    undef $time;
    undef $user;

    ( $cid, $action, $date, $time, $user ) = $line =~ $g_changeRegex;

    next LINELOOP unless $action;

    $loggerMain->debug( );
    $loggerMain->debug( '$line   = ', $line );
    $loggerMain->debug( '$cid    = ', $cid );
    $loggerMain->debug( '$action = ', $action );
    $loggerMain->debug( '$date   = ', $date );
    $loggerMain->debug( '$time   = ', $time );
    $loggerMain->debug( '$user   = ', $user );
    $loggerMain->debug( );

    # action is the operation the file was open for:
    #   add, edit, delete, branch, import, or integrate

    given( $action )
    {
     when ( 'edit'      ) { last LINELOOP; }
     when ( 'integrate' ) { next LINELOOP; }
     when ( 'add'       ) { }
     when ( 'delete'    ) { }
     when ( 'branch'    ) { }
     when ( 'import'    ) { }
     default { croak '__CROAK__ $action  = ', $action; }
    }

  } # LINELOOP

}
else
{
  croak '__CROAK__ Problem with P4 logfile command';
}

$loggerMain->debug( 'For $cid = ', $cid, ' on ', $date, ' ', $time, ' initial blame $user = ', $user );

my $loginName    = $user;
my $dateTime     = $date . 'T' . $time;
my $dateModified = Time::Piece->strptime( $dateTime, "%Y/%m/%dT%H:%M:%S");

my( $assigneeFullName, $cqHybridName, $assigneeEmail, $assigneeLoginName );

# modified more than <threshold> days ago?
#
my $now            = localtime;
my $thresholdDate  = $now;
   $thresholdDate -= ONE_DAY * $g_modificationAgeThreshold;

$loggerMain->debug( '$now                        = ', $now );
$loggerMain->debug( '$g_modificationAgeThreshold = ', $g_modificationAgeThreshold );
$loggerMain->debug( '$thresholdDate              = ', $thresholdDate );
$loggerMain->debug( '$dateModified               = ', $dateModified );

if( $dateModified < $thresholdDate )
{
  ( $assigneeEmail, $assigneeFullName, $assigneeLoginName ) =  Blame::getSWLead(
                                                                                  {
                                                                                    cqobject    => $g_cqObject,
                                                                                    project     => $cqProject,
                                                                                    projectdata => $projectDataHRef,
                                                                                    reason      => "Modified: $dateModified",
                                                                                  }
                                                                                );
  $cqHybridName = $assigneeFullName . ' - ' . $assigneeLoginName;
}
else
{
  $loggerMain->debug( $DASH x $LINELENGTH );
  $loggerMain->debug( '$loginName  = ', $loginName );

  # check/replace exceptional name
  #
  $loginName   = $xEmailLoginHRef->{ lc $loginName } if( exists $xEmailLoginHRef->{ lc $loginName } );
  $loggerMain->debug( '$loginName  = ', $loginName );

  my( $assigneeHRef ) = Blame::validateAssignee(
                                                  {
                                                    cqobject    => $g_cqObject,
                                                    project     => $cqProject,
                                                    projectdata => $projectDataHRef,
                                                    login       => $loginName,
                                                    p4admin     => $g_p4Admin,
                                                  }
                                                );

  $assigneeFullName  = $assigneeHRef->{ fullname  };
  $assigneeLoginName = $assigneeHRef->{ loginname };
  $assigneeEmail     = $assigneeHRef->{ email     };
  $cqHybridName      = $assigneeFullName . ' - ' . $assigneeLoginName;
}

$loggerMain->debug( '$assigneeFullName  = ', $assigneeFullName );
$loggerMain->debug( '$cqHybridName      = ', $cqHybridName );
$loggerMain->debug( '$assigneeEmail     = ', $assigneeEmail );
$loggerMain->debug( '$assigneeLoginName = ', $assigneeLoginName );
$loggerMain->debug( $DASH x $LINELENGTH );

print $assigneeLoginName . "\n";


END
{
  $g_cqObject->disconnect if $g_cqObject; # disconnect instantiated Clearquest object

  my $logoutResultARef      = $p4->RunLogout();
  my ( $status, $severity ) = Blame::checkP4Status( { p4obj => $p4 } );

  $loggerMain->debug( '$status   = ', $status );
  $loggerMain->debug( '$severity = ', $severity );

}
exit 0;

################################################################################

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
  if( $g_testMode )
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
  my $p_test = shift || $TRUE;
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

sub getInputParameters
{
  my $tmp = @_;

  my $USAGE = << "_EOT_";
"Usage: $script
-project 'CQ project name'
-p4client 'client name'
-p4file 'file name'
[-loglevel DEBUG|INFO|WARN|ERROR|FATAL]
[-test]
[-h|?|help]";
_EOT_

  $USAGE = join $SPACE, split m{\n}x, $USAGE;
  $USAGE .= "\n";

  croak $USAGE unless GetOptions(
                                  "project=s"  => \$cqProject,
                                  "p4client=s" => \$g_p4Client,
                                  "p4file=s"   => \$g_p4File,
                                  "loglevel=s" => \$g_logLevel,
                                  "test"       => \$g_testMode,
                                  "h|?|help"   => \$g_help,
                                );
  print $USAGE and exit if $g_help;
  print $USAGE and exit unless $g_p4Client;
  print $USAGE and exit unless $g_p4File;
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

  Readonly::Scalar $MAX_ERRORS                  => 5;
  Readonly::Scalar $MAX_RETRIES                 => 5;
  Readonly::Scalar $ERRREF_TIMEOUT              => 5; # seconds
  Readonly::Scalar $DIRWAIT_TIMEOUT             => 5; # seconds
  Readonly::Scalar $MAX_DIRWAIT_COUNT           => 12;

  Readonly::Scalar $g_p4EnvPort => q(Pf-sj1-mob.sj.broadcom.com:1668);
  Readonly::Scalar $g_p4EnvUser => q(admin);
  Readonly::Scalar $g_p4EnvPath => q(:/tools/perforce/2010.2/x86_64-rhel5);
  Readonly::Scalar $g_p4Exe     => q(/tools/perforce/2010.2/x86_64-rhel5/p4);

  Readonly::Scalar $g_modificationAgeThreshold  => $hRef->{ acceptableAgeOfModification }; # days
  Readonly::Scalar $g_defaultManager            => $hRef->{ defaultManager              };

  Readonly::Scalar $g_logDirectory_production   => $hRef->{ productionlogs    };
  Readonly::Scalar $g_logDirectory_test         => $hRef->{ testlogs          };

  Readonly::Scalar $g_projectLeadsFile          => $hRef->{ projectleads      };
  Readonly::Scalar $g_xEmailLoginFile           => $hRef->{ exceptionalLogins };

  Readonly::Scalar $g_p4Admin                   => $hRef->{ p4admin           };

  Readonly::Scalar $g_pwConfigFile              => $hRef->{ pwconfig          };

  # lexical regexes
  #
  Readonly::Scalar my $line        => qr{^\s+(\d+)\s+}x;
  Readonly::Scalar my $yyyymmdd    => qr{(\d{4}\/\d{2}\/\d{2})\s+}x;
  Readonly::Scalar my $hhmmss      => qr{(\d{2}:\d{2}:\d{2})\s+}x;
  Readonly::Scalar my $ownerBranch => qr{(.+?)\s+}x;
  Readonly::Scalar my $clId        => qr{(\d+)\s+}x;
  Readonly::Scalar my $revision    => qr{(\d+)}x;
  Readonly::Scalar my $user        => qr{by\s+(\w+)@}x;
  Readonly::Scalar my $leadin      => qr{^info1:.+?change\s+}x;
  Readonly::Scalar my $action      => qr{(\w+)\s+on\s+}x;

  Readonly::Scalar $g_ignoreRegex => qr{^info:|^info2:}x;
  Readonly::Scalar $g_changeRegex => qr{${leadin}${clId}${action}${yyyymmdd}${hhmmss}${user}}x;

  Readonly::Scalar $g_restMessageRegex => qr{Resource\snot\sfound}x;
  Readonly::Scalar $g_p4AdminRegex     => qr{$g_p4Admin|admin}ix;
  Readonly::Scalar $g_adminEmailRegex  => qr{^(.+?)@}x;
  Readonly::Scalar $g_ownerLoginRegex  => qr{^(.+?)@}x;

  Readonly::Scalar $g_broadcomRegex    => qr{broadcom}ix;

  return;
}

__END__
