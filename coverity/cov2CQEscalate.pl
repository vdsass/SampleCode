#!/usr/brcm/ba/bin/perl
use strict;
use warnings;

use lib "/projects/mobcom_andrwks/users/dsass/clone/Clearquest/lib";
use lib "/projects/mobcom_andrwks/users/dsass/clone/Clearquest/etc";

use Carp;
use Clearquest;
use Config::General;

use Data::Dumper::Simple;

#use English;

# obfuscated way of allowing given/when; switch is deprecated
#
use feature qw( switch );
use File::Basename;
use File::Path qw(make_path remove_tree);
use File::Slurp;
use FindBin;

use Getopt::Long;

use Log::Log4perl qw( get_logger :levels );

use Readonly;

use Sys::Hostname;
use System::Command;

use Time::HiRes;

use utf8;
use XML::LibXML;

local $| = 1;
my( $script ) = $FindBin::Script =~ /(.*)\.pl$/x;

my( $g_projectLeadsFile, $g_projectsStreamsXMLFilePath, $g_path2CategoryTypeXMLFilePath,
    $g_ignoredDirectoriesFilePath, $g_logDirectory_production, $g_logDirectory_test,
    $g_pwConfigFile, $g_cimPath, $g_cimPort, $g_cimUser, $g_cimPass, $g_cimMode, $g_cimFields,
    $g_p4Port, $g_p4User, $g_p4Pass, $g_p4EnvDir, $g_p4ExePath, $g_p4Logincmd,
    $covHost, $covProject, $covStream, $covPid, $covStatus, $covClassification, $customer,
    $cqDatabase, $cqProject, $cqPlatform, $critical, $testMode, $logLevel, $logonly, $help,
    $FALSE, $TRUE, $LINELENGTH, $COMMA, $SLASH, $DASH, $SPACE, $EQUAL, $CR, $LF, $REST_OK,
    $REST_NOT_FOUND, $MAX_RECORD_COUNT
  );

my( $triagedRegex, $mobCRegex, $severityRegex, $buildRegex, $ownerLoginRegex,
    $restMessageRegex, $loginRegex, $adminEmailRegex, $javaOptionsRegex
  );

my $debugTrace          = $TRUE;
my $debugTrace_Level_0  = $FALSE;

Readonly::Scalar my $configFilePath  => $FindBin::Bin . '/../config/cov2CQEscalateConfig.xml';

# read the script's config file
#   assign paths and other initialization variables
#
setGlobalParameters( getConfig( $configFilePath ) );

# read the password file; extract pw for mcsi_user
#                         extract pw for p4
#
my $pwHRef = getPwValues( $g_pwConfigFile );
Readonly::Scalar $g_cimPass    => $pwHRef->{ 'scm-password'      };
Readonly::Scalar $g_p4Pass     => $pwHRef->{ 'p4server-password' };
Readonly::Scalar $g_p4Logincmd => $g_p4ExePath . ' login < ' . $g_p4Pass;

getInputParameters();

my $loggerMain_logLevel = getLoggerLevel( $logLevel );
createLogDirectory( $testMode );

Log::Log4perl::init( loggerInit( $testMode ? $g_logDirectory_test : $g_logDirectory_production ) );

my $loggerMain = get_logger( $script );
   $loggerMain->level( $loggerMain_logLevel );

$loggerMain->warn( '$Sys::Hostname::hostname = ', hostname );
$loggerMain->warn( '$Clearquest::VERSION     = ', $Clearquest::VERSION );
$loggerMain->warn( 'XML::LibXML::VERSION     = ', $XML::LibXML::VERSION );

$loggerMain->debug( '$customer   = ', $customer );
$loggerMain->debug( '$covHost    = ', $covHost );
$loggerMain->debug( '$covProject = ', $covProject );
$loggerMain->debug( '$covStream  = ', $covStream );

$loggerMain->debug( '$covPid     = ', $covPid );    # input parameter for now; Coverity pid only exposed in WS API

$loggerMain->debug( '$cqDatabase = ', $cqDatabase );
$loggerMain->debug( '$cqProject  = ', $cqProject );
$loggerMain->debug( '$cqPlatform = ', $cqPlatform );
$loggerMain->debug( '$critical   = ', $critical ) if $critical;
$loggerMain->debug( '$testMode   = ', $testMode ) if $testMode;

$loggerMain->debug( '$g_projectLeadsFile             = ', $g_projectLeadsFile );
$loggerMain->debug( '$g_projectsStreamsXMLFilePath   = ', $g_projectsStreamsXMLFilePath );
$loggerMain->debug( '$g_path2CategoryTypeXMLFilePath = ', $g_path2CategoryTypeXMLFilePath );
$loggerMain->debug( '$g_ignoredDirectoriesFilePath   = ', $g_ignoredDirectoriesFilePath );
$loggerMain->debug( '$g_logDirectory_production      = ', $g_logDirectory_production );
$loggerMain->debug( '$g_logDirectory_test            = ', $g_logDirectory_test );

$cqDatabase = 't_sbx' unless $cqDatabase;
my $g_cqObject = getCQObject( $cqDatabase );

# get project SW leads from config file
#
my $g_projectDataHRef = getProjectData( $g_projectLeadsFile );

$loggerMain->debug( Dumper( $g_projectDataHRef ) );

# query CQ dB for Coverity checker severities
#   severities are associated with & assigned by customer
#
my %checkerSeverity;
my $customerRegex       = qr{^$customer}x;
my $checkerSeverityHRef = \%checkerSeverity;
   $checkerSeverityHRef = getCheckerSeverity( $customerRegex );

$loggerMain->debug( Dumper( $checkerSeverityHRef ) );

# Coverity severities mapped to CQ severity & priority
#
my $covSeverityCQSeverityPriorityHRef = getCQSeveritiesAndPriority();

$loggerMain->debug( Dumper( $covSeverityCQSeverityPriorityHRef ) );

# file path to CQ category type map
#
my $path2CategoryTypeHRef = getpath2CategoryType( $g_path2CategoryTypeXMLFilePath );
$loggerMain->debug(  Dumper( $path2CategoryTypeHRef ) );

# path2CategoryType regex for pattern match
# use m{}p regex modifier to avoid performance penalty on match variable
# use ${^MATCH} variable to satisfy Perl::Critic
#
# $cq_project needs to be substituted into path name; xml configuration file was
# modified with 'cq_project' as a generic for substitution
#
my @modifiedPaths;

for my $path( keys %{$path2CategoryTypeHRef} )
{
  chomp $path;
  $path =~ s/cq_project/${cqProject}/x;
  push @modifiedPaths, $path;
}

my @partialPathregexes = map{ qr{$_}px } @modifiedPaths;

$loggerMain->debug(  Dumper( @partialPathregexes ) );

my $ignoredDirectoriesARef = getIgnoredDirectoriesARef( $g_ignoredDirectoriesFilePath );
$loggerMain->debug(  Dumper( $ignoredDirectoriesARef ) );

my $covDataHRef = getCovData(
                              {
                                host   => $covHost,
                                stream => $covStream,
                                status => $covStatus,
                                class  => $covClassification,
                              }
                            );

$loggerMain->debug( Dumper( $covDataHRef ) );

my $covData = $covDataHRef->{ data };

# some lines of the Coverity 'show' response contain data that does not behave...
#
# loginName [Broadcom ldap]
# (const char *),
# (const char *, char *, int)",
# (const char *, const android::sp<android::MetaData> &)",
# (const char *, const android::sp<android::MetaData> &)",
# (const effect_descriptor_s *, int, unsigned int, int, int)",
# (const native_handle **),
# (const hw_module_t *, const char *, hw_device_t **)",
# (const android::sp<android::DataSource> &, const char *)",
# (const char *, char *, int)",
# (const effect_descriptor_s *, int, unsigned int, int, int)",
# (const native_handle **),
# (const hw_module_t *, const char *, hw_device_t **)",
#
$covData =~ s{\s\[Broadcom\sldap\]}{}gmx; # remove ldap string (seen on ems server)
$covData =~ s{\(.*\)}{}gmx;               # remove function arguments

my @covData = split m{\n}x, $covData;

$loggerMain->debug( Dumper( @covData ) );

# @covData contains the output of cov-manage-im
#   one line per array element
# DATALOOP populates hash
#   primary key     : cid
#   secondary keys  : checker,
#                     file,
#                     function
#
my $cqApproved  = '1';
my $counter     = 0;

my $coverityDefectRecordsSeen                    = 0;
my $errorRecordsProcessed                        = 0;
my $successfulRecordsProcessed                   = 0;
my $triagedRecordsProcessed                      = 0;
my $coverityDefectRecordsPassedIgnoreDirectory   = 0;
my $ignoredDirectory                             = 0;
my $coverityDefectRecordsWithoutCustomerSeverity = 0;
my $passedAllFilters                             = 0;

my $noOwner                                      = 0;
my $unAssignedOwner                              = 0;

my $mobCExtRef                                   = 0;
my $severityMinor                                = 0;


DATALOOP: for my $line( @covData )
{

  ++$coverityDefectRecordsSeen;

  $loggerMain->debug( $EQUAL x $LINELENGTH );
  $loggerMain->debug( '$line = ', $line );

  # filter records that do not conform to expected format
  #
  next DATALOOP unless $line =~ $triagedRegex;

  ++$triagedRecordsProcessed;

  $loggerMain->warn( '$triagedRecordsProcessed = ', $triagedRecordsProcessed );

  #    0      1      2        3           4        5      6      7      8       9      10        11
  #'action,checker,cid,classification,component,ext-ref,file,function,owner,severity,status,stream-name';
  #
  # ext-ref may contain a CQ id indicating ths record has been previously processed (a 'duplicate')
  # so ignore this record...
  #
  my( $covID, $covHashRef ) = getDefectRecordComponents( \$line );

  $loggerMain->info( '$covID = ', $covID );

  # ignore records if there's no owner associated with this defect...
  #   or owner is 'Unassigned'
  #
  my $owner = $covHashRef->{ $covID }{ owner };

  unless( $owner )
  {
    ++$noOwner;
    $loggerMain->info( 'REJECTED: $owner = undef' );
    next DATALOOP;
  }
  elsif( $owner eq 'Unassigned' )
  {
    ++$unAssignedOwner;
    $loggerMain->info( 'REJECTED: $owner = ', $owner );
    next DATALOOP;
  }

  # during development/test the CQ dB t_sbx was used to create CQ records
  #   Coverity records were updated with the CQId from t_sbx
  #     Moving to production t_sbx entries will be overwritten with MobC id's
  #

  my $externalRef = $covHashRef->{ $covID }{ 'ext-ref' };

  if( $externalRef =~ $mobCRegex )
  {
    ++$mobCExtRef;
    $loggerMain->info( 'REJECTED: $externalRef = ', $externalRef );
    next DATALOOP;
  }

  #   when $critical input parameter is set,
  #     skip records whose defect record checker severity is not Major or Moderate
  #
  my $covSeverity = $covHashRef->{ $covID }{ covseverity };

  unless( $critical and $covSeverity =~ $severityRegex )
  {
    ++$severityMinor;
    $loggerMain->info( 'REJECTED: $covSeverity = ', $covSeverity );
    next DATALOOP;
  }

  # filter records if directory path is in the ignore list...
  #
  my $fullFilePath   = $covHashRef->{ $covID }{ fullfilepath   };

  if( ignoreDirectory( $ignoredDirectoriesARef, $fullFilePath ) )
  {
    ++$ignoredDirectory;
    $loggerMain->info( 'REJECTED: ignored directory' );
    next DATALOOP;
  }

  ++$passedAllFilters;
  $loggerMain->info( 'record passed all filtering tests...' );

  my $action         = $covHashRef->{ $covID }{ action         };
  my $checker        = $covHashRef->{ $covID }{ checker        };
  my $classification = $covHashRef->{ $covID }{ classification };
  my $component      = $covHashRef->{ $covID }{ component      };
  my $function       = $covHashRef->{ $covID }{ function       };
  my $status         = $covHashRef->{ $covID }{ status         };
  my $stream_name    = $covHashRef->{ $covID }{ 'stream-name'  };

  # file path components:
  #      0         1                     2                                        3               4       5      6     7     8    9        10        11 12            13
  # /projects/mps_coverity/MP_2.6.0_BCM21664Android_SystemRel_2.1.6/android_hawaii_edn010_java/vendor/broadcom/modem/hawaii/msp/modem/cellularstack/as/uas/urrcdc_build_peer_msg_func.c
  # ^^^^^^^^^^^^^^^^^^^^^^
  #        /build/          <<< when run on bsub queue
  # isolate 'component' name
  #
  my @fileComponents = split m{/}x, $fullFilePath;

  $loggerMain->debug( Dumper( @fileComponents ) );

  my $temp           = shift @fileComponents; # /
     $temp           = shift @fileComponents; # projects
                       # remove 'mps_coverity' ( when testing stand-alone )
     $temp           = shift @fileComponents unless( $fullFilePath =~ $buildRegex ) ;

  my $manifestBranch = shift @fileComponents;
  my $buildVariant   = shift @fileComponents;
  my $shortFilePath  = join $SLASH, @fileComponents;

  my $componentPath = dirname( $shortFilePath );
  my $componentName = basename( $shortFilePath );

  $loggerMain->debug( $DASH x $LINELENGTH );
  $loggerMain->debug( '$covID          = ', $covID );
  $loggerMain->debug( '$action         = ', $action );
  $loggerMain->debug( '$checker        = ', $checker );
  $loggerMain->debug( '$classification = ', $classification );
  $loggerMain->debug( '$component      = ', $component );
  $loggerMain->debug( '$externalRef    = ', $externalRef ) if $externalRef;
  $loggerMain->debug( '$fullFilePath   = ', $fullFilePath );

  $loggerMain->debug( '$shortFilePath  = ', $shortFilePath );
  $loggerMain->debug( '$componentPath  = ', $componentPath );
  $loggerMain->debug( '$componentName  = ', $componentName );

  $loggerMain->debug( '$manifestBranch = ', $manifestBranch );
  $loggerMain->debug( '$buildVariant   = ', $buildVariant );

  $loggerMain->debug( '$function       = ', $function ) if $function;
  $loggerMain->debug( '$owner          = ', $owner );

  my( $loginName, $domainName )       =    $owner =~ $ownerLoginRegex;
  $loggerMain->debug( '$loginName      = ', $loginName );
  $loggerMain->debug( '$domainName     = ', $domainName );

  $loggerMain->debug( '$covSeverity    = ', $covSeverity );
  $loggerMain->debug( '$status         = ', $status );
  $loggerMain->debug( '$stream_name    = ', $stream_name );

  # search categoryTypes hash;
  #   match the current path with the partial path key to get categoryType;
  #     use default if no match
  #
  my( $cqCatType, $cqSubCat ) = getCategoryTypeAndSubType( $path2CategoryTypeHRef, \@partialPathregexes, $fullFilePath );

  my $cqSeverity = $covSeverityCQSeverityPriorityHRef->{ $covSeverity }{ severity };
  my $cqPriority = $covSeverityCQSeverityPriorityHRef->{ $covSeverity }{ priority };

  $loggerMain->debug( '$loginName  = ', $loginName  );
  $loggerMain->debug( '$cqSubCat   = ', $cqSubCat   ) if $cqSubCat;
  $loggerMain->debug( '$cqCatType  = ', $cqCatType  );
  $loggerMain->debug( '$cqSeverity = ', $cqSeverity );
  $loggerMain->debug( '$cqPriority = ', $cqPriority );

  my %cqRecord =(
                  Platform          => $cqPlatform,
                  Project           => $cqProject,
                  Title             => 'Coverity Defect',
                  Found_In_Versions => ['N/A'],
                  Severity          => $cqSeverity,
                  CM_Log            => 'A Coverity defect was detected.',
                );

  $loggerMain->debug( Dumper( %cqRecord ) );

  # defect record [update] requires a valid 'Assignee'
  #   if the Assignee, which is a user login name, is no longer an employee
  #     the project's SW lead is the Assignee
  #
  my( $validEmail, $validName, $validLoginName, $cqAssigneeFullName ) = validateAssignee( $cqProject, $loginName );

  $loggerMain->debug( '$validEmail         = ', $validEmail );
  $loggerMain->debug( '$validName          = ', $validName );
  $loggerMain->debug( '$validLoginName     = ', $validLoginName );
  $loggerMain->debug( '$cqAssigneeFullName = ', $cqAssigneeFullName );
  $loggerMain->debug( $DASH x $LINELENGTH );

  updateCQAndCoverity(
                        {
                         cqrecord       => \%cqRecord,
                         covhost        => $covHost,
                         covproject     => $covProject,
                         covid          => $covID,
                         checker        => $checker,
                         fullfilepath   => $fullFilePath,
                         componentpath  => $componentPath,
                         componentname  => $componentName,
                         function       => $function,
                         owner          => $owner,
                         covseverity    => $covSeverity,
                         cqplatform     => $cqPlatform,
                         cqproject      => $cqProject,
                         cqpriority     => $cqPriority,
                         cqseverity     => $cqSeverity,
                         cqcattype      => $cqCatType,
                         cqsubcat       => $cqSubCat,
                         cqapproved     => $cqApproved,
                         validemail     => $validEmail,
                         assigneefn     => $cqAssigneeFullName,
                        }
                     ) unless $testMode;


  last DATALOOP if $testMode and ++$counter == $MAX_RECORD_COUNT;

} # DATALOOP

$loggerMain->warn();
$loggerMain->warn( '$coverityDefectRecordsSeen                    = ', $coverityDefectRecordsSeen );
$loggerMain->warn( '$triagedRecordsProcessed                      = ', $triagedRecordsProcessed );
$loggerMain->warn( '$noOwner                                      = ', $noOwner );
$loggerMain->warn( '$unAssignedOwner                              = ', $unAssignedOwner );
$loggerMain->warn( '$mobCExtRef                                   = ', $mobCExtRef );
$loggerMain->warn( '$severityMinor                                = ', $severityMinor );
$loggerMain->warn( '$ignoredDirectory                             = ', $ignoredDirectory );
$loggerMain->warn();
$loggerMain->warn( '$passedAllFilters                             = ', $passedAllFilters );
$loggerMain->warn( '$successfulRecordsProcessed                   = ', $successfulRecordsProcessed );
$loggerMain->warn( '$errorRecordsProcessed                        = ', $errorRecordsProcessed );
$loggerMain->warn();


END
{
  $g_cqObject->disconnect if $g_cqObject; # disconnect instantiated Clearquest object
}

exit;

################################################################################


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

sub updateCQAndCoverity
{
  my $pHRef              = shift;

  my $updateCQAndCoverity_Start = Time::HiRes::time();

  my $p_cqRecordHRef     = $pHRef->{ cqrecord      };
  my $p_covHost          = $pHRef->{ covhost       };
  my $p_covProject       = $pHRef->{ covproject    };
  my $p_covID            = $pHRef->{ covid         };
  my $p_checker          = $pHRef->{ checker       };
  my $p_fullFilePath     = $pHRef->{ fullfilepath  };
  my $p_componentPath    = $pHRef->{ componentpath };
  my $p_componentName    = $pHRef->{ componentname };
  my $p_function         = $pHRef->{ function      };
  my $p_covSeverity      = $pHRef->{ covseverity   };

  my $p_cqPlatform       = $pHRef->{ cqplatform    };
  my $p_cqProject        = $pHRef->{ cqproject     };
  my $p_cqSeverity       = $pHRef->{ cqseverity    };
  my $p_cqPriority       = $pHRef->{ cqpriority    };
  my $p_cqCatType        = $pHRef->{ cqcattype     };
  my $p_cqSubCat         = $pHRef->{ cqsubcat      };
  my $p_cqApproved       = $pHRef->{ cqapproved    };
  my $p_validEmail       = $pHRef->{ validemail    };
  my $p_cqAssigneeFN     = $pHRef->{ assigneefn    };

  # update CQ
  #
  #   mandatory fields for adding a Defect record
  #   NOTE: order is important!
  #         the order array specifies to the REST module in what order the fields
  #         are to be updated
  #
  my @order = qw( Project Platform Found_In_Versions Severity );

  my $addDBID = $g_cqObject->add( 'Defect', $p_cqRecordHRef, @order );

  my( $addStatus, $addMsg ) = checkRESTError();
  $loggerMain->error( '$addStatus = ', $addStatus ) unless( $addStatus == $REST_OK );
  $loggerMain->error( '$addMsg    = ', $addMsg )    if $addMsg;
  $loggerMain->debug( Dumper( $addDBID ) );

  my @fields = qw( id State Project Platform Title Severity Found_In_Versions Approved_by_CCB CM_Log );
  my %getDBIDResult = $g_cqObject->getDBID( 'Defect', $addDBID, @fields );
  my( $getDBIDStatus, $getDBIDMsg ) = checkRESTError();
  $loggerMain->error( '$getDBIDStatus = ', $getDBIDStatus )  unless $getDBIDStatus == $REST_OK;
  $loggerMain->error( '$getDBIDMsg    = ', $getDBIDMsg    )  if $getDBIDMsg;
  $loggerMain->debug( Dumper( %getDBIDResult ) );

  my $cqID = $getDBIDResult{ id };
  $loggerMain->info ( '$cqID          = ', $cqID );

# http://mpsscm-coverity.broadcom.com:8080/sourcebrowser.htm?projectId=10002#mergedDefectId=10191

  my $description = << "__EOF__";
Issue Description: A Coverity defect was discovered.
    Steps to Reproduce:
      1. Coverity scan performed by SCM.
      2. Details at http://mpsscm-coverity.broadcom.com:8080/sourcebrowser.htm?projectId=${covPid}#mergedDefectId=${p_covID}
\n
      Frequency of Problem: Always
\n
      Other information:
        Coverity ID\t: ${p_covID}
        CheckerID\t: ${p_checker}
        Component path\t: ${p_componentPath}
        Component\t: ${p_componentName}
        Function\t: ${p_function}
        Read about triaging a Coverity defect: http://confluence.broadcom.com/display/MWGMPSSCM/How+To+Triage+A+Coverity+Defect
__EOF__

  # when performing an update, repeat all fields (i.e., re-write) that are currently set in the record
  #
  my %update =(
                Platform          => $p_cqPlatform,
                Project           => $p_cqProject,
                Title             => "[Coverity] CID=$p_covID $p_checker $p_covSeverity $p_fullFilePath",
                Found_In_Versions => ['N/A'],
                Severity          => $p_cqSeverity,
                AssigneeFullName  => $p_cqAssigneeFN,
                Priority          => $p_cqPriority,
                HowFound          => 'Analysis',
                Category          => 'Software',
                Category_Type     => $p_cqCatType,
                'Sub-Category'    => $p_cqSubCat,
                Submitter         => 'AdminAutoSubmit',
                Entry_Type        => 'Defect',
                Verifier          => 'AdminAutoSubmit',
                Visibility        => 'Broadcom only',
                CM_Log            => 'Changed state to assigned',
                Approved_by_CCB   => $p_cqApproved,
                Description       => $description,
              );

  # NOTE: order is important!
  #       the order array specifies to the REST module in what order the fields
  #       are to be updated
  #
  @order = qw( Project Platform Found_In_Versions Severity Category Category_Type Sub-Category );

  my $modifyResult = $g_cqObject->modify( 'Defect', $cqID, 'Assign', \%update, @order );


  my( $modifyStatus, $modifyMsg ) = checkRESTError();
  $loggerMain->error( '$modifyStatus = ', $modifyStatus ) unless $modifyStatus == $REST_OK;
  $loggerMain->error( '$modifyMsg    = ', $modifyMsg )    if $modifyMsg;
  $loggerMain->error( Dumper( $modifyResult ) )           if $modifyMsg;

  @fields = qw( id Assignee State Project Platform Title Severity Found_In_Versions Approved_by_CCB CM_Log
                Priority HowFound Category Category_Type Sub-Category Submitter Entry_Type Verifier
                Visibility CM_Log Approved_by_CCB Description
              );

  my %getResult = $g_cqObject->get( 'Defect', $cqID, @fields );
  my( $getStatus, $getMsg ) = checkRESTError();
  $loggerMain->error( '$getStatus = ', $getStatus )  unless $getStatus == $REST_OK;
  $loggerMain->error( '$getMsg    = ', $getMsg )     if $getMsg;
  $loggerMain->error( Dumper( %getResult ) )         if $getMsg;

  unless( $logonly )
  {
    my $updateCovHRef = updateCov(
                                    {
                                      host      => $p_covHost,
                                      project   => $p_covProject,
                                      cid       => $p_covID,
                                      cqid      => $cqID,
                                      assignee  => $p_validEmail,
                                      severity  => $p_covSeverity,
                                    }
                                  );

    if( ref $updateCovHRef )
    {
      $loggerMain->debug( '$updateCovHRef isa : ', ref( $updateCovHRef ) );
      $loggerMain->debug( Dumper( $updateCovHRef ) );

      if( $updateCovHRef->{ status } )
      {
        ++$successfulRecordsProcessed;
      }
      else
      {
        ++$errorRecordsProcessed;
      }

    }
    else
    {
      $loggerMain->fatal( '$updateCovHRef is not a reference' );
    }

  } # logonly

  my $updateCQAndCoverity_End      = Time::HiRes::time();
  my $updateCQAndCoverity_Duration = $updateCQAndCoverity_End - $updateCQAndCoverity_Start;
  $loggerMain->info( '$updateCQAndCoverity_Duration = ', $updateCQAndCoverity_Duration );

  return;

} # updateCQAndCoverity


sub getCQObject
{
  my $database = shift;
  my $cq = Clearquest->new( CQ_DATABASE => $cqDatabase, );
  $cq->connect()
    or croak '__CROAK__: Cannot connect to cq database: ', $cqDatabase;
  return $cq;
}


sub ignoreDirectory
{
  my $arrayRef = shift;
  my $filePath = shift;
  my $retval;

  my $ignoreDirectory_Start      = Time::HiRes::time();

  if( $filePath ~~ @{$arrayRef} )
  {
    $loggerMain->info( 'MATCHED  : $filePath = ', $filePath );
    $retval = $TRUE;
  }
  else
  {
    $loggerMain->info( 'NO MATCH: $filePath = ', $filePath );
    $retval = $FALSE;
  }

  my $ignoreDirectory_End      = Time::HiRes::time();
  my $ignoreDirectory_Duration = $ignoreDirectory_End - $ignoreDirectory_Start;
  $loggerMain->info( '$ignoreDirectory_Duration = ', $ignoreDirectory_Duration );

  return $retval;
}

sub getDefectRecordComponents
{
  my $defectRecordRef = shift;

  my @tmp = split m{,}x, ${$defectRecordRef};

  $loggerMain->debug( Dumper( @tmp ) );

  #    0      1      2        3           4        5      6      7      8       9      10        11
  #'action,checker,cid,classification,component,ext-ref,file,function,owner,severity,status,stream-name';
  #
  # ext-ref may contain a CQ id indicating ths record has been previously processed (a 'duplicate')
  # so ignore this record...
  #
  my %hash;
  my $CID                         = $tmp[2];

  $hash{ $CID }{ action         } = $tmp[0];
  $hash{ $CID }{ checker        } = $tmp[1];

  $hash{ $CID }{ classification } = $tmp[3];
  $hash{ $CID }{ component      } = $tmp[4];
  $hash{ $CID }{ 'ext-ref'      } = $tmp[5];
  $hash{ $CID }{ fullfilepath   } = $tmp[6];
  $hash{ $CID }{ function       } = $tmp[7];
  $hash{ $CID }{ owner          } = $tmp[8];
  $hash{ $CID }{ covseverity    } = $tmp[9];
  $hash{ $CID }{ status         } = $tmp[10];
  $hash{ $CID }{ 'stream-name'  } = $tmp[11];

  return $CID, \%hash;
}

# use m{}p regex modifier to avoid performance penalty on match variable
# use ${^MATCH} variable to satisfy Perl::Critic
#
sub getCategoryTypeAndSubType
{
  my( $hashRef, $arrayRef, $filePath )= @_;
  my( $cqCatType, $cqSubCat );

  if( $filePath ~~ @{$arrayRef} )
  {
    $loggerMain->info( 'MATCHED: $filePath = ', $filePath  );
    $loggerMain->info( '         ${^MATCH} = ', ${^MATCH}  );

    $cqCatType = $hashRef->{ ${^MATCH} };
  }
  else
  {
    $loggerMain->debug( 'NO MATCH' );
    $cqCatType = 'AP Android';
  }
  $cqSubCat  = 'N/A';
  return $cqCatType, $cqSubCat;
}

sub getCQSeveritiesAndPriority
{

  my %covSeverityCQSeverityPriority;

  $covSeverityCQSeverityPriority{ Major } =    {
                                                 severity => '1 - Critical',
                                                 priority => '1 - Resolve Immediately',
                                               };

  $covSeverityCQSeverityPriority{ Moderate } = {
                                                 severity => '2 - Major',
                                                 priority => '2 - Give High Attention',
                                               };

  $covSeverityCQSeverityPriority{ Minor } =    {
                                                 severity => '4 - Minor',
                                                 priority => '4 - Low Priority',
                                               };

  return \%covSeverityCQSeverityPriority;
}

sub setGlobalParameters
{
  my $hRef = shift;

  Readonly::Scalar $FALSE                       => 0;
  Readonly::Scalar $TRUE                        => 1;

  Readonly::Scalar $LINELENGTH                  => 80;

  Readonly::Scalar $COMMA                       => q{,};
  Readonly::Scalar $SLASH                       => q{/};
  Readonly::Scalar $DASH                        => q{-};
  Readonly::Scalar $EQUAL                       => q{=};
  Readonly::Scalar $CR                          => chr(13);
  Readonly::Scalar $LF                          => chr(10);
  Readonly::Scalar $SPACE                       => chr(32);

  Readonly::Scalar $REST_OK                     => 0;
  Readonly::Scalar $REST_NOT_FOUND              => 404;

  Readonly::Scalar $g_projectLeadsFile             => $hRef->{ projectleads      };
  Readonly::Scalar $g_projectsStreamsXMLFilePath   => $hRef->{ projects2streams  };
  Readonly::Scalar $g_path2CategoryTypeXMLFilePath => $hRef->{ path2categorytype };
  Readonly::Scalar $g_ignoredDirectoriesFilePath   => $hRef->{ ignoredirectories };
  Readonly::Scalar $g_logDirectory_production      => $hRef->{ productionlogs    };
  Readonly::Scalar $g_logDirectory_test            => $hRef->{ testlogs          };

  Readonly::Scalar $g_cimPath                      => $hRef->{ cimpath           };
  Readonly::Scalar $g_cimPort                      => $hRef->{ cimport           };
  Readonly::Scalar $g_cimUser                      => $hRef->{ cimuser           };

  Readonly::Scalar $g_cimMode                      => $hRef->{ cimmode           };
  Readonly::Scalar $g_cimFields                    => $hRef->{ cimfields         };

  Readonly::Scalar $g_p4Port                       => $hRef->{ p4port            };
  Readonly::Scalar $g_p4User                       => $hRef->{ p4user            };
  Readonly::Scalar $g_p4EnvDir                     => $hRef->{ p4envdir          };
  Readonly::Scalar $g_p4ExePath                    => $hRef->{ p4exepath         };

  Readonly::Scalar $g_pwConfigFile                 => $hRef->{ pwconfig          };

  Readonly::Scalar $MAX_RECORD_COUNT               => $hRef->{ maxrecordcount    };# for testing

  Readonly::Scalar $triagedRegex                   => qr{Triaged}x;
  Readonly::Scalar $mobCRegex                      => qr{MobC}x;
  Readonly::Scalar $severityRegex                  => qr{Major|Moderate}x;
  Readonly::Scalar $buildRegex                     => qr{build}x;
  Readonly::Scalar $ownerLoginRegex                => qr{^(.+?)@(.+?)$}ix;
  Readonly::Scalar $restMessageRegex               => qr{Resource\snot\sfound}x;
  Readonly::Scalar $loginRegex                     => qr{pgaurav|mcsi_user}ix;
  Readonly::Scalar $adminEmailRegex                => qr{^(.+?)@}x;
  Readonly::Scalar $javaOptionsRegex               => qr{^Picked\sup\s_JAVA_OPTIONS:}x;

  return;
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
-customer 'customer name'
-covhost 'emsscm-coverity|mpsscm-coverity'
-covproject 'Coverity project'
-covpid 'Coverity project ID'
-covstream 'Coverity stream'
-covstatus 'Coverity defect status'
-covclass 'Coverity defect classification'
-cqproject 'Clearquest project'
-cqplatform 'Clearquest platform'
[-critical]
[-test]
[-loglevel [DEBUG|INFO|WARN|ERROR|FATAL]]
[-logonly]
[-h|?|help]"
_EOT_

  $USAGE = join $SPACE, split m{\n}x, $USAGE;
  $USAGE .= "\n";

  croak $USAGE unless GetOptions(
                                  "customer=s"    => \$customer,
                                  "covhost=s"     => \$covHost,
                                  "covproject=s"  => \$covProject,
                                  "covpid=i"      => \$covPid,
                                  "covstream=s"   => \$covStream,
                                  "covstatus=s"   => \$covStatus,
                                  "covclass=s"    => \$covClassification,
                                  "cqdatabase=s"  => \$cqDatabase,
                                  "cqproject=s"   => \$cqProject,
                                  "cqplatform=s"  => \$cqPlatform,
                                  "critical"      => \$critical,
                                  "test"          => \$testMode,
                                  "loglevel=s"    => \$logLevel,
                                  "logonly"       => \$logonly,
                                  "h|?|help"      => \$help,
                                );

  print $USAGE and exit if $help;
  croak "__CROAK__: Customer argument required\n$USAGE" unless $customer eq 'Samsung';

  return;
}

sub getConfig
{
  my $xmlFilePath = shift;

  print $script, $SPACE, __LINE__, ' $xmlFilePath = ', $xmlFilePath, "\n" if $debugTrace;

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

  print $script, $SPACE, __LINE__, " No XML or system errors...\n" if $debugTrace;

  my %config;

  for my $covIgnoredDirectoriesNode( $doc->findnodes( '/config/*' ) )
  {
    my $name  = $covIgnoredDirectoriesNode->getAttribute( 'name' );
    my $value = $covIgnoredDirectoriesNode->getAttribute( 'value' );
    print $script, $SPACE, __LINE__, 'name = ', $name, '$value = ', $value, "\n" if $debugTrace_Level_0;

    $config{ $name } = $value;
  }
  print $script, $SPACE, __LINE__, Dumper( %config ) if $debugTrace_Level_0;
  return \%config;
}

sub reportXMLError
{
  # report a structured error (XML::LibXML::Error object)
  #
  my $message = $@->as_string();
  $loggerMain->error( '$message = ', $message ) if $message;

  my $error_domain = $@->domain();
  $loggerMain->error( '$error_domain = ', $error_domain ) if $error_domain;

  my $error_code = $@->code();
  $loggerMain->error( '$error_code = ', $error_code ) if $error_code;

  my $error_message = $@->message();
  $loggerMain->error( '$error_message = ', $error_message ) if $error_message;

  my $error_level = $@->level();
  $loggerMain->error( '$error_level = ', $error_level ) if $error_level;

  my $filename = $@->file();
  $loggerMain->error( '$filename = ', $filename ) if $filename;

  my $line = $@->line();
  $loggerMain->error( '$line = ', $line ) if $line;

  my $nodename = $@->nodename();
  $loggerMain->error( '$nodename = ', $nodename ) if $nodename;

  my $error_str1 = $@->str1();
  $loggerMain->error( '$error_str1 = ', $error_str1 ) if $error_str1;

  my $error_str2 = $@->str2();
  $loggerMain->error( '$error_str2 = ', $error_str2 ) if $error_str2;

  my $error_str3 = $@->str3();
  $loggerMain->error( '$error_str3 = ', $error_str3 ) if $error_str3;

  my $error_num1 = $@->num1();
  $loggerMain->error( '$error_num1 = ', $error_num1 ) if $error_num1;

  my $error_num2 = $@->num2();
  $loggerMain->error( '$error_num2 = ', $error_num2 ) if $error_num2;

  my $string = $@->context();
  $loggerMain->error( '$string = ', $string ) if $string;

  my $offset = $@->column();
  $loggerMain->error( '$offset = ', $offset ) if $offset;

  my $previous_error = $@->_prev();
  $loggerMain->error( '$previous_error = ', $previous_error ) if $previous_error;
  return;
}

sub getpath2CategoryType
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

  print $script, $SPACE, __LINE__, " No XML or system errors...\n" if $debugTrace;

  my %path2CategoryType;
  for my $categoryTypesNode( $doc->findnodes( '/configuration/category_types/*' ) )
  {
    my $path = $categoryTypesNode->getAttribute( 'path' );
    $loggerMain->debug( '$path = ', $path );
    my $categorytype = $categoryTypesNode->getAttribute( 'categorytype' );
    $loggerMain->debug( '$categorytype = ', $categorytype );
    $path2CategoryType{ $path } = $categorytype;
  }
  $loggerMain->debug(  Dumper( %path2CategoryType ) );
  return \%path2CategoryType;
}

sub getIgnoredDirectoriesARef
{
  my $filePath  = shift;

  # chomp => 1 doesn't seem to work
  my $linesARef = read_file( $filePath, array_ref => 1, chomp => 1 );
  chomp @{$linesARef};

  # array element must be a regex for smart match operator ~~
  #
  my @regexes = map{ qr{$_}x } @{$linesARef};
  return \@regexes;
}

################################################################################

# validateAssignee - get Assignee from 'users' table
#
sub validateAssignee
{
  my $project = shift;
  my $login   = shift || 'AdminAutoSubmit';

  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  my $logger = get_logger( $subroutine );
  $logger->level( $WARN );
  $logger->debug( '$login : ', $login);

  # 'LIKE' is NOT SUPPORTED BY REST...
  #    Andrew deFaria: "As for like, you'll probably need to do something like
  #    "<fieldname> like '%var%'" for the condition."
  #
  my( $validatedEmail, $validatedFullName, $validatedLoginName, $compositName );
  my $table = 'users';

  my %dBRecord = $g_cqObject->get( $table, $login, qw( is_active email fullname login_name ) );
  $logger->debug( Dumper( %dBRecord ) );

  my( $restStatus, $restMsg ) = checkRESTError();

  unless( $restStatus == $REST_OK )
  {
    if( $restStatus == $REST_NOT_FOUND and $restMsg =~ $restMessageRegex )
    {
      $logger->warn( 'Can not find $login = ', $login, ' Using SW lead. $restStatus = ', $restStatus );

      # use SW lead from project config file
      #
      my $projectDataHRef = getProjectData( );

      $logger->debug( Dumper( $projectDataHRef ) );

      if( exists $projectDataHRef->{ $project } )
      {
        $logger->warn( 'Using $g_projectLeadsFile: ', $g_projectLeadsFile, ' SW lead data for ', $project  );

        $logger->debug( '$swLead             = ', $projectDataHRef->{ $project }{ swLead      } );
        $logger->debug( '$swLeadEmail        = ', $projectDataHRef->{ $project }{ swLeadEmail } );
        $logger->debug( '$validatedLoginName = ', $projectDataHRef->{ $project }{ swLeadLogon } );

        $validatedLoginName = $projectDataHRef->{ $project }{ swLeadLogon };
        $validatedEmail     = $projectDataHRef->{ $project }{ swLeadEmail };
        $validatedFullName  = $projectDataHRef->{ $project }{ swLead      };
      }
      else
      {
        $logger->warn( 'Using CQ AdminAutoSubmit email address. ', $project, ' is not in $g_projectLeadsFile: ', $g_projectLeadsFile );

        my %adminRecord    = $g_cqObject->get( $table, 'AdminAutoSubmit', qw( login_name email fullname ) );
        my $adminEmail     = $adminRecord{ email };
        my $adminFullName  = $adminRecord{ fullname };

        $logger->debug( '$adminEmail    = ', $adminEmail );
        $logger->debug( '$adminFullName = ', $adminFullName );

        my %userRecord      = $g_cqObject->get( $table, $adminEmail, qw( login_name email fullname ) );
        $validatedEmail     = $userRecord{ email };
        $validatedFullName  = $userRecord{ fullname };
        $validatedLoginName = $userRecord{ login_name };

        $logger->debug( '$validatedEmail     = ', $validatedEmail );
        $logger->debug( '$validatedFullName  = ', $validatedFullName );
        $logger->debug( '$validatedLoginName = ', $validatedLoginName );
      }
    }
    else
    {
      $logger->error( '$restMsg = ', $restMsg ) if $restMsg;
      croak '__CROAK__: Unexpected CQ REST failure: $restStatus = ', $restStatus;
    }
  }
  else
  {
    # user record could be in the dB, but not active
    #
    if( $dBRecord{ is_active } )
    {
      $logger->debug( 'User ', $login, ' is_active.' );
      $logger->debug( Dumper( %dBRecord ) );
      $logger->debug( 'email : ', $dBRecord{ email } );

      # Prashant Gaurav is associated with all P4 branch creations...
      #
      if( $login =~ $loginRegex )
      {
        $logger->debug( '$login = ', $login );

        # use SW lead from project config file
        #
        my $projectDataHRef = getProjectData( );

        if( exists $projectDataHRef->{ $project } )
        {
          $logger->warn( 'Using $g_projectLeadsFile: ', $g_projectLeadsFile, ' SW lead data for ', $project  );

          $validatedLoginName = $projectDataHRef->{ $project }{ swLeadLogon };
          $validatedEmail     = $projectDataHRef->{ $project }{ swLeadEmail };
          $validatedFullName  = $projectDataHRef->{ $project }{ swLead };

          $logger->debug( '$validatedFullName  = ', $validatedFullName );
          $logger->debug( '$validatedEmail     = ', $validatedEmail );
          $logger->debug( '$validatedLoginName = ', $validatedLoginName );
        }
        else
        {
          $logger->warn( 'Using CQ AdminAutoSubmit email address. ', $project, ' is not in $g_projectLeadsFile: ', $g_projectLeadsFile );

          my %adminRecord    = $g_cqObject->get( $table, 'AdminAutoSubmit', qw( login_name email fullname ) );
          my $adminEmail     = $adminRecord{ email };
          my $adminFullName  = $adminRecord{ fullname };

          $logger->debug( '$adminEmail    = ', $adminEmail );
          $logger->debug( '$adminFullName = ', $adminFullName );

          # can't use login_name for AdminAutoSubmit...
          # ...extract it from the assigned admin's email
          #
          my( $validatedAdminLogin ) = $adminEmail =~ $adminEmailRegex;

          my %userRecord      = $g_cqObject->get( $table, $validatedAdminLogin, qw( login_name email fullname ) );
          $validatedEmail     = $userRecord{ email };
          $validatedFullName  = $userRecord{ fullname };
          $validatedLoginName = $userRecord{ login_name };
        }
      }
      else
      {
        $validatedEmail       = $dBRecord{ email };
        $validatedFullName    = $dBRecord{ fullname };
        $validatedLoginName   = $dBRecord{ login_name };
      }

      $logger->debug( '$validatedEmail     = ', $validatedEmail );
      $logger->debug( '$validatedFullName  = ', $validatedFullName );
      $logger->debug( '$validatedLoginName = ', $validatedLoginName );

    }
    else
    {
      $logger->warn( $login, ' is not an active employee. Using CQ AdminAutoSubmit to get a valid email address.' );

      my %adminRecord    = $g_cqObject->get( $table, 'AdminAutoSubmit', qw( login_name email fullname ) );
      my $adminEmail     = $adminRecord{ email };
      my $adminFullName  = $adminRecord{ fullname };

      $logger->debug( '$adminEmail    = ', $adminEmail );
      $logger->debug( '$adminFullName = ', $adminFullName );

      # can't use login_name for AdminAutoSubmit...
      # ...extract it from the assigned admin's email
      #
      my( $validatedAdminLogin ) = $adminEmail =~ $adminEmailRegex;

      my %userRecord      = $g_cqObject->get( $table, $validatedAdminLogin, qw( login_name email fullname ) );
      $validatedEmail     = $userRecord{ email };
      $validatedFullName  = $userRecord{ fullname };
      $validatedLoginName = $userRecord{ login_name };

    }
  }

  $compositName = $validatedFullName . ' - ' . $validatedLoginName;

  $logger->debug( '$validatedEmail    = ', $validatedEmail );
  $logger->debug( '$validatedFullName = ', $validatedFullName );
  $logger->debug( '$compositName      = ', $compositName );

  return( $validatedEmail, $validatedFullName, $validatedLoginName, $compositName );
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

##################################################################
# query CQ dB for Coverity CHECKER severity (assigned by customer)
# input parameter is a customer regex
# output is a hash of checker => severity for the matched customer
#
sub getCheckerSeverity
{
  my $matchRegex  = shift;

  $loggerMain->debug( Dumper( $matchRegex ) );

  # REST does not support regex or 'like'
  #my( $result, $numrecs ) = $g_cqObject->find( 'CovCheckerSeverityMap', "Customer =~ $matchRegex", qw( Customer CheckerID Severity ) );
  my( $result, $numrecs ) = $g_cqObject->find( 'CovCheckerSeverityMap', "CheckerID!='NULL'", qw( Customer CheckerID Severity ) );

  $loggerMain->debug( 'returned from $g_cqObject->find()' );

  my( $restStatus, $restMsg ) = checkRESTError();
  $loggerMain->error( '$restStatus = ', $restStatus ) unless( $restStatus == $REST_OK );
  $loggerMain->error( '$restMsg    = ', $restMsg )    if $restMsg;
  $loggerMain->debug( '$g_cqObject->find was successful' );

   my $severityHashRef;

  # get data for this customer only
  #
  GETNEXTLOOP: while( my %cqRecord = $g_cqObject->getNext( $result ) )
  {
    next GETNEXTLOOP unless $cqRecord{ Customer } =~ $matchRegex;

       $customer  = $cqRecord{ Customer  };
    my $checkerID = $cqRecord{ CheckerID };
    my $severity  = $cqRecord{ Severity  };

    $severityHashRef->{ $checkerID } = $severity;
  }
  return $severityHashRef;
}

sub updateCov
{
  my $pHashRef = shift;

  my $p_host     = $pHashRef->{ host  };
  my $p_project  = $pHashRef->{ project  };
  my $p_cid      = $pHashRef->{ cid      };
  my $p_cqid     = $pHashRef->{ cqid     };
  my $p_assignee = $pHashRef->{ assignee };
  my $p_severity = $pHashRef->{ severity };

  local $| = 1;

  $p_assignee = 'mcsi_user' if( $p_assignee eq 'admin' );

  my $cmdString = <<"_EOT_";
$g_cimPath
--host $p_host
--port $g_cimPort
--user $g_cimUser
--password $g_cimPass
--mode $g_cimMode
--update
--project $p_project
--cid $p_cid
--set ext-ref:$p_cqid
_EOT_

  $cmdString = join $SPACE, split m{\n}x, $cmdString;

  my $updateCovStatus;
  my $updateCovData;
  my $updateCovError;

  my $cmdObj = System::Command->new( $cmdString );

  $loggerMain->debug( '$cmdObj->cmdline() = ', $cmdObj->cmdline() );

  my $stdOutGlobRef = $cmdObj->stdout();
  my $stdErrGlobRef = $cmdObj->stderr();

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

    $updateCovStatus = $FALSE;
  }
  else
  {
    my $stdOut;
    my $stdErr;
    $updateCovStatus = $TRUE;

    STDOUTLOOP: while( $stdOut = <$stdOutGlobRef> )
    {
      chomp $stdOut;
      $loggerMain->debug( '$stdOut = ', $stdOut );
      $updateCovData  .= $SPACE . $stdOut;
    }
    STDERRLOOP: while( $stdErr = <$stdErrGlobRef> )
    {
      chomp $stdErr;
      # the java options message is of no consequence
      #   even though it's written on stderr
      #
      last STDERRLOOP if $stdErr =~ $javaOptionsRegex;
      $loggerMain->error( '$stdErr = ', $stdErr );
      $updateCovError .= $SPACE . $stdErr;
      $updateCovStatus = $FALSE;
    }
  }
  $cmdObj->close();
  return (
          {
            status => $updateCovStatus,
            data   => $updateCovData,
            error  => $updateCovError,
          }
         );
}

sub getCovData
{
  my $pHashRef = shift;
  my $getCovData_Start = Time::HiRes::time();

  my $p_host     = $pHashRef->{ host   };
  my $p_stream   = $pHashRef->{ stream };
  my $p_status   = $pHashRef->{ status };
  my $p_class    = $pHashRef->{ class  };

  local $| = 1;

  # 20130319: do not use classification for filtering (i.e., 'Bug' ) --classification $p_class
  #
  my $cmdString = <<"_EOT_";
$g_cimPath
--host $p_host
--port $g_cimPort
--user $g_cimUser
--password $g_cimPass
--mode $g_cimMode
--show
--stream $p_stream
--status $p_status
--fields \"$g_cimFields\"
_EOT_

  $cmdString = join $SPACE, split m{\n}x, $cmdString;

  my $getCovStatus;
  my $getCovData;
  my $getCovError;

  my $cmdObj = System::Command->new( $cmdString );

  $loggerMain->debug( '$cmdObj->cmdline() = ', $cmdObj->cmdline() );

  my $stdOutGlobRef = $cmdObj->stdout();
  my $stdErrGlobRef = $cmdObj->stderr();

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

    $getCovStatus = $FALSE;
  }
  else
  {
    my $stdOut;
    my $stdErr;
    $getCovStatus = $TRUE;

    STDOUTLOOP: while( $stdOut = <$stdOutGlobRef> )
    {
      # do NOT chomp the data; upstream code depends on \n
      #
      #$loggerMain->debug( '$stdOut = ', $stdOut );
      $getCovData .= $stdOut;
    }

    STDERRLOOP: while( $stdErr = <$stdErrGlobRef> )
    {
      chomp $stdErr;

      # the 'java options' message is of no consequence
      #   even though it's written on stderr
      #
      last STDERRLOOP if $stdErr =~ $javaOptionsRegex;
      $loggerMain->error( '$stdErr = ', $stdErr );
      $getCovError .= $stdErr;
      $getCovStatus = $FALSE;
    }
  }
  $cmdObj->close();
  my $returnHRef = (
                    {
                      status => $getCovStatus,
                      data   => $getCovData,
                      error  => $getCovError,
                    }
                   );

  my $getCovData_End      = Time::HiRes::time();
  my $getCovData_Duration = $getCovData_End - $getCovData_Start;
  $loggerMain->debug( '$getCovData_Duration = ', $getCovData_Duration );

  return $returnHRef;
}

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

sub checkRESTError
{
  my $errNum = $g_cqObject->error();
  my $errMsg;
  $errMsg = $g_cqObject->errmsg() unless( $errNum == $REST_OK );
  return $errNum, $errMsg;
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

sub getPwValues
{
  my $file = shift;
  my $conf = Config::General->new( $file );
  my %hash = $conf->getall;
  return \%hash;
}

__END__

=pod

=head1 NAME

cov2CQEscalate.pl

=head1 SYNOPSIS

Perl script to query Coverity for defects, create/updata CQ records, update Coverity with CQ information

=head1 USAGE

Run cov2CQEscalate.pl from the command-line (NOTE:script is intended to run periodically from crontab; see OPTIONS):

"Usage: $script -customer 'Customer Name' -covhost 'emsscm-coverity|mpsscm-coverity' -covproject 'Coverity project' -covpid 'Coverity project ID' -covstream 'Coverity stream'
                -covstatus 'Coverity defect status' -covclass 'Coverity defect classification' -cqproject 'Clearquest project' -cqplatform 'Clearquest platform'
               [-critical] [-test] [-loglevel 'DEBUG|INFO|WARN|ERROR|FATAL' ] [-logonly] [-h|?|help]";

Optional switches are bracketed, []. When not present, the script will use appropriate default values.

-critical : selects only Coverity Major and Moderate Defect records. Minor Defect records are not processed. When not
            present on the command line all Coverity Defects will be processed.

-test     : limits the number of Defect records processed to the value set in the XML configuration file.

-loglevel : defines log messages that will be displayed (if -test is set) and/or printed. Debug log statements one of the keyword routines.
            If the -loglevel keyword is higher in the priority list than the log statement, the statement wil not be executed.

            log levels:

            FATAL < highest
            ERROR
            WARN
            INFO
            DEBUG < lowest

EXAMPLES:
./cov2CQEscalate.pl -customer Samsung -covhost mpsscm-coverity -covproject AP-sdb-common-android-jb-4.2 -covstream AP-sdb-common-android-jb-4.2-android_hawaii_edn010
                    -covpid 10002 -cqproject Hawaii -cqplatform HawaiiStone -covstatus Triaged -covclass Bug -critical -test -loglevel INFO

./cov2CQEscalate.pl  -customer Samsung -covhost mpsscm-coverity -covproject AP-JAVA-sdb-common-android-jb-4.2 -covstream AP-JAVA-sdb-common-android-jb-4.2-android_hawaii_edn010
                     -covpid 10003 -cqproject Hawaii -cqplatform HawaiiStone -covstatus Triaged -covclass Bug -critical -test -loglevel INFO

=head1 REQUIRED ARGUMENTS

=head1 OPTIONS

The following are crontab command line entries that have been used to test the script and execute it for production:

# logonly - no db access
# 45 15 25 3 * rsh xserver.sj.broadcom.com "/tools/bin/bsub -o '/projects/mobcom_andrwks_ext7_scratch/users/mcsi_user/logs/cov2CQ_bsub.log' -q sj-mob-android '/projects/mob_tools/coverity/test/cov2CQEscalate.pl -customer Samsung -covhost mpsscm-coverity -covproject AP-sdb-common-android-jb-4.2.2 -covstream AP-sdb-common-android-jb-4.2.2-android_hawaii_edn010 -covpid 10009 -covstatus Triaged -covclass Bug -cqproject Hawaii -cqplatform HawaiiStone -critical -loglevel DEBUG -cqdatabase t_sbx -test -logonly'"
# 20 14 27 3 * rsh xserver.sj.broadcom.com "/tools/bin/bsub -o '/projects/mobcom_andrwks_ext7_scratch/users/mcsi_user/logs/cov2CQ_JAVA_bsub.log' -q sj-mob-android '/projects/mob_tools/coverity/test/cov2CQEscalate.pl -customer Samsung -covhost mpsscm-coverity -covproject AP-JAVA-sdb-common-android-jb-4.2.2 -covstream AP-JAVA-sdb-common-android-jb-4.2.2-android_hawaii_edn010 -covpid 10010 -covstatus Triaged -covclass Bug -cqproject Hawaii -cqplatform HawaiiStone -critical -loglevel DEBUG -cqdatabase t_sbx -test -logonly'"

# test - use t_sbx and limit number of records processed
# 45 15 25 3 * rsh xserver.sj.broadcom.com "/tools/bin/bsub -o '/projects/mobcom_andrwks_ext7_scratch/users/mcsi_user/logs/cov2CQ_bsub.log' -q sj-mob-android '/projects/mob_tools/coverity/test/cov2CQEscalate.pl -customer Samsung -covhost mpsscm-coverity -covproject AP-sdb-common-android-jb-4.2.2 -covstream AP-sdb-common-android-jb-4.2.2-android_hawaii_edn010 -covpid 10009 -covstatus Triaged -covclass Bug -cqproject Hawaii -cqplatform HawaiiStone -critical -loglevel DEBUG -cqdatabase t_sbx -test'"
# 25 15 26 3 * rsh xserver.sj.broadcom.com "/tools/bin/bsub -o '/projects/mobcom_andrwks_ext7_scratch/users/mcsi_user/logs/cov2CQ_JAVA_bsub.log' -q sj-mob-android '/projects/mob_tools/coverity/test/cov2CQEscalate.pl -customer Samsung -covhost mpsscm-coverity -covproject AP-JAVA-sdb-common-android-jb-4.2.2 -covstream AP-JAVA-sdb-common-android-jb-4.2.2-android_hawaii_edn010 -covpid 10010 -covstatus Triaged -covclass Bug -cqproject Hawaii -cqplatform HawaiiStone -critical -loglevel DEBUG -cqdatabase t_sbx -test'"

# production - use MobC and no record limit
# 35 23 * * * rsh xserver.sj.broadcom.com "/tools/bin/bsub -o '/projects/mobcom_andrwks_ext7_scratch/users/mcsi_user/logs/cov2CQ_bsub.log' -q sj-mob-android '/projects/mob_tools/coverity/cq_bridge/cov2CQEscalate.pl -customer Samsung -covhost mpsscm-coverity -covproject AP-sdb-common-android-jb-4.2.2 -covstream AP-sdb-common-android-jb-4.2.2-android_hawaii_edn010 -covpid 10009 -covstatus Triaged -covclass Bug -cqproject Hawaii -cqplatform HawaiiStone -critical -loglevel INFO -cqdatabase MobC'"
# 30 23 * * * rsh xserver.sj.broadcom.com "/tools/bin/bsub -o '/projects/mobcom_andrwks_ext7_scratch/users/mcsi_user/logs/cov2CQ_JAVA_bsub.log' -q sj-mob-android '/projects/mob_tools/coverity/cq_bridge/cov2CQEscalate.pl -customer Samsung -covhost mpsscm-coverity -covproject AP-JAVA-sdb-common-android-jb-4.2.2 -covstream AP-JAVA-sdb-common-android-jb-4.2.2-android_hawaii_edn010 -covpid 10010 -covstatus Triaged -covclass Bug -cqproject Hawaii -cqplatform HawaiiStone -critical -loglevel INFO -cqdatabase MobC'"


=head1 DIAGNOSTICS

See -loglevel command line option under USAGE

=head1 EXIT STATUS

Exits with 0 for non-error executuion.
Error conditions within the script will cause it to Croak at the point of failure.

=head1 CONFIGURATION

Configuration file is ...


=head1 DEPENDENCIES

See the Perl 'use' list at the top of the script.

In particular cov2CQEscalate.pl is designed to use:
Clearquest::REST

=head1 INCOMPATIBILITIES

cov2CQEscalate.pl is intended to run in a Linux environment.

=head1 DESCRIPTION

=over 2

=item 1. reproduce original shell (.sh) and Perl (.pl) scripts functionality for Coverity 6.5.1.

=item 2. use stateless records in CQ dB for:

=over 1

=item a. cq severity

=item b. cq priority

=item c. coverity severity

=item d. tbd

=back

=item 3. ignore specific build directories for analysis

=over 1

=item a. implemented via %ignoredDirectories

=back

=item 4. use CQ categoy type for specific build directories

=over 1

=item a. implemented via %categoryTypesPath

=back

=back

=head1 SEE ALSO

 Coverity Project ID's are found on the Coverity Connect Quality Advisor page
         http://mpsscm-coverity.broadcom.com:8080/reports.htm#dQUALITY/p10002
 Select Projects pull-down and select Project Name for the url   >>>>>  ^^^^^
   NOTE: ID is only the numeric part


=head1 AUTHOR

Dennis Sass, E<lt>dsass@broadcom.com<gt>

=head1 BUGS AND LIMITATIONS

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2013 by Broadcom, Inc.

<License TBD>

=cut
