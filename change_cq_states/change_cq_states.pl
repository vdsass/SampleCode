#!/usr/ba/bin/perl
###############################################################################
# change_cq_states.pl
# CQ Integrated State Change via Electric Commander
#
# On a Unix machine ( xl or lc(Citrix) )
# compile: -> baperl -c change_cq_states.pl
# run:     -> change_cq_states.pl
#             or
#          -> change_cq_states.pl > ../logs/change_cq_states.log 2>&1
#
# Hybrid Manifest requirements:
#   Use only GIT log to get the list of CQs
#   Support Hybrid manifest
#   Have provision to integrate AP or CP or both CQs
#   Generate CQ commit list.
#
# see perldoc after __END__
#
###############################################################################
use strict;
use warnings;

use threads;

use Getopt::Long;

use lib "/projects/mobcom_andrwks/users/dsass/clone/Clearquest/lib";
use lib "/projects/mobcom_andrwks/users/dsass/clone/Clearquest/etc";

use Clearquest;

use Utils;
use DateTime;

use Cwd;
use Carp;

use FindBin;

use Data::Dumper::Simple;
use Log::Log4perl qw( get_logger :levels );

use Env;
use Sys::CPU;

use Email::Stuff;

use Excel::Writer::XLSX;

use XML::Simple;

use XML::LibXML;

use File::Path qw(make_path remove_tree);
use utf8;

use Readonly;
Readonly::Scalar my $FALSE        => 0;
Readonly::Scalar my $MAX_THREADS  => Sys::CPU::cpu_count();
Readonly::Scalar my $MAX_RETRIES  => 5; # in case of timeout
Readonly::Scalar my $MAX_ERRORS   => 5;
Readonly::Scalar my $REST_OK      => 0;
Readonly::Scalar my $SLEEP_VALUE  => 5; # seconds
Readonly::Scalar my $TRUE         => 1;

Readonly::Scalar my $GIT_URIS_SEARCH  => 'ssh://mobcomgit@mobcom-git.sj.corp.com';
Readonly::Scalar my $GIT_URIS_REPLACE => '/projects/mobcom_andrgit/scm';
Readonly::Scalar my $REPOS_PATH       => '/projects/mobcom_andrgit/scm/git_repos/mpg_manifests/manifest.git';

Readonly::Scalar my $excelDirectory   => '/projects/mobcom_andrwks/users/dsass/MPGSWCM-1222/perl/logs/';

# testing parameters
#
Readonly::Scalar my $REPO_LOOPCOUNT => 10000; # for test limiting

# for a given state indicates next state in process flow
#                                CURRENT STATE   NEXT STATE
Readonly::Hash my %states =>  (
                                Submitted   => 'Assigned',
                                Assigned    => 'Opened',
                                Opened      => 'Implemented',
                                Implemented => 'Integrated',
                                Integrated  => 'Integrated', # Integrated does not change state
                                Verified    => 'Verified',   # Verified does not change state
                                Closed      => 'Closed',     # Closed does not change state
                                Duplicated  => 'Integrated',
                                Feedback    => 'Feedback',   # Feedback does not change state
                                Rejected    => 'Rejected',   # Rejected does not change state
                                Suspended   => 'Suspended',  # Suspended does not change state
                              );

# for a given state indicates Action to move Defect record to next state in process flow
#                                 STATE         ACTION
Readonly::Hash my %actions => (
                                Submitted   => 'Assign',
                                Assigned    => 'Open',
                                Opened      => 'Implementation_Complete',
                                Implemented => 'Integrate',
                                Integrated  => 'Modify',    # Integrated_In_Version field is updated
                                Verified    => 'Modify',    # Integrated_In_Version field is updated
                                Closed      => 'Modify',    # Integrated_In_Version field is updated
                                Duplicated  => 'Integrate',
                                Feedback    => 'Modify',    # Feedback does not change state
                                Rejected    => 'Modify',    # Rejected does not change state
                                Suspended   => 'Modify',    # Suspended does not change state
                              );

local $| = 1;
my( $script ) = $FindBin::Script =~ /(^.+?)\.pl$/x;
print "$script ", __LINE__, ' : $Sys::Hostname::hostname = ', hostname, "\n";

$XML::LibXML::Error::WARNINGS = 1;

# determine testing parameter
#
#my $COMMAND_LINE;
#
#if( $ARGV[0] and $ARGV[0] =~ /cl/ix )
#{
#  print $script, ' ', __LINE__, ' $ARGV[0] = ', $ARGV[0], "Using pre-defined parameters\n";
#  $COMMAND_LINE = $TRUE;
#}
#else
#{
#  print "No valid command-line argument. Using Electric Commander.\n";
#  $COMMAND_LINE = $FALSE;
#}

# EC procedure command:
#
# /projects/mobcom_andrwks/users/dsass/MPGSWCM-1222/perl/change_cq_states.pl
# /projects/mobcom_andrwks/users/dsass/MPGSWCM-1222/perl/change_cq_states.pl --apcp $[AP_CP] --cqproj $[CQ_PROJECT] --manifest $[MANIFEST] --newtag $[NEW_TAG_NAME] --oldtag $[OLD_TAG_NAME] --nonexecmode $[NONEXEC_MODE] --outputpath $[OUTPUT_PATH]

my %threadHash;

my( $AP_CP, $EC, $oldTag, $newTag, $CQProject, $manifest, $nonExecMode, $output_path);

my $result = GetOptions ("apcp=s"        => \$AP_CP,
                         "cqproj=s"      => \$CQProject,
                         "oldtag=s"      => \$oldTag,
                         "newtag=s"      => \$newTag,
                         "manifest=s"    => \$manifest,
                         "outputpath=s"  => \$output_path,
                         "nonexecmode=s" => \$nonExecMode);

$output_path = ' ' unless $output_path;

# Excel summary data
#
my %statistics = (
                  successes  => 0,
                  duplicates => 0,
                  exceptions => 0,
                  retries    => 0,
                  );

# container for exceptions
#
my @xCqId;

my $debugTrace                  = 1;
my $debugTrace_Level_0          = 0;

my $debugTiming                 = 0;

my $debugMain                   = 1;
my $debugMain_Level_0           = 0;

my $debugParameters             = 0;
my $debugFindOrAddVersionRecord = 0;
my $debugfindDefectRecord       = 0;
my $debugChangeDefectState      = 1;
my $debugDoAction               = 1;
my $debugModify                 = 1; # trace 'modify' call within doAction
my $debugP4CQIDList             = 0;
my $debugGetCQs                 = 1;
my $debugUpdateIiv              = 0;
my $debugRestError              = 0;
my $debugGetInfoFromEc          = 0;
my $debugGetWorkingSetPath      = 0;

my $debugProcessRecords          = 0;
my $debugProcessCommittedRecords = 0;
my $debugProcessCommittedImplementedRecords = 0;

my $debugUpdateModifiedCQIDsHash = 0;
my $debugGitBareRepoCQIDs        = 0;
my $debugCreateWorkingDir        = 0;
my $debugcommittedCqIDHash       = 0;
my $debugGetEquivalentCQIDs      = 0;
my $debugfindRecords             = 0;
my $debugMergeHashes             = 0;
my $debugGetExcelData            = 1;
my $debugGetCommittedAndImplementedCQIDs = 0;


my $doActionCount               = 0; # track number of actions performed

my %cqIdsProcessed;  # hash to collect modified records + action(s)
my %xCqIdsProcessed; # hash to collect exception records

# for Projects data WRT SW Leads
#
my $projectsXMLFile = '/projects/mobcom_andrwks/users/dsass/MPGSWCM-1222/perl/users/projectLeads.xml';
my $logDirectory    = '/projects/mobcom_andrwks/users/dsass/MPGSWCM-1222/perl/logs/';

Log::Log4perl::init( loggerInit( $logDirectory ) );

my $loggerMain_LogLevel                         = $INFO;
my $getExcelData_LogLevel                       = $INFO;
my $checkRESTError_LogLevel                     = $INFO;
my $doAction_LogLevel                           = $INFO;
my $findOrAddVersionRecord_LogLevel             = $INFO;
my $processCommittedImplementedRecords_LogLevel = $INFO;
my $processCommittedRecords_LogLevel            = $INFO;
my $findRecords_LogLevel                        = $INFO;
my $changeDefectState_LogLevel                  = $INFO;
my $updateIiv_LogLevel                          = $INFO;
my $validateAssignee_LogLevel                   = $INFO;
my $getReposFromManifest_LogLevel               = $INFO;

my $excelDataHashRef;

my $loggerMain = get_logger( $script );
   $loggerMain->level( $loggerMain_LogLevel );

$loggerMain->info( '$Clearquest::VERSION = ', $Clearquest::VERSION );
$loggerMain->info( '$MAX_THREADS         = ', $MAX_THREADS );

my $cqIdPrefix = 'MobC';
my @RESPONSE;
my $SUCCESSFUL = 1;

my %dbparams = ( CQ_MODULE   => 'rest', );
my $cq = Clearquest->new( %dbparams );
$cq->connect()
  or croak "CROAK! Cannot connect to cq database.\n";

# EC parameters
#
my @INPUT_FIELDS = qw(
                        AP_CP
                        CQ_PROJECT
                        MANIFEST
                        NEW_TAG_NAME
                        NONEXEC_MODE
                        OLD_TAG_NAME
                        OUTPUT_PATH
                     );

my @tags;
my %REMOTES;
my %INPUT_VALUES;

#if( $COMMAND_LINE == $TRUE )
#{
#  $loggerMain->debug( "Running from the command-line..." );
#
#  # 20130110 Test Case 1:
#  #
#  #
#  #Name Value
#  #CL_NUMBER 475433
#  #COMMIT_ID 1ca486540128607c8818f07a1393682113b79839
#  #COMMIT_REPO_PATH repo_msp/modem/capri
#  #CP_TEMPLATE_CLIENTSPEC TEMPLATE_CapriSDB
#  #CQ_PROJECT Capri
#  #DISABLE_MANIFEST_CHECK 1
#  #MANIFEST sdb-common-android-jb
#  #MANIFEST_COMMITID
#  #NEW_TAG_NAME MP_1.1.2_BCM28155_SystemRel_3.2.8.1
#  #NONEXEC_MODE 0
#  #OLD_TAG_NAME MP_1.1.1_BCM28155_SystemRel_3.2.8
#  #USER_NAME kamrun, abhutani
#
#  $CQProject   = 'Capri';
#  $manifest    = 'sdb-common-android-jb';
#  $oldTag      = 'MP_1.1.1_BCM28155_SystemRel_3.2.8';
#  $newTag      = 'MP_1.1.2_BCM28155_SystemRel_3.2.8.1';
#
#  # 20130110 Test Case 2:
#  #
#  #
#  #CL_NUMBER 476492
#  #COMMIT_ID 80a1699c76a058be038a43e25812ce1679df7fee
#  #COMMIT_REPO_PATH repo_lmp/kernel/linux-hawaii
#  #CP_TEMPLATE_CLIENTSPEC TEMPLATE_CapriSDB
#  #CQ_PROJECT Capri
#  #DISABLE_MANIFEST_CHECK 0
#  #MANIFEST sdb-common-android-jb-4.2
#  #MANIFEST_COMMITID 3d5d27958d974fd3a057b378bee5f0354497eb49
#  #NEW_TAG_NAME MP_2.2.0_BCM28155_SystemRel_4.2.5
#  #NONEXEC_MODE 0
#  #OLD_TAG_NAME MP_2.51.0_BCM28155_SystemRel_4.2.4
#  #USER_NAME abhutani, kamrun
#
#  #$CQProject   = 'Capri';
#  #$manifest    = 'sdb-common-android-jb-4.2';
#  #$oldTag      = 'MP_2.51.0_BCM28155_SystemRel_4.2.4';
#  #$newTag      = 'MP_2.2.0_BCM28155_SystemRel_4.2.5';
#
#  # 20130110 Test Case 3:
#  #
#  #CL_NUMBER 476234
#  #COMMIT_ID 344d24cf33387da627d61aae165aee35de72a4ff
#  #COMMIT_REPO_PATH repo_msp/modem/capri
#  #CP_TEMPLATE_CLIENTSPEC TEMPLATE_RheaSDB
#  #CQ_PROJECT RheaROW
#  #DISABLE_MANIFEST_CHECK 1
#  #MANIFEST sdb-common-android-jb
#  #MANIFEST_COMMITID 044a937b162a009049312bf58e2e18ea138ad250
#  #NEW_TAG_NAME MP_1.2.0_BCM21654ROW_SystemRel_2.2.23
#  #NONEXEC_MODE 0
#  #OLD_TAG_NAME MP_1.1.0_BCM21654ROW_SystemRel_2.2.22
#  #USER_NAME vadapala
#
#  #$CQProject   = 'RheaROW';
#  #$manifest    = 'sdb-common-android-jb';
#  #$oldTag      = 'MP_1.1.0_BCM21654ROW_SystemRel_2.2.22';
#  #$newTag      = 'MP_1.2.0_BCM21654ROW_SystemRel_2.2.23';
#
#  # 20130110 Test Case 4:
#  #
#  #CL_NUMBER 475446
#  #COMMIT_ID 344f14513c53ffd5df1f92002b7fd189a694bd8e
#  #COMMIT_REPO_PATH repo_tools/scripts
#  #CP_TEMPLATE_CLIENTSPEC TEMPLATE_RheaSDB
#  #CQ_PROJECT RheaROW
#  #DISABLE_MANIFEST_CHECK 1
#  #MANIFEST sdb-common-android-jb-4.2
#  #MANIFEST_COMMITID 6d9e5202e3cb73f1ec830f00c95eb0ef5e68db6f
#  #NEW_TAG_NAME MP_2.1.0_BCM21654ROW_SystemRel_3.0.5
#  #NONEXEC_MODE 0
#  #OLD_TAG_NAME MP_2.51.0_BCM21654ROW_SystemRel_3.0.4
#  #USER_NAME vadapala
#
#  #$CQProject   = 'RheaROW';
#  #$manifest    = 'sdb-common-android-jb-4.2';
#  #$oldTag      = 'MP_2.51.0_BCM21654ROW_SystemRel_3.0.4';
#  #$newTag      = 'MP_2.1.0_BCM21654ROW_SystemRel_3.0.5';
#
#  #Try these New and Old tag sets
#  #
#  #MultiPlatform_1.46.1_BCM28155_SystemRel_3.2.1
#  #MultiPlatform_1.45.2_BCM28155_SystemRel_3.0.15.1
#  #
#  #
#  #MultiPlatform_1.45.2_BCM28155_SystemRel_3.0.15.1
#  #MultiPlatform_1.45.1_BCM28155_SystemRel_3.0.15
#
#  # 20130111 Test Case 5:
#  #  3.2.1
#  #AP Release Info AP Release Tag in GIT:  MultiPlatform_1.46.1_BCM28155_SystemRel_3.2.1
#  #Until Commit: # f2ea739 in repo_lmp/kernel/linux-hawaii
#  #Release Documents
#  #GIT Manifest:  sdb-common-android-jb #
#  #GIT Mainline Dev Branch:  sdb-common-android-jb
#  #CP Release Info  CP Release Label in P4:  MultiPlatform_1.46.1_BCM28155_SystemRel_3.2.1 (based on CL 460742)
#  #P4 Release Client-Spec Name:  //spec/client/TEMPLATE_CapriSDB.p4s
#  #P4 Mainline Dev Branch:  //depot/Sources/SystemDevelopment/Capri/msp/...
#  #Release Location(s)  IRVINE
#  #BRACKNELL-UK
#
#  #$CQProject   = 'Capri';
#  #$manifest    = 'sdb-common-android-jb';
#  #$oldTag      = 'MultiPlatform_1.45.2_BCM28155_SystemRel_3.0.15.1';
#  #$newTag      = 'MultiPlatform_1.46.1_BCM28155_SystemRel_3.2.1';
#
#  # 20130111 Test Case 6
#  #3.0.15.1
#  #AP Release Info AP Release Tag in GIT:  MultiPlatform_1.45.2_BCM28155_SystemRel_3.0.15.1
#  #Until Commit: # e7a7a93 in repo_msp/modem/rhea
#  #Release Documents
#  #GIT Manifest:  sdb-common-android-jb #f681be5
#  #GIT Mainline Dev Branch:  sdb-common-android-jb
#  #CP Release Info  CP Release Label in P4:  MultiPlatform_1.45.2_BCM28155_SystemRel_3.0.15.1 (based on CL 460217)
#  #P4 Release Client-Spec Name:  //spec/client/TEMPLATE_CapriSDB.p4s
#  #P4 Mainline Dev Branch:  //depot/Sources/SystemDevelopment/Capri/msp/...
#  #Release Location(s)  IRVINE
#  #BRACKNELL-UK
#
#  #$CQProject   = 'Capri';
#  #$manifest    = 'sdb-common-android-jb';
#  #$oldTag      = 'MultiPlatform_1.45.1_BCM28155_SystemRel_3.0.15';
#  #$newTag      = 'MultiPlatform_1.45.2_BCM28155_SystemRel_3.0.15.1';
#
#  # 20130111 Test Case 7
#  #  3.0.15
#  #AP Release Info AP Release Tag in GIT:  MultiPlatform_1.45.1_BCM28155_SystemRel_3.0.15
#  #Until Commit: # aea2191 in repo_aosp/platform/hardware/libhardware
#  #Release Documents
#  #GIT Manifest:  sdb-common-android-jb #67144fa
#  #GIT Mainline Dev Branch:  sdb-common-android-jb
#  #CP Release Info  CP Release Label in P4:  MultiPlatform_1.45.1_BCM28155_SystemRel_3.0.15 (based on CL 459688)
#  #P4 Release Client-Spec Name:  //spec/client/TEMPLATE_CapriSDB.p4s
#  #P4 Mainline Dev Branch:  //depot/Sources/SystemDevelopment/Capri/msp/...
#  #Release Location(s)  IRVINE
#  #BRACKNELL-UK
#
#  #$CQProject   = 'Capri';
#  #$manifest    = 'sdb-common-android-jb';
#  #$oldTag      = '';
#  #$newTag      = 'MultiPlatform_1.45.1_BCM28155_SystemRel_3.0.15';
#
#
#  $AP_CP       = 'APCP';
#
#  $output_path = ' ';
#  $nonExecMode = 1;                      # 0=> update CQdB; 1=> do not update CQdB
#
#}
#else
#{
#  $loggerMain->debug( "Running from Electric Commander..." );
#
#  # open ec connection; global $EC will contain objectRef
#  #
#  $loggerMain->debug( "opening an EC connection..." );
#
#  open_ec_connection();
#
#  # get information from EC; global $EC will contain objectRef
#  #
#  $loggerMain->debug( "getting input from EC..." );
#
#  get_info_from_ec();
#
#  $loggerMain->debug( Dumper( @INPUT_FIELDS ) );
#  $loggerMain->debug( Dumper( %INPUT_VALUES ) );
#
#  $AP_CP       = trimWhitespace( $INPUT_VALUES{ AP_CP        } );
#  $CQProject   = trimWhitespace( $INPUT_VALUES{ CQ_PROJECT   } );
#  $oldTag      = trimWhitespace( $INPUT_VALUES{ OLD_TAG_NAME } );
#  $newTag      = trimWhitespace( $INPUT_VALUES{ NEW_TAG_NAME } );
#
#  $manifest    = trimWhitespace( $INPUT_VALUES{ MANIFEST     } );
#
#  $output_path = trimWhitespace( $INPUT_VALUES{ OUTPUT_PATH  } );
#  $nonExecMode = trimWhitespace( $INPUT_VALUES{ NONEXEC_MODE } ); # for testing; CQdB is not updated if set
#
#}


#convert to unix path
#
$output_path =~ s-\\\\-\\-g;
$output_path =~ s-^.*\\projects-/projects-;
$output_path =~ s-\\-/-g;


# initialize excel

my $timeFormatsRef   = getDate_Time( time );
my $today_mm_dd_yyyy = $timeFormatsRef->[2];

system( "rm -f ${excelDirectory}${newTag}_Integrated_CQs.xlsx" ) if( -e $excelDirectory . $newTag.'_Integrated_CQs.xlsx' );

my $integratedCQwb  = Excel::Writer::XLSX->new( $excelDirectory . $newTag . '_Integrated_CQs.xlsx' );
my $wsD             = $integratedCQwb->add_worksheet( 'ClearQuest_Defects' );

###############################################################################
# Add a handler to store the width of the longest string written to a column.
# ...Use the stored width to simulate autofit of the column widths.
# Do this for every worksheet you want to autofit.
#
$wsD->add_write_handler(qr[\w]x, \&store_string_widths);

# Excel row/col indices; cell formats
#
my $titleRow              = 0;
my $titleCol              = 0;

my $titleCol_Start        = 0;
my $titleCol_End          = 8; # zero offset

my $titleRowHeight        = 20;

my $summaryHeaderRow      = $titleRow + 2;
my $summaryHeaderHeight   = 20;
my $summaryHeaderCol      = 0;

my $summaryDataRow        = $summaryHeaderRow + 1;
my $summaryDataRowHeight  = 15;
my $summaryDataCol        = 0;

my $headerRow             = $summaryHeaderRow + 7;

my $headerCol_Start       = 0;
my $headerCol_End         = 8; # zero offset
my $headerCol             = 0;

my $headerHeight          = 20;

my $dataRow               = $headerRow + 1;  # start row
my $dataCol               = 0;               # start col
my $dataRowHeight         = 15;

# Excel worksheet formats
#
my $summary_header_format = $integratedCQwb->add_format( align  => 'center',
                                                     valign => 'vcenter',
                                                     bg_color => 'black',
                                                     color  => 'white',
                                                     font   => 'Arial',
                                                     size   => '12',
                                                     bold   => 1,
                                                     border => 1,
                                                   );

my $center_cell_format = $integratedCQwb->add_format( align  => 'center',
                                                  valign => 'vcenter',
                                                  color  => 'black',
                                                  font   => 'Arial',
                                                  size   => '10',
                                                  bold   => 0,
                                                  border => 1,
                                                );

my $url_link_format    = $integratedCQwb->add_format( align  => 'center',
                                                  valign => 'vcenter',
                                                  color  => 'blue',
                                                  underline => 1,
                                                  font   => 'Arial',
                                                  size   => '10',
                                                  bold   => 0,
                                                  border => 1,
                                                );

my $left_cell_format = $integratedCQwb->add_format( align  => 'left',
                                                valign => 'vcenter',
                                                color  => 'black',
                                                font   => 'Arial',
                                                size   => '10',
                                                bold   => 0,
                                                border => 1,
                                              );

my $right_cell_format = $integratedCQwb->add_format( align  => 'right',
                                                 valign => 'vcenter',
                                                 color  => 'black',
                                                 font   => 'Arial',
                                                 size   => '10',
                                                 bold   => 0,
                                                 border => 1,
                                               );

my $left_cell_wrap_format = $integratedCQwb->add_format( align     => 'left',
                                                     valign    => 'vjustify', # doc claims this will auto-wrap
                                                     text_wrap => 1,
                                                     color     => 'black',
                                                     font      => 'Arial',
                                                     size      => '10',
                                                     bold      => 0,
                                                     border    => 1,
                                                   );

my $genericHeadingFormat = $integratedCQwb->add_format( align    => 'center',
                                                    valign   => 'vcenter',
                                                    bg_color => 'green',
                                                    color    => 'white',
                                                    font     => 'Arial',
                                                    size     => '12',
                                                    bold     => 1,
                                                    border   => 1,
                                                   );

my $cqIDHeadingFormat = $integratedCQwb->add_format( align    => 'center',
                                                 valign   => 'vcenter',
                                                 bg_color => 'yellow',
                                                 color    => 'blue',
                                                 font     => 'Arial',
                                                 size     => '12',
                                                 bold     => 1,
                                                 border   => 1,
                                               );

my $dataRowFormat = $integratedCQwb->add_format( align  => 'center',
                                             valign => 'vcenter',
                                             color  => 'black',
                                             font   => 'Arial',
                                             size   => '10',
                                             bold   => 0,
                                           );

my $titleFormat   = $integratedCQwb->add_format( align  => 'left',
                                             valign => 'vcenter',
                                             color  => 'black',
                                             font   => 'Arial',
                                             size   => '16',
                                             bold   => 1,
                                             border => 0,
                                           );

# define summary header formats
#
$wsD->set_row( $summaryHeaderRow, $summaryHeaderHeight );

# create summary header text with individual cell format
#
$wsD->write( $summaryHeaderRow,   $summaryHeaderCol,     'Summary', $summary_header_format );
$wsD->write( $summaryHeaderRow,   $summaryHeaderCol + 1, 'Count',   $summary_header_format );

$wsD->write( $summaryDataRow,     $summaryDataCol, 'Successes',  $left_cell_format );
$wsD->write( $summaryDataRow + 1, $summaryDataCol, 'Duplicates', $left_cell_format );
$wsD->write( $summaryDataRow + 2, $summaryDataCol, 'Exceptions', $left_cell_format );

# define header formats
#           set_row($row, $height, $format, $hidden, $level, $collapsed)
#
$wsD->set_row( $headerRow, $headerHeight );

# create header text with individual cell format
#
$wsD->write( $headerRow, $headerCol,     'CQID', $cqIDHeadingFormat );
$wsD->write( $headerRow, $headerCol + 1, 'State', $genericHeadingFormat );
$wsD->write( $headerRow, $headerCol + 2, 'Integrated_In_Versions', $genericHeadingFormat );
$wsD->write( $headerRow, $headerCol + 3, 'Project', $genericHeadingFormat );
$wsD->write( $headerRow, $headerCol + 4, 'Platform', $genericHeadingFormat );
$wsD->write( $headerRow, $headerCol + 5, 'Approved_By_CCB', $genericHeadingFormat );
$wsD->write( $headerRow, $headerCol + 6, 'IMS_Case_ID', $genericHeadingFormat );
$wsD->write( $headerRow, $headerCol + 7, 'Title', $genericHeadingFormat );
$wsD->write( $headerRow, $headerCol + 8, 'Entry_Type', $genericHeadingFormat );

# end initialize Excel

# open files for data collection
#
my $changeStateCQsFileName = $logDirectory . $newTag . '_changeStateCQsList.log';
open( my $changeStateCQs, '>', $changeStateCQsFileName )
  or croak( "Cannot open file $changeStateCQsFileName: $!" );

my $fixedCQsFileName = $logDirectory . $newTag . '_fixedCQsList.log';
open( my $fixedCQs, '>', $fixedCQsFileName )
  or croak( "Cannot open file $fixedCQsFileName: $!" );

my $otherCQsFileName = $logDirectory . $newTag . '_otherCQsList.log';
open( my $otherCQs, '>', $otherCQsFileName )
  or croak( "Cannot open file $otherCQsFileName: $!" );

my $examineTheseCQsFileName = $logDirectory . $newTag . '_examineTheseCQsList.log';
open( my $examineTheseCQs, '>', $examineTheseCQsFileName )
  or croak( "Cannot open file $examineTheseCQsFileName: $!" );


# get Project Lead + email data
#   in case Assignee is no longer an employee
#     create [global] reference var for assignee validation
#
my $parser = XML::LibXML->new();
my $projectsDoc;

eval{ $projectsDoc = $parser->parse_file( $projectsXMLFile ) };

if( ref( $@ ) )
{
  # handle a structured error (XML::LibXML::Error object)
  #
  $loggerMain->fatal( 'Handled a structured error (XML::LibXML::Error object)' );

  my $error_domain = $@->domain();
  $loggerMain->error( '$error_domain = ', $error_domain );

  my $error_code = $@->code();
  $loggerMain->error( '$error_code = ', $error_code );

  my $error_message = $@->message();
  $loggerMain->error( '$error_message = ', $error_message );

  my $error_level = $@->level();
  $loggerMain->error( '$error_level = ', $error_level );

  my $filename = $@->file();
  $loggerMain->error( '$filename = ', $filename );

  my $line = $@->line();
  $loggerMain->error( '$line = ', $line );

  my $fullMessage = $@->as_string();
  $loggerMain->error( '$fullMessage = ', $fullMessage );

  exit 1;

}
elsif( $@ )
{
  # error, but not an XML::LibXML::Error object
  $loggerMain->fatal( 'eval error, but not an XML::LibXML::Error object' );

  exit 1;

}
else
{
  $loggerMain->debug( 'No eval error' );
}

my $projectDataRef = getProjectData( $projectsDoc );
my $workingPath    = getWorkingSetPath();

$loggerMain->info( '$CQProject     = ', $CQProject );

$loggerMain->info( '$manifest      = ', $manifest );

$loggerMain->info( '$oldTag        = ', $oldTag );
$loggerMain->info( '$newTag        = ', $newTag );

$loggerMain->info( '$workingPath   = ', $workingPath );
$loggerMain->info( '$output_path   = ', $output_path );


################################################################################
# STEP 1: test existence of Version; create if necessary
#
# verify or create CQ dB version record
#
my @params = qw( VersionStr Projects );
findOrAddVersionRecord( "VersionInfo", $newTag, $CQProject, @params );

################################################################################
# List1:
# This is a Hybrid Build System (HBS) - there is no distinction between AP/CP
#   get a list of [all] CQ commits
#
# The rest will be flagged for review, this includes
# a. CQs in List2 but not in List1
# b. Commits between 2 tags that don't have a CQ associated with it
#
################################################################################

# $reposHRef contains remote,
#                     default and
#                     project data as hash of hashes
#
my $reposHRef = getReposFromManifest();

# this prints $reposHRef  = HASH(0x98de1a8)
$loggerMain->debug( '$reposHRef  = ', $reposHRef );
# this prints the entire data structure
$loggerMain->debug( Dumper( %$reposHRef ) );

my $defaultRemote   = $reposHRef->{ default }->[0]->{ remote   };
my $defaultRevision = $reposHRef->{ default }->[0]->{ revision };
my $projectArrayRef = $reposHRef->{ project };


################################################################################

# this prints the hash slice for the 'project' key:
#
# @{$reposHRef->{project}} = (
#                              {
#                                'name' => 'repo_lmp/kernel/linux-3.0.15',
#                                'groups' => 'rhea',
#                                'path' => 'kernel/rhea/3.0.15'
#                              },
#                              etc.
#
#$loggerMain->debug( Dumper( @{ $reposHRef->{ project } } ) );


#foreach my $repoHRef( @{ $reposHRef->{ project } } )
#{
#  # this prints $repoHRef  = HASH(0x98de418)
#  $loggerMain->debug( '$repoHRef  = ', $repoHRef );
#
#  # this prints a repo hash as a list, which is the output of the slice:
#  #             %$repoHRef = namerepo_lmp/kernel/linux-3.0.15groupsrheapathkernel/rhea/3.0.15
#  #
#  $loggerMain->debug( '%$repoHRef = ', %$repoHRef );
#
#  # this prints each individual repo hash:
#  #
#  #%$repoHRef = (
#  #               'name' => 'repo_lmp/kernel/linux-3.0.15',
#  #               'groups' => 'rhea',
#  #               'path' => 'kernel/rhea/3.0.15'
#  #             );
#  $loggerMain->debug( Dumper( %$repoHRef ) );
#
#  # this prints each individual repo hash element:
#  #
#  # $repoHRef->{name}   = repo_lmp/kernel/linux-3.0.15
#  # $repoHRef->{groups} = rhea
#  # $repoHRef->{path}   = kernel/rhea/3.0.15
#  #
#  $loggerMain->debug( '$repoHRef->{name}   = ', $repoHRef->{name} );
#  $loggerMain->debug( '$repoHRef->{groups} = ', $repoHRef->{groups} );
#  $loggerMain->debug( '$repoHRef->{path}   = ', $repoHRef->{path} );
#
#}
################################################################################

my @g_dataArray;

my $ap = 0;
my $cp = 0;

$ap = 1 if $AP_CP eq 'AP' or $AP_CP eq 'APCP';
$cp = 1 if $AP_CP eq 'CP' or $AP_CP eq 'APCP';

$loggerMain->debug( '$ap = ', $ap, ' $cp = ', $cp );

my $repoCount = 0;
my $cpPath    = qr{vendor/corp/modem}ix;

my $repoCounter          = 0;
my $processedRepoCounter = 0;

REPOLOOP: for my $repoHashRef( @$projectArrayRef )
{
  $loggerMain->info( '-' x 80 );
  $loggerMain->debug( Dumper( %$repoHashRef ) );
  $loggerMain->info( 'REPOLOOP: $repoHashRef->{ name } = ', $repoHashRef->{ name } );
  $repoCounter++;

  # "CP code is always under vendor/corp/modem.  Rest of the paths have AP code."
  #
  if( $ap && !$cp )
  {
    $loggerMain->info( 'skipping $repoHashRef->{ name } = ', $repoHashRef->{ name } ) if $repoHashRef->{ name } =~ $cpPath;
    next REPOLOOP if $repoHashRef->{ name } =~ $cpPath;
  }
  elsif( !$ap && $cp )
  {
    $loggerMain->info( 'skipping $repoHashRef->{ name } = ', $repoHashRef->{ name } ) if $repoHashRef->{ name } !~ $cpPath;
    next REPOLOOP if $repoHashRef->{ name } !~ $cpPath;
  }
  elsif( $ap && $cp )
  {
    ;
  }
  else
  {
    $loggerMain->fatal( 'Neither $ap or $cp parameters are set!' );
    exit 0;
  }

  $loggerMain->info( 'Processing $repoHashRef->{ name } = ', $repoHashRef->{ name } );
  $processedRepoCounter++;

  # Thread throttling to prevent bogging down the server.  If
  # the maximum amount of threads are running, then wait for at
  # least one to finish.
  #
  while (threads->list(threads::running) > $MAX_THREADS) {
      threads->yield(); # This prevents CPU hogging.
  }

  # Clean up from any finished threads
  #
  my @thr = threads->list(threads::joinable);
  my $threadCount = 0;
  for my $thread( @thr )
  {
    $loggerMain->info( "Joining threads... \$threadCount = ", ++$threadCount );

    my $responseARef = $thread->join();

    $loggerMain->debug( '$responseRef = ', ref( $responseARef ) );

    unless( $responseARef )
    {
      $loggerMain->warn( 'Create loop... $thread->join() $responseARef = ', $responseARef );
      push( @RESPONSE, $responseARef );
      $SUCCESSFUL = 0;
    }
    else
    {
      $loggerMain->debug( 'Create loop... $thread->join() ', Dumper( $responseARef ) );

      # if there's data, update the global container
      #
      my( $threadId, $hashRef ) = @$responseARef;

      $loggerMain->debug( '$threadId = ', $threadId );
      $loggerMain->debug( '$hashRef  = ', $hashRef  );

      push @g_dataArray, $hashRef if( scalar keys %$hashRef );
    }

  } # for $thread

  my $paramHRef = {
                    repohref        => $repoHashRef,
                    defaultremote   => $defaultRemote,
                    defaultrevision => $defaultRevision,
                  };

  my $thd = threads->create( \&processRepo, $paramHRef );

  last REPOLOOP if $repoCount++ > $REPO_LOOPCOUNT;

  $loggerMain->info( '-' x 80 );

} # REPOLOOP


# Wait for all threads to finish before continuing
#
while (threads->list(threads::running)) {
    threads->yield(); # This prevents CPU hogging.
}

my @thr = threads->list(threads::joinable);

my $threadCount = 0;

for my $thread( @thr )
{
  $loggerMain->info( "Joining threads... \$threadCount = ", ++$threadCount );

  my $responseARef = $thread->join();

  unless( $responseARef )
  {
    $loggerMain->warn( 'Near the end... $thread->join() $responseARef = ', $responseARef );
    push( @RESPONSE, $responseARef );
    $SUCCESSFUL = 0;
  }
  else
  {
    $loggerMain->info( 'Near the end... $thread->join() ' );

    # if there's data, update the global container
    #
    my( $threadId, $hashRef ) = @$responseARef;

    $loggerMain->debug( '$threadId = ', $threadId );
    $loggerMain->debug( '$hashRef  = ', $hashRef  );

    push @g_dataArray, $hashRef if( scalar keys %$hashRef );
  }

} # for @thr

if( $SUCCESSFUL )
{
  $loggerMain->info( 'Finished gathering data.' );
}
else
{
  $loggerMain->warn( 'Finished gathering data.  There were errors:', Dumper( @RESPONSE ) );
}

$loggerMain->info( '$repoCounter          = ', $repoCounter );
$loggerMain->info( '$processedRepoCounter = ', $processedRepoCounter );

$loggerMain->debug( Dumper( @g_dataArray ) );

my %committedCqIDHash;
my $committedCqIDHashRef = \%committedCqIDHash;

for my $hashRef( @g_dataArray )
{
  $loggerMain->debug( Dumper( %$hashRef ) );

  for my $commitId( keys %$hashRef )
  {
    my $platform   = $hashRef->{ $commitId }{ platform   };
    my $reponame   = $hashRef->{ $commitId }{ reponame   };
    my $commitTime = $hashRef->{ $commitId }{ committime };

    my $cqIdARef   = $hashRef->{ $commitId }{ cqids      };

    $loggerMain->debug( '$platform = ', $platform );
    $loggerMain->debug( '$reponame = ', $reponame );
    $loggerMain->debug( '$commitTime = ', $commitTime );
    $loggerMain->debug( Dumper( $cqIdARef ) );

    for my $t_cqID( @$cqIdARef )
    {
      $loggerMain->debug( '$t_cqID = ', $t_cqID );
      $committedCqIDHash{ $t_cqID } = $commitId; # MobC001234567 => 'sha'
    }
  }
} # for $hashRef

$loggerMain->debug( Dumper( %committedCqIDHash ) );

################################################################################
#  List2:
#  get a list of CQs from the CQ dB that are in 'implemented' state for the given project
################################################################################

my $implemented_FileName = $logDirectory . $newTag . '_implemented.log';

open( my $implmentedFH, '>', $implemented_FileName )
  or croak( "Cannot open file $implemented_FileName: $!" );

  my @recordFields = qw( id Category Category_Type Sub-Category );

  my $implementedCQIDsHashRef = findRecords( 'Defect', "State=\"Implemented\" and Project=\"$CQProject\"", @recordFields );

  my $implementedCQIDsLength = scalar( keys %$implementedCQIDsHashRef );
  $loggerMain->debug( "\$implementedCQIDsLength = $implementedCQIDsLength\n" );
  $loggerMain->debug( Dumper( %$implementedCQIDsHashRef ) );
  print $implmentedFH "\$implementedCQIDsLength = $implementedCQIDsLength\n" . Dumper( %$implementedCQIDsHashRef );
close $implmentedFH;

################################################################################
# List 3:
#   The intersection of List1 and List2 (CQs with no matter what state (before integrated state) they are in)
#     will be moved to integrated (state)
################################################################################

my $committedAndImplemented_FileName = $logDirectory . $newTag . '_committedAndImplemented.log';

open( my $committedAndImplementedCQs, '>', $committedAndImplemented_FileName )
  or croak( "Cannot open file $committedAndImplemented_FileName: $!" );

  my %committedAndImplementedCQIDs;
  my $committedAndImplementedCQIDsRef = \%committedAndImplementedCQIDs;

  ( $committedCqIDHashRef, $implementedCQIDsHashRef, $committedAndImplementedCQIDsRef ) = getCommittedAndImplementedCQIDs( $committedCqIDHashRef, $implementedCQIDsHashRef, $committedAndImplementedCQIDsRef );
  my $committedAndImplementedCQIDsLength = scalar( keys %committedAndImplementedCQIDs );

  $loggerMain->debug( '$committedAndImplementedCQIDsLength = ', $committedAndImplementedCQIDsLength );
  $loggerMain->debug( Dumper( %committedAndImplementedCQIDs ) );

  print $committedAndImplementedCQs "\$committedAndImplementedCQIDsLength = $committedAndImplementedCQIDsLength\n" . Dumper( %committedAndImplementedCQIDs );

close $committedAndImplementedCQs;

################################################################################
# 2. move committed and implemented (common | intersected) CQID records to integrated state
#
# For each CQID (the MobCXXXXXXXX value in the db record)
#   'version' is the tag/label associated with the record (Found_In_Version, Fixed_In_Version, Integrated_In_Version )
#   'State' is the field we want out of the db; there can be multiple fields requested, or all fields
#   'Integrated_In_Versions' is the version identfier field that's added or appended, if one exists.
################################################################################

my $totalCommittedAndImplementedCQIDs = scalar(keys %committedAndImplementedCQIDs );
$loggerMain->debug( '$totalCommittedAndImplementedCQIDs = ', $totalCommittedAndImplementedCQIDs );

@recordFields = qw( id
                    Duplicates_Of_This_Defect
                    Integrated_In_Versions
                    Project
                    State
                    Category
                    Category_Type
                    Sub-Category
                    Assignee
                  );

my $counter = $totalCommittedAndImplementedCQIDs;

while( my ($k, $v) = each %committedAndImplementedCQIDs )
{
  processCommittedImplementedRecords( 'Defect', $newTag, $k, @recordFields );

  $loggerMain->info( '=' x 80 );
  $loggerMain->info( '$k[ey]         = ', $k );
  $loggerMain->info( 'CQID count     = ', $counter-- );
  $loggerMain->info( '$doActionCount = ', $doActionCount );
}


################################################################################
# If CQ is in List1 but not in List2, query CQ database.
#  If its open move it to integrated.
#  If it is already integrated add it to a list of Fixed CQs
#   (note: we DO NOT change the state in CQ)
################################################################################

# @recordFields expanded to provide data for spreadsheet
#    CM_Log contains information about 'interim' open-state CQIDs
#
@recordFields = qw( id
                    State
                    Integrated_In_Versions
                    Project
                    Platform
                    Approved_by_CCB
                    IMS_Case_ID
                    Title
                    Entry_Type
                    Duplicates_Of_This_Defect
                    Category
                    Category_Type
                    Sub-Category
                    Assignee
                    CM_Log
                  );

my $totalCommittedOnlyCQIDs = scalar(keys %$committedCqIDHashRef );
$loggerMain->debug( '$totalCommittedOnlyCQIDs = ', $totalCommittedOnlyCQIDs );
my $CQIDCounter = $totalCommittedOnlyCQIDs;

while( my( $key, $value ) = each %$committedCqIDHashRef )
{
  $loggerMain->debug( "\$key          = ", $key );
  $loggerMain->debug( "\$value        = ", $value );

  processCommittedRecords( {
                             table  => 'Defect',
                             newtag => $newTag,
                             key    => $key,
                             value  => $value,
                             fields => \@recordFields,
                           }
                         );

  $CQIDCounter--;

  $loggerMain->debug( '$CQIDCounter   = ', $CQIDCounter );
  $loggerMain->debug( '$doActionCount = ', $doActionCount );

  $loggerMain->debug( '=' x 80 );

}

close $changeStateCQs;
close $fixedCQs;
close $otherCQs;
close $examineTheseCQs;

################################################################################
# The rest will be flagged for review, this includes CQs in List2 but not in List1
# ==>> HOW TO GET THESE: Commits between tags that don't have an associated CQ
################################################################################

my $cqIdsProcessed_FileName = $logDirectory . $newTag . '_cqIdsProcessed.log';
open( my $cqIdsProcessedFH, '>', $cqIdsProcessed_FileName )
  or croak( "Cannot open file $cqIdsProcessed_FileName: $!" );

  for my $cqIdKey( sort keys %cqIdsProcessed )
  {
    chomp $cqIdKey;
    my $actionsRef = $cqIdsProcessed{ $cqIdKey }{ Actions };
    my @actions    = @$actionsRef;

    print "$script ", __LINE__, ": \$cqIdsProcessed{$cqIdKey} = @actions\n" if $debugMain_Level_0;

    print $cqIdsProcessedFH "$script ", __LINE__, ": \$cqIdsProcessed{$cqIdKey} = @actions\n";

    $statistics{successes} += 1;
  }

close $cqIdsProcessedFH;

############################## EXCEL ###########################################

my @excelRecordFields = qw( id
                            State
                            Integrated_In_Versions
                            Project
                            Platform
                            Approved_by_CCB
                            IMS_Case_ID
                            Title
                            Entry_Type
                          );

$loggerMain->info( "Started dB query for Excel data..." );

my $cqIdLink;

# query the CQdB for CQID data
#   fill-in the Excel details
#
for my $cqId( sort keys %cqIdsProcessed )
{
  chomp $cqId;
  $loggerMain->info( '$cqId = ', $cqId );

  $excelDataHashRef = getExcelData( 'Defect', $cqId, @excelRecordFields );

  my %ExcelData = %$excelDataHashRef;
  my $State     = $excelDataHashRef->{ $cqId }{ 'State' };
     $State     = 'undef' unless defined $State;

  $loggerMain->debug( Dumper( %ExcelData ) );
  $loggerMain->info( 'id    = ', $excelDataHashRef->{ $cqId }{ 'id' } );
  $loggerMain->info( 'State = ', $State );

  # the Excel requirement is to list only current version. Not all history.
  #
  my $integratedInVersionString = $newTag;

  $loggerMain->info( "Integrated_In_Versions = \n", $integratedInVersionString );

  my $Project = $excelDataHashRef->{ $cqId }{ 'Project' };
     $Project = 'undef' unless defined $Project;

  $loggerMain->info( '$Project = ', $Project );

  my $Platform = $excelDataHashRef->{ $cqId }{ 'Platform' };
     $Platform = 'undef' unless defined $Platform;

  $loggerMain->info( '$Platform = ', $Platform );

  my $Approved_by_CCB = $excelDataHashRef->{ $cqId }{ 'Approved_by_CCB' };

  unless( defined $Approved_by_CCB )
  {
   $Approved_by_CCB = 'undef';
  }
  elsif( $Approved_by_CCB == 1 )
  {
    $Approved_by_CCB = 'Y';
  }
  else
  {
   $Approved_by_CCB = 'N';
  }
  $loggerMain->info( '$Approved_by_CCB = ', $Approved_by_CCB );

  my $IMSCaseID = $excelDataHashRef->{ $cqId }{ 'IMS_Case_ID' };
     $IMSCaseID = 'Not defined' unless defined $IMSCaseID;

  $loggerMain->info( '$IMSCaseID = ', $IMSCaseID );

  my $Title = $excelDataHashRef->{ $cqId }{ 'Title' };
     $Title = 'undef' unless defined $Title;

  $loggerMain->info( '$Title = ', $Title );

  my $Entry_Type = $excelDataHashRef->{ $cqId }{ 'Entry_Type' };
     $Entry_Type = 'undef' unless defined $Entry_Type;

  $loggerMain->info( '$Entry_Type = ', $Entry_Type );

  # set row format defaults
  #
  $wsD->set_row( $dataRow, $dataRowHeight, $dataRowFormat );

  # add data and update individual cell formats where required
  #
  $cqIdLink = "http://cqweb-irva-mcbu.corp.com/cqweb/#/MCBU/MobC/RECORD/${cqId}&recordType=Defect&format=HTML&noframes=false&version=cqwj";

  $loggerMain->info( '$cqIdLink = ', $cqIdLink );

  $wsD->write_url( $dataRow, $dataCol, $cqIdLink, $cqId, $url_link_format );
  $wsD->write(     $dataRow, $dataCol + 1, $State, $center_cell_format );

  $wsD->write( $dataRow, $dataCol + 2, $integratedInVersionString, $left_cell_wrap_format );

  $wsD->write( $dataRow, $dataCol + 3, $Project,         $center_cell_format );
  $wsD->write( $dataRow, $dataCol + 4, $Platform,        $center_cell_format );
  $wsD->write( $dataRow, $dataCol + 5, $Approved_by_CCB, $center_cell_format );
  $wsD->write( $dataRow, $dataCol + 6, $IMSCaseID,       $center_cell_format );
  $wsD->write( $dataRow, $dataCol + 7, $Title,           $left_cell_wrap_format );
  $wsD->write( $dataRow, $dataCol + 8, $Entry_Type,      $center_cell_format );

  # set/reset counters
  #
  $dataRow++;

} # for cqIDs

$loggerMain->info( "Completed Excel row updates. Continuing with summary data and format..." );

$wsD->write( $summaryDataRow,     $summaryDataCol + 1,  $statistics{successes},  $right_cell_format );
$wsD->write( $summaryDataRow + 1, $summaryDataCol + 1,  $statistics{duplicates}, $right_cell_format );
$wsD->write( $summaryDataRow + 2, $summaryDataCol + 1,  $statistics{exceptions}, $right_cell_format );

# create title text
$wsD->set_row( $titleRow, $titleRowHeight );

$wsD->merge_range($titleRow,
                  $titleCol,
                  $titleRow,
                  $titleCol + $titleCol_End,
                  'BCM'. $CQProject . ': ' . $manifest . ' : ClearQuest State Changes ' . $today_mm_dd_yyyy,
                  $titleFormat );

autofit_columns($wsD); # doesn't work very well ...

# force these column widths
#
$wsD->set_column('A:A', 20); # CQID
$wsD->set_column('B:B', 15); # State
$wsD->set_column('C:C', 50); # Integrated_In_Versions
$wsD->set_column('D:D', 10); # Project
$wsD->set_column('E:E', 21); # Platform
$wsD->set_column('F:F', 25); # Approved_By_CCB
$wsD->set_column('G:G', 20); # IMS_Case_ID
$wsD->set_column('H:H', 50); # Title
$wsD->set_column('I:I', 15); # Entry_Type

$loggerMain->info( "Creating Exception_Report worksheet, if required..." );

# create Exception_Report worksheet
#   if there's data to report
#
my $xCqIdsFH;

  my $xCqIds_FileName = $logDirectory . $newTag . '_xCqIds.log';

  open( $xCqIdsFH, '>', $xCqIds_FileName )
    or croak( "Cannot open file $xCqIds_FileName: $!" );

  my $wsE = $integratedCQwb->add_worksheet( 'Exception_Report' );

  $wsE->set_row( $titleRow, $titleRowHeight );
  $wsE->merge_range( $titleRow,
                     $titleCol,
                     $titleRow,
                     $titleCol + $titleCol_End,
                     'BCM'. $CQProject . ': ' . $manifest . ' : ClearQuest State Changes ' . $today_mm_dd_yyyy,
                     $titleFormat );

  # define header formats for Exception sheet
  #
  my $xHeaderRow            = $titleRow + 2;
  my $xHeaderHeight         = 20;
  my $xHeaderCol            = 0;
  my $xDataRow              = $xHeaderRow + 1;
  my $xDataRowHeight        = 15;
  my $xDataCol              = 0;

  # create header text with individual cell format
  #
  $wsE->set_row( $xHeaderRow, $xHeaderHeight );

  $wsE->write( $xHeaderRow, $xHeaderCol,     'CQIDs with Exceptions', $cqIDHeadingFormat );
  $wsE->write( $xHeaderRow, $xHeaderCol + 1, 'State', $genericHeadingFormat );
  $wsE->write( $xHeaderRow, $xHeaderCol + 2, 'Integrated_In_Versions', $genericHeadingFormat );
  $wsE->write( $xHeaderRow, $xHeaderCol + 3, 'Project', $genericHeadingFormat );
  $wsE->write( $xHeaderRow, $xHeaderCol + 4, 'Platform', $genericHeadingFormat );
  $wsE->write( $xHeaderRow, $xHeaderCol + 5, 'Approved_By_CCB', $genericHeadingFormat );
  $wsE->write( $xHeaderRow, $xHeaderCol + 6, 'IMS_Case_ID', $genericHeadingFormat );
  $wsE->write( $xHeaderRow, $xHeaderCol + 7, 'Title', $genericHeadingFormat );
  $wsE->write( $xHeaderRow, $xHeaderCol + 8, 'Entry_Type', $genericHeadingFormat );

if( $#xCqId > 0 )
{
  $loggerMain->info( "Exception_Report dB query..." );

  # query the CQdB for CQID data
  #   fill-in the Excel details
  #
  while( my $xCqId = <@xCqId> )
  {
    chomp $xCqId;

    print $xCqIdsFH $xCqId;

    $excelDataHashRef = getExcelData( 'Defect', $xCqId, @recordFields );
    my %ExcelData     = %$excelDataHashRef;

    $loggerMain->debug( Dumper( %ExcelData ) );
    $loggerMain->info( 'id = ', $excelDataHashRef->{ $xCqId }{ 'id' } );

    my $State = $excelDataHashRef->{ $xCqId }{ 'State' };
       $State = 'undef' unless defined $State;

    $loggerMain->info( '$State = ', $State );

    my $integratedInVersionString = $newTag;

    $loggerMain->info( '$integratedInVersionString = ', $integratedInVersionString );

    my $Project = $excelDataHashRef->{ $xCqId }{ 'Project' };
       $Project = 'undef' unless defined $Project;

    $loggerMain->info( '$Project = ', $Project );

    my $Platform = $excelDataHashRef->{ $xCqId }{ 'Platform' };
       $Platform = 'undef' unless defined $Platform;

    $loggerMain->info( '$Platform = ', $Platform );

    my $Approved_by_CCB = $excelDataHashRef->{ $xCqId }{ 'Approved_by_CCB' };

    unless( defined $Approved_by_CCB )
    {
     $Approved_by_CCB = 'undef';
    }
    elsif( $Approved_by_CCB == 1 )
    {
      $Approved_by_CCB = 'Y';
    }
    else
    {
     $Approved_by_CCB = 'N';
    }

    $loggerMain->info( '$Approved_by_CCB = ', $Approved_by_CCB );

    my $IMSCaseID = $excelDataHashRef->{ $xCqId }{ 'IMS_Case_ID' };
       $IMSCaseID = 'Not defined' unless defined $IMSCaseID;

    $loggerMain->info( '$IMSCaseID = ', $IMSCaseID );

     my $Title = $excelDataHashRef->{ $xCqId }{ 'Title' };
        $Title = 'undef' unless defined $Title;

    $loggerMain->info( '$Title = ', $Title );

    my $Entry_Type = $excelDataHashRef->{ $xCqId }{ 'Entry_Type' };
       $Entry_Type = 'undef' unless defined $Entry_Type;

    $loggerMain->info( '$Entry_Type = ', $Entry_Type );

    # set row format defaults
    #
    $wsE->set_row( $xDataRow, $xDataRowHeight, $dataRowFormat );

    # add data and update individual cell formats where required
    #
    $cqIdLink = "http://cqweb-irva-mcbu.corp.com/cqweb/#/MCBU/MobC/RECORD/${xCqId}&recordType=Defect&format=HTML&noframes=false&version=cqwj";

    $wsE->write_url( $xDataRow, $xDataCol, $cqIdLink, $xCqId, $url_link_format );
    $wsE->write(     $xDataRow, $xDataCol + 1, $State, $center_cell_format );

    $wsE->write( $xDataRow, $xDataCol + 2, $integratedInVersionString, $left_cell_wrap_format );

    $wsE->write( $xDataRow, $xDataCol + 3, $Project,         $center_cell_format );
    $wsE->write( $xDataRow, $xDataCol + 4, $Platform,        $center_cell_format );
    $wsE->write( $xDataRow, $xDataCol + 5, $Approved_by_CCB, $center_cell_format );
    $wsE->write( $xDataRow, $xDataCol + 6, $IMSCaseID,       $center_cell_format );
    $wsE->write( $xDataRow, $xDataCol + 7, $Title,           $left_cell_wrap_format );
    $wsE->write( $xDataRow, $xDataCol + 8, $Entry_Type,      $center_cell_format );

    # set/reset counters
    $xDataRow++;

  } # while $xCqID

  $loggerMain->info( "Done with Exception_Report worksheet..." );

  autofit_columns($wsE); # doesn't work very well ...

  # force these column widths
  #
  $wsE->set_column('A:A', 35); # CQID
  $wsE->set_column('B:B', 15); # State
  $wsE->set_column('C:C', 50); # Integrated_In_Versions
  $wsE->set_column('D:D', 10); # Project
  $wsE->set_column('E:E', 21); # Platform
  $wsE->set_column('F:F', 25); # Approved_By_CCB
  $wsE->set_column('G:G', 20); # IMS_Case_ID
  $wsE->set_column('H:H', 50); # Title
  $wsE->set_column('I:I', 15); # Entry_Type

} # if @xCqId

close $xCqIdsFH if $xCqIdsFH;

# create an Excel workbook/worksheet containing the committed and CQ data
# @g_dataArray contains the commit data
#
my $committedDataWorkbookStatus = createCommittedDataWorkbook( {
                                                                project      => $CQProject,
                                                                manifest     => $manifest,
                                                                committedcqs => $committedCqIDHashRef,
                                                               }
                                                              );

$loggerMain->info( "Done with workbook..." );

if( $nonExecMode )
{
  $loggerMain->warn( "Not copying .xlsx file - NONEXEC_MODE is set to '1'" );
}
else
{
  # copy xlsx to irv server
  if (system("scp -rq ${excelDirectory}${newTag}_Integrated_CQs.xlsx xserver.irv.corp.com:$output_path"))
  {
    print "__ERROR__ : couldnt scp the output excel file \"${excelDirectory}${newTag}_Integrated_CQs.xlsx\" to xserver.irv.corp.com:$output_path\n";
  }
  else
  {
    print "__INFO__ : successfully copied over the output excel file \"${excelDirectory}${newTag}_Integrated_CQs.xlsx\" to xserver.irv.corp.com:$output_path\n";
    $loggerMain->warn( "copied excel file \"${excelDirectory}${newTag}_Integrated_CQs.xlsx\" to xserver.irv.corp.com:$output_path" );
    system("ssh mobcom_ec\@xserver.irv.corp.com -q chmod -R 775 $output_path");
  }
}
############################ EXCEL ###########################################

chdir
  or croak "__ERROR__ : Can't chdir to default directory: $!\n";

# rmWorkingDir( $wsPath ) if -e $wsPath and $p4Sync or $repo2Sync;

$integratedCQwb->close()
  or croak "__CROAK__ : closing Excel workbook : $!\n";

$loggerMain->info( "Finished!" );

END
{
  $cq->disconnect if $cq;      # disconnect instantiated Clearquest::REST object
}


exit 0;

###############################################################################
#
#
###############################################################################
sub processRepo
{
  my $pHashRef        = shift;

  my $pThisRepoHRef    = $pHashRef->{ repohref };
  my $pDefaultRemote   = $pHashRef->{ defaultremote };
  my $pDefaultRevision = $pHashRef->{ defaultrevision };

  my $thisThreadId  = threads->tid();
  my $pThisThreadId = $thisThreadId;

  ## create a logger for each thread
  ##   threadLoggerInit() returns a reference to a configuration string
  ##
  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  my $returnStatus = 1;

  my( $subName ) = $subroutine =~ m{main::(.*)}x;

  $pThisThreadId = sprintf( "%04d", $pThisThreadId );
  my $threadName = "${pThisThreadId}_${subName}";
  my $threadLog  = "${logDirectory}/$threadName.log";

  Log::Log4perl::init( threadLoggerInit( $threadLog ) );

  my $threadLogger = get_logger( $threadName  );
     $threadLogger->level( $loggerMain_LogLevel );

  $threadLogger->info( "\n", '=' x 80, "\n" );
  $threadLogger->info( '$pThisThreadId = ', $pThisThreadId );

  # if this repo's remote is not defined, use default
  #
  unless( $pThisRepoHRef->{ remote } )
  {
    $pThisRepoHRef->{ remote } = $pDefaultRemote;
  }

  # if this repo's revision is not defined, use default, or
  #   if revision is defined but different than default
  #     log it as info - something will need to be done...
  #
  unless( defined( $pThisRepoHRef->{ revision } ) )
  {
    $pThisRepoHRef->{ revision } = $pDefaultRevision;
  }
  elsif( $pThisRepoHRef->{ revision } ne $pDefaultRevision )
  {
    $threadLogger->error( 'repo revision and default revision are not the same' );
    $threadLogger->error( '$pThisRepoHRef->{ revision } = ', $pThisRepoHRef->{ revision } );
    $threadLogger->error( '$pDefaultRevision            = ', $pDefaultRevision );
  }

  my $repoName   = $pThisRepoHRef->{ name };
  my $path       = $repoName . '.git';                   # use "name" instead of "path"
  my $BASE_PATH  = $REMOTES{$pThisRepoHRef->{ remote }}; # . '.git'

  my $cpPath     = qr{vendor/corp/modem}ix;

  my $majorPlatform = 'AP';
     $majorPlatform = 'CP' if $repoName =~ $cpPath;

  $threadLogger->info( '$path                        = ', $path );
  $threadLogger->info( '$BASE_PATH                   = ', $BASE_PATH );
  $threadLogger->info( '$majorPlatform               = ', $majorPlatform );

  $threadLogger->info( '$pThisRepoHRef->{ remote }   = ', $pThisRepoHRef->{ remote } );
  $threadLogger->info( '$pThisRepoHRef->{ revision } = ', $pThisRepoHRef->{ revision } );

  $threadLogger->info( Dumper( %$pThisRepoHRef ) );

  my %validCqIds;

  if (-e "$BASE_PATH/$path" )
  {
    # Get a list of commits ** for this repo **
    #
    my $cmd = "git --git-dir $BASE_PATH/$path log --pretty=format:\"%h $pThisRepoHRef->{revision}\" $oldTag..$newTag 2>&1";
    my $commits = qx( $cmd );

    if( $? || $commits =~ /^fatal/ix )
    {
      $threadLogger->fatal( "git log error \$? = ", $? );
      $threadLogger->fatal( Dumper( $commits ) );
    }
    elsif( length $commits > 0 )
    {
      my @commitIds = split( /\n/, $commits);

      $threadLogger->info( "Commits for this repo = " . scalar( @commitIds ) );
      $threadLogger->debug( Dumper( @commitIds ) );

      # Loop through the list of commits and process
      #
      for my $shortCommitId( @commitIds )
      {
        $threadLogger->debug( '$shortCommitId = ', $shortCommitId );

        # Get all info about the commit
        #
        my $showCmd   = "git --git-dir $BASE_PATH/$path show --stat $shortCommitId 2>&1";
        my $component = qx( $showCmd );

        $threadLogger->debug( Dumper( $component ) );

        # Parse out and use the commit ID returned (sanity)
        #
        my( $fullCommitId ) = $component =~ /^commit (\S+)/;

        $threadLogger->info( '$fullCommitId = ', $fullCommitId );

        my @cqIdArray;
        my @cqIds;

        # extract all CQ ID's from the log record
        #
        while( $component =~ /(MobC(\d+))/gm )
        {
          $threadLogger->debug( "CQ Id $1 ends at position ", pos $component );
          push @cqIds, $1 if $2 > 0;
        }

        $threadLogger->info( 'found = ', scalar @cqIds, " CQ ID's" ) if( scalar @cqIds > 0 );
        $threadLogger->info( "no CQ ID's found" )                    if( scalar @cqIds == 0 );

        # Loop through each CQ found
        #
        for my $cqId( @cqIds )
        {
          $threadLogger->info( 'parsed $cqId = ', $cqId );

          if( exists $validCqIds{ $fullCommitId } )
          {
            $threadLogger->debug( Dumper( %validCqIds ) );
            $threadLogger->info( "Key exists. Appending $cqId to array..." );

            # if the key exists
            #  extract the existing array
            #    and append the new id
            #
            my $tempArrayRef = $validCqIds{ $fullCommitId }{ cqids };
            $threadLogger->info( Dumper( $tempArrayRef ) );

            push @$tempArrayRef, $cqId;
            $threadLogger->info( Dumper( $tempArrayRef ) );

            my %hash      = map{ $_ => 1 } @$tempArrayRef;
            $threadLogger->info( Dumper( %hash ) );

            @cqIdArray    = keys %hash;
            $threadLogger->info( Dumper( @cqIdArray ) );
          }
          else # key is not in the hash; just add the new key/array to the hash
          {
            $threadLogger->info( "New key. Adding $cqId to array..." );
            push @cqIdArray, $cqId;
            $threadLogger->debug( Dumper( @cqIdArray ) );
          }

          # Get the git commit time (committer date) and convert it to Pacific time
          #
          my $logCmd = "git --git-dir $BASE_PATH/$path log --pretty=format:%cd $fullCommitId -n 1";

          $validCqIds{ $fullCommitId }{ committime     } = get_commit_time( $logCmd );
          $validCqIds{ $fullCommitId }{ platform       } = $majorPlatform;
          $validCqIds{ $fullCommitId }{ cqids          } = \@cqIdArray;
          $validCqIds{ $fullCommitId }{ reponame       } = $repoName;
          $validCqIds{ $fullCommitId }{ component      } = \$component;

        } # for $cqTds
      } # for $shortCommitId
    } # $commits > 0
    else
    {
      $threadLogger->warn( 'No commits', Dumper( $commits ) );
    }

  } # path valid
  else
  {
    $threadLogger->fatal( "$BASE_PATH/$path does not exist!" );
  }

  $threadLogger->info( Dumper( %validCqIds ) );
  $threadLogger->info( 'End ', $subroutine, ': ', $pThisThreadId );
  $threadLogger->info( "\n", '=' x 80, "\n" );

  return( [ $thisThreadId, \%validCqIds ] );

}

sub getReposFromManifest
{
  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  print "$subroutine ", __LINE__, " : \$REPOS_PATH = $REPOS_PATH\n" if $debugTrace_Level_0;

  # Verify if project exists by running:
  #    git branch | grep "\s+$PROJECT$"
  #    if it's not empty and matches $PROJECT then it's ok and proceed

  my $projects = qx( git --git-dir $REPOS_PATH branch );

  print "$subroutine ", __LINE__,  ' ', Dumper( $projects ) if $debugTrace_Level_0;

  my $xmlDataHRef;

  if( $projects =~ /^\s*$manifest\s*$/m )
  {
    # Get the default.xml for the project:
    #    git show $manifest:default.xml

    my $xmlFile = qx( git --git-dir $REPOS_PATH show $manifest:default.xml );

    print "$subroutine ", __LINE__,  ' ', Dumper( $xmlFile ) if $debugTrace_Level_0;

    $xmlDataHRef = XMLin( $xmlFile, ForceArray => 1, KeyAttr => '' );

    #'remote' => [
    #                              {
    #                                'review' => 'http://mps-gerrit.sj.corp.com',
    #                                'name' => 'mps-git',
    #                                'fetch' => '/projects/mobcom_andrgit/scm/git_repos'
    #                              },
    #                              {
    #                                'review' => 'http://mps-gerrit.sj.corp.com',
    #                                'name' => 'mps-gerrit',
    #                                'fetch' => 'ssh://mps-gerrit.sj.corp.com:29418/'
    #                              }
    #                            ]

    #foreach my $remote ( @{$xmlData->{ remote }} )

    foreach my $remote ( @{$xmlDataHRef->{ remote }} )
    {
      print "$subroutine ", __LINE__,  ' ', Dumper( $remote ) if $debugTrace_Level_0;

      $remote->{'fetch'} =~ s/$GIT_URIS_SEARCH/$GIT_URIS_REPLACE/; # replace ssh:// path with file system path
      $REMOTES{$remote->{'name'}} = $remote->{'fetch'};            # replace repo path with file system path
    }

  }
  else
  {
    print "__ERROR__ : Invalid project name. Exiting!\n";
    exit(1);
  }

  return $xmlDataHRef;

}

sub osDir
{
  my $dir;
  if( $^O =~ /x$/ix ) # Unix or Linux
  {
    $dir = qx( pwd );
    $dir =~ s{(.*)$}{$1/}x;
  }
  elsif( $^O =~ /MSWin/ix )
  {
    $dir = qx( echo %cd% );
    $dir =~ s{(.*)$}{$1\\}x;
  }
  else
  {
    croak "__CROAK__ Operating system not recognized!: \$^O = ", $^O, "\n";
  }
  return \$dir;
}

sub threadLoggerInit
{
  my $logFile = shift;
  # create a configuration definition
  #
  my $threadLogConfig = qq(
                            log4perl.rootLogger              = DEBUG, LOG1
                            log4perl.appender.LOG1           = Log::Log4perl::Appender::File
                            log4perl.appender.LOG1.filename  = $logFile
                            log4perl.appender.LOG1.mode      = write
                            log4perl.appender.LOG1.layout    = Log::Log4perl::Layout::PatternLayout
                            log4perl.appender.LOG1.layout.ConversionPattern = %d %L %p %m %n
                           );
  return \$threadLogConfig;
}

sub get_commit_time {
    my ($cmd) = @_;
    my $commit_time = qx( $cmd );

    # the output of cmd is something like Tue Nov 20 22:36:48 2012 -0800

    my ($day, $month, $date, $time, $year, $diff) = split(/ /, $commit_time);

    $time =~ m/(\d\d):(\d\d):(\d\d)/;

    my $hour = $1;
    my $min  = $2;
    my $sec  = $3;
    my $ampm = '';

    if (int($hour) > 12) {
	$hour = ($hour - 12);
	if ($hour < 10) {
	    $hour = '0' . $hour;
	}
	$ampm = 'PM';
    }
    else {
	if ($hour == 00) {
	    $hour = 12;
	}
	$ampm = 'AM';
    }

    $commit_time = "$day $month $date $year ${hour}:${min}:${sec} $ampm $diff";

    return $commit_time;
}

###############################################################################
#
# Functions used for Autofit.
#
###############################################################################
#
# Adjust the column widths to fit the longest string in the column.
#
sub autofit_columns
{
  my $worksheet = shift;
  my $col       = 0;
  for my $width (@{$worksheet->{__col_widths}})
  {
      $worksheet->set_column($col, $col, $width) if $width;
      $col++;
  }
  return;
}

###############################################################################
#
# The following function is a callback added via add_write_handler().
# It modifies the write() function to store the maximum unwrapped width of a
# string in a column.
#
sub store_string_widths
{
    my $worksheet = shift;
    my $col       = $_[1];
    my $token     = $_[2];

    # Ignore some tokens that we aren't interested in.
    return if not defined $token;       # Ignore undefs.
    return if $token eq '';             # Ignore blank cells.
    return if ref $token eq 'ARRAY';    # Ignore array refs.
    return if $token =~ /^=/x;           # Ignore formula

    # Ignore numbers
    return if $token =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/x;

    # Ignore various internal and external hyperlinks. In a real scenario
    # you may wish to track the length of the optional strings used with
    # urls.
    return if $token =~ m{^[fh]tt?ps?://}x;
    return if $token =~ m{^mailto:}x;
    return if $token =~ m{^(?:in|ex)ternal:}x;


    # We store the string width as data in the Worksheet object. We use
    # a double underscore key name to avoid conflicts with future names.
    #
    my $old_width    = $worksheet->{__col_widths}->[$col];
    my $string_width = string_width($token);

    if (not defined $old_width or $string_width > $old_width)
    {
        # You may wish to set a minimum column width as follows.
        #  return undef if $string_width < 10;

        $worksheet->{__col_widths}->[$col] = $string_width;
    }

    # Return control to write();
    return;
}

###############################################################################
# Simple conversion between string length and string width for Arial 10 (0.9).
###############################################################################
sub string_width {
    my $arg = shift;
    return 1.15 * length $arg;
}

sub mergeHashes
{
  my $hashRefA = shift;
  my $hashRefB = shift;

  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  print "$subroutine ", __LINE__, ": \$hashRefA = $hashRefA\n" if $debugMergeHashes;
  print "$subroutine ", __LINE__, ": \$hashRefB = $hashRefB\n" if $debugMergeHashes;

  my %hashA = %$hashRefA;
  my %hashB = %$hashRefB;

  my $lengthHashA = scalar( keys %hashA );
  my $lengthHashB = scalar( keys %hashB );

  print "$subroutine ", __LINE__, ": \$lengthHashA = $lengthHashA\n" if $debugMergeHashes;
  print "$subroutine ", __LINE__, ": \$lengthHashB = $lengthHashB\n" if $debugMergeHashes;

  print "$subroutine ", __LINE__, ": ", Dumper( %hashA ), "\n" if $debugMergeHashes;
  print "$subroutine ", __LINE__, ": ", Dumper( %hashB ), "\n" if $debugMergeHashes;

  my $existsCount = 0;
  my $mergeCount  = 0;

  if( $lengthHashA <= $lengthHashB ) # merge smaller hash into larger; A => B
  {
    HASHALOOP: for my $keyA( keys %hashA )
    {
      if( exists $hashB{ $keyA } )
      {
        $existsCount++;
        print "$subroutine ", __LINE__, ": Key [ $keyA ] exists in \%hashB.\t\$existsCount = $existsCount\n" if $debugMergeHashes;
        next HASHALOOP;
      }
      else
      {
        $hashB{ $keyA } = $hashA{ $keyA};
        $mergeCount++;
        print "$subroutine ", __LINE__, ": Key [ $keyA ] added to \%hashB\t\$mergeCount = $mergeCount\n" if $debugMergeHashes;
      }
    }
    return \%hashB;
  }
  else # $lengthHashB < $lengthHashA; B => A
  {
    HASHBLOOP: for my $keyB( keys %hashB )
    {
      if( exists $hashA{ $keyB } )
      {
        $existsCount++;
        print "$subroutine ", __LINE__, ": Key [ $keyB ] exists in \%hashA.\t\$existsCount = $existsCount\n" if $debugMergeHashes;
        next HASHBLOOP;
      }
      else
      {
        $hashA{ $keyB } = $hashB{ $keyB };
        $mergeCount++;
        print "$subroutine ", __LINE__, ": Key [ $keyB ] added to \%hashA\t\$mergeCount = $mergeCount\n" if $debugMergeHashes;
      }
    }
    return \%hashA;
  }
} # sub mergeHashes

sub getCommittedAndImplementedCQIDs
{
  my $hashRefA = shift;
  my $hashRefB = shift;
  my $hashRefC = shift;

  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  # walk through a hash element-by-element
  # -> this approach will conserve memory, but may be slow(er)
  #
  # find the common keys between hashes A, B
  # ... put them into hash C
  # ... delete them from A, B

  my $elementsA = scalar( keys %$hashRefA );
  my $elementsB = scalar( keys %$hashRefB );

  # compare the smaller hash against the larger
  #
  if( $elementsA <= $elementsB ) # hash A is smaller
  {
    while( my( $key_A, $value_A ) = each( %$hashRefA ) )
    {
      if( exists $hashRefB->{ $key_A } ) # if keyA is in hash B
      {
        $hashRefC->{ $key_A }= 'common'; # create key in hash C
        delete $hashRefA->{ $key_A };    # remove from hash A
        delete $hashRefB->{ $key_A };    # remove from hash B
      }
    }
  }
  else # hash B is smaller
  {
    while( my( $key_B, $value_B ) = each( %$hashRefB ) )
    {
      if( exists $hashRefA->{ $key_B } ) # if keyB is in hash A
      {
        $hashRefC->{ $key_B } = 'common'; # create the key in hash C
        delete $hashRefA->{ $key_B };     # remove from hash A
        delete $hashRefB->{ $key_B };     # remove from hash B
      }
    }
  }

  return $hashRefA, $hashRefB, $hashRefC;

} # getCommittedAndImplementedCQIDs

sub processCommittedImplementedRecords
{
  my( $table, $version, $key, @fields ) = @_;
  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  #my $logger = get_logger( $subroutine );
  #$logger->level( $processCommittedImplementedRecords_LogLevel );

  $loggerMain->debug( '$table     = ', $table );
  $loggerMain->debug( '$version   = ', $version );
  $loggerMain->debug( '$key        = ', $key );
  $loggerMain->debug( Dumper( @fields ) );

  my %dBRecord = $cq->get( $table, $key, @fields );
  my( $restStatus, $restMsg ) = checkRESTError();
  $loggerMain->error( '$restStatus = ', $restStatus ) unless( $restStatus == $REST_OK );
  $loggerMain->error( '$restMsg    = ', $restMsg )    if $restMsg;
  return unless $restStatus == $REST_OK;

  my $recordProject = $dBRecord{ Project };
  $loggerMain->debug( '$recordProject = ', $recordProject ) if $recordProject;
  return unless( $recordProject and $recordProject eq $CQProject );

  # Category_Type and/or may be undef...
  #
  my $is_Category      = $dBRecord{ 'Category' };
  my $is_Category_Type = $dBRecord{ 'Category_Type' };
  my $is_Sub_Category  = $dBRecord{ 'Sub-Category' };

  $is_Category      = ' ' unless defined $is_Category;
  $is_Category_Type = ' ' unless defined $is_Category_Type;
  $is_Sub_Category  = ' ' unless defined $is_Sub_Category;

  # requirement ... filter Tools > MTT records
  #
  return if( $is_Category       eq 'Software' and
             $is_Category_Type  eq 'Tools'
           );

  my $duplicatesRef = $dBRecord{ Duplicates_Of_This_Defect };
  my $iivRef        = $dBRecord{ Integrated_In_Versions };
  my $cqId          = $dBRecord{ id };
  my $cqState       = $dBRecord{ State };
  my $action        = $actions{ $cqState };

  my @duplicates    = @$duplicatesRef;
  my @iiv           = @$iivRef;

  $loggerMain->debug( '$cqId    = ', $cqId );
  $loggerMain->debug( '$cqState = ', $cqState );

  $loggerMain->debug( Dumper( %dBRecord ) );
  $loggerMain->debug( Dumper( @duplicates ) );
  $loggerMain->debug( Dumper( @iiv ) );

  # check the state of 'this' record
  #   if in Integrated, Verified or Closed state, update the Integrated_In_Versions field
  #
  if( $cqState eq 'Feedback' or
      $cqState eq 'Rejected' or
      $cqState eq 'Suspended' )
  {
    $loggerMain->debug( '$cqId = ', $cqId );
    $loggerMain->debug( 'No action taken... $cqState = ', $cqState );
    return; # no processing for records in these states
  }
  elsif( $cqState eq 'Integrated' or
         $cqState eq 'Verified' or
         $cqState eq 'Closed' )
  {
    $loggerMain->debug( '$cqId = ', $cqId );
    $loggerMain->debug( 'Updating Integrated_In_Version field... $cqState = ', $cqState );
    my( $updateRequired, $updateHashRef ) = updateIiv( $version, $cqState, \%dBRecord );  # update Integrated_In_Versions field

    if( $updateRequired )
    {
      $loggerMain->debug( '$cqId    = ', $cqId );
      $loggerMain->debug( '$cqState = ', $cqState );
      $loggerMain->debug( 'Modifying record... $action = ', $action );
      doAction( $cqId, $action, $updateHashRef );
    }
  }
  else # record State will be changed
  {
     # check for duplicates
     #   if duplicate(s) exist, modify duplicate record before the parent
     #
     if( scalar @duplicates > 0 )
     {
       $loggerMain->debug( Dumper( @duplicates ) );

       # process each duplicate record in-place
       #    if there are duplicates of a duplicate, process recursively
       #
       foreach my $duplicateID( @duplicates )
       {
         $loggerMain->debug( 'Calling processCommittedImplementedRecords... $duplicateID = ', $duplicateID );
         processCommittedImplementedRecords( 'Defect', $version, "id=$duplicateID", @fields );
         $statistics{ duplicates } += 1;
       }
     }
     else
     {
      $loggerMain->debug( 'There are no duplicates of $cqId = ', $cqId );
     }

     my $newState = $states{ $cqState };
     my $action   = $actions{ $cqState };

     $loggerMain->debug( 'Modifying... $cqId     = ', $cqId );
     $loggerMain->debug( 'From:        $cqState  = ', $cqState );
     $loggerMain->debug( 'To:          $newState = ', $newState );

     changeDefectState( $version, $cqId, \%dBRecord );

  } # if $cqState

  return;

} # processCommittedImplementedRecords



################################################################################
# sub processCommittedRecords
#
# If CQ is in List1 but not in List2, query CQ database.
#  If its open                                     (ONLY OPEN? or in any state?)
#    move it to integrated.
#  If it is already integrated
#    add it to a list of Fixed CQs (note: we DONOT change the state in CQ)
################################################################################

sub processCommittedRecords
{
  my $pHRef = shift;

  my $table      = $pHRef->{ table  };
  my $version    = $pHRef->{ newtag };
  my $mobcId     = $pHRef->{ key    };
  my $cid        = $pHRef->{ value  };
  my $fieldsARef = $pHRef->{ fields };

  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  #my $logger = get_logger( $subroutine );
  #$logger->level( $INFO );

  $loggerMain->info ( '$table     = ', $table );
  $loggerMain->info ( '$version   = ', $version );
  $loggerMain->info ( '$mobcId    = ', $mobcId );
  $loggerMain->info ( '$cid       = ', $cid );

  $loggerMain->debug( Dumper( @$fieldsARef ) );

  my %dBRecord = $cq->get( $table, $mobcId, @$fieldsARef );

  my $recordProject = $dBRecord{ Project };

  # if there's a record and it's for this project ...
  #
  unless( $recordProject and $recordProject eq $CQProject )
  {
    $loggerMain->info( '$recordProject = ', $recordProject ) if $recordProject;
    return;
  }
  else
  {
    $loggerMain->info( 'Processing $recordProject = $CQProject = ', $CQProject );
  }

  # Category_Type and/or may be undef...
  #
  my $is_Category      = $dBRecord{ 'Category' };
  my $is_Category_Type = $dBRecord{ 'Category_Type' };
  my $is_Sub_Category  = $dBRecord{ 'Sub-Category' };

  $is_Category      = 'undef' unless defined $is_Category;
  $is_Category_Type = 'undef' unless defined $is_Category_Type;
  $is_Sub_Category  = 'undef' unless defined $is_Sub_Category;

  $loggerMain->info ( '$is_Category      = ', $is_Category );
  $loggerMain->info ( '$is_Category_Type = ', $is_Category_Type );
  $loggerMain->info ( '$is_Sub_Category  = ', $is_Sub_Category );

  # requirement per ... filter Tools
  #
  return if( $is_Category       eq 'Software' and
             $is_Category_Type  eq 'Tools'
           );

  my $duplicatesRef = $dBRecord{ Duplicates_Of_This_Defect };
  my $iivRef        = $dBRecord{ Integrated_In_Versions };
  my $cqId          = $dBRecord{ id };
  my $cqState       = $dBRecord{ State };
  my $CM_Log        = $dBRecord{ CM_Log }; # contains 'Interim' Open-state information

  my $action        = $actions{ $cqState };

  my @duplicates    = @$duplicatesRef;
  my @iiv           = @$iivRef;

  $loggerMain->info ( '$cqId    = ', $cqId );
  $loggerMain->info ( '$cqState = ', $cqState );

  $loggerMain->debug( Dumper( %dBRecord ) );
  $loggerMain->debug( Dumper( @duplicates ) );
  $loggerMain->debug( Dumper( @iiv ) );

  # if in Opened State
  #   move to Integrated State
  # else
  #   do nothing ?
  #
  #We have to be careful in changing the state of CQ in “Open” state.
  #Development team might be using the  incremental approach where they keep the CQID in “Open” state by using “Interim” keyword in CL/Commit template.
  #For example: there are 39 such defects in Capri. Example: Defect:MobC00205982
  #We need to ignore these moving to Integrated.
  #
  #What processing, if any, should be taken WRT defect records in states other than ‘opened’ or ‘integrated?’
  #                Submitted   =>  Move to integrated
  #                Assigned    =>  Move to integrated
  #                Verified    =>  Don’t add to list of fixed CQs but add to list to be inspected by integration lead
  #                Closed      =>  Don’t add to list of fixed CQs but add to list to be inspected by integration lead
  #                Feedback    =>  Move to integrated
  #                Rejected    =>  Don’t add to list of fixed CQs but add to list to be inspected by integration lead
  #                Suspended   =>  Don’t add to list of fixed CQs but add to list to be inspected by integration lead

  if( $cqState eq 'Opened' or
      $cqState eq 'Submitted' or
      $cqState eq 'Assigned' or
      $cqState eq 'Implemented' or
      $cqState eq 'Feedback'
    )
  {
    # check for duplicates
    #   if duplicate(s) exist, modify duplicate record before the parent

    if( scalar @duplicates > 0 )
    {
      # process each duplicate record in-place
      #    if there are duplicates of a duplicate, process recursively

      foreach my $duplicateID( @duplicates )
      {
        $loggerMain->info( 'Calling processCommittedRecords... $duplicateID = ', $duplicateID );

        # recursively process duplicate(s)

        processCommittedRecords( {
                                   table  => 'Defect',
                                   newtag => $version,
                                   key    => "id=$duplicateID",
                                   value  => $cid,
                                   fields => $fieldsARef,
                                 }
                               );
      }
    }
    else
    {
      $loggerMain->info( 'There are no duplicates of $cqId = ', $cqId );
    }

    my $interimBoolean = 0;

    if( $CM_Log and $cqState eq 'Opened' ) # check if this is an 'interim' record
    {
      my @CMLog_Array = split( "\n", $CM_Log );

      # scan from bottom. The last record inserted will indicate the
      # 'interim' state of the CQ
      #
      INTERIMLOOP: while( @CMLog_Array )
      {
        my $CMLogLine = pop @CMLog_Array;

        $loggerMain->info( '$CMLogLine = ', $CMLogLine );

        next INTERIMLOOP unless( $CMLogLine =~ /($cqIdPrefix\d+):(\w+)(?:\s|$)/ix );

          my $cqID   = $1;
          my $suffix = $2;

          $loggerMain->info( 'MATCHED: $cqID = ', $cqID );

          if( $suffix eq '' )
          {
            $loggerMain->info( 'MATCHED: $suffix = ', $suffix );
            $interimBoolean = 0;
            last INTERIMLOOP;
          }
          elsif( $suffix =~ /Interim/ix )
          {
            $loggerMain->info( 'MATCHED: $suffix = ', $suffix );
            $interimBoolean = 1;
            last INTERIMLOOP;
          }
      } # INTERIMLOOP

      $loggerMain->info( '$interimBoolean = ', $interimBoolean );

      next GETRECORD if( $interimBoolean == 1);

    } # if $CM_Log and 'Opened' state

    my $newState = $states{ $cqState };
    my $action   = $actions{ $cqState };

    $loggerMain->info ( 'Modifying... $cqId     = ', $cqId );
    $loggerMain->info ( 'From:        $cqState  = ', $cqState );
    $loggerMain->info ( 'To:          $newState = ', $newState );

    changeDefectState( $version, $cqId, \%dBRecord );

    print $changeStateCQs "$subroutine: \$cqId = $cqId FROM: \$cqState = $cqState TO: \$newState = $newState\n";

  }
  elsif( $cqState eq 'Integrated' )
  {
    $loggerMain->info( '$cqId    = ', $cqId );
    $loggerMain->info( '$cqState = ', $cqState );
    print $fixedCQs "$subroutine: \$cqId = $cqId \$cqState = $cqState\n";
  }
  elsif( $cqState eq 'Verified' or
         $cqState eq 'Closed'   or
         $cqState eq 'Rejected' or
         $cqState eq 'Suspended'
       )
  {
    $loggerMain->info( '$cqId    = ', $cqId );
    $loggerMain->info( '$cqState = ', $cqState );
    print $otherCQs "$subroutine: \$cqId = $cqId \$cqState = $cqState\n";
  }
  elsif( $cqState eq 'Duplicated' )
  {
    $loggerMain->info( '$cqId    = ', $cqId );
    $loggerMain->info( '$cqState = ', $cqState );
    print $otherCQs "$subroutine: \$cqId = $cqId \$cqState = $cqState\n";
  }
  else
  {
    $loggerMain->error( "CQ state not accounted for:  \$cqId = $cqId \$cqState = $cqState" );
  }

  return;

} # processCommittedRecords

sub getExcelData
{
  my $table  = shift; # 'Defect' table
  my $key    = shift; # $cqId
  my @fields = @_;    # everything we want in Excel report

  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  #my $logger = get_logger( $subroutine );
  #   $logger->level( $getExcelData_LogLevel );

  $loggerMain->info( '$table = ', $table);
  $loggerMain->info( '$key   = ', $key);
  $loggerMain->info( Dumper( @fields ) );

  my %defectRecord = $cq->get( $table, $key, @fields );

  my( $restStatus, $restMsg ) = checkRESTError();
  $loggerMain->error( '$restStatus = ', $restStatus ) unless( $restStatus == $REST_OK );
  $loggerMain->error( '$restMsg    = ', $restMsg )    if $restMsg;
  return unless( $restStatus == $REST_OK );

  my %excelData;
  $excelData{ $key } = \%defectRecord;
  $loggerMain->info( Dumper( %excelData ) );
  return \%excelData;

} # getExcelData

#
# findRecords -
# initially get records in implemented state; make it generic for any state
#
sub findRecords
{
  my $table     = shift;
  my $condition = shift;
  my @fields    = @_;   # at a minimum, @fields must contain 'id'

  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  #my $logger = get_logger( $subroutine );
  #
  #$logger->level( $findRecords_LogLevel );
  $loggerMain->info( '$table     = ', $table );
  $loggerMain->info( '$condition = ', $condition );
  $loggerMain->debug( Dumper( @fields ) );

  my( $result, $nbrRecs ) = $cq->find( $table, $condition, @fields );

  $loggerMain->info( '$nbrRecs = ', $nbrRecs );
  $loggerMain->info( '$result  = ', $result );

  my %CQIDsFound;

  # need to test number of records found - otherwise $testCq->getnext will error out
  if( $nbrRecs and $nbrRecs > 0 )
  {
    my $count = 0;
    GETRECORD: while( my %defectRecord = $cq->getNext( $result ) )
    {
      # defensive programming: Category_Type and/or may be undef...
      #
      my $is_Category      = $defectRecord{ 'Category' };
      my $is_Category_Type = $defectRecord{ 'Category_Type' };
      my $is_Sub_Category  = $defectRecord{ 'Sub-Category' };

      $is_Category      = ' ' unless defined $is_Category;
      $is_Category_Type = ' ' unless defined $is_Category_Type;
      $is_Sub_Category  = ' ' unless defined $is_Sub_Category;

      next GETRECORD if( $is_Category       eq 'Software' and
                         $is_Category_Type  eq 'Tools'
                       );

      my $cqID = $defectRecord{ id };
      $CQIDsFound{ $cqID } = $condition;
    }
  }
  else
  {
    $loggerMain->info( 'NO RECORDS FOUND' );
  }

  $loggerMain->debug( Dumper( %CQIDsFound ) );

  return \%CQIDsFound;

} # findRecords

sub changeDefectState
{
  my( $version, $idKey, $hashRef ) = @_;
  my( $subroutine ) = (caller(0))[3];

  local $| = 1;

  #my $logger = get_logger( $subroutine );
  #
  #$logger->level( $changeDefectState_LogLevel );

  my %dBRecord = %$hashRef;
  my %update;

  my $currentState = $dBRecord{ State };
  my $newState     = $states{ $currentState };
  my $action       = $actions{ $currentState };

  $loggerMain->debug( Dumper( %dBRecord ) );
  $loggerMain->debug( 'Modifying database record: $idKey        = ', $idKey );
  $loggerMain->debug( '                           $version      = ', $version );
  $loggerMain->debug( '                           $currentState = ', $currentState );
  $loggerMain->debug( '                           $action       = ', $action );
  $loggerMain->debug( '                           $newState     = ', $newState );


  if( $currentState eq 'Assigned'  or  # these states transition per the $states table
      $currentState eq 'Opened'    or  #   no need to update the Integrated_In_Versions field
      $currentState eq 'Submitted' )
  {
      %update = ( State => $newState, );
  }
  elsif( $currentState eq 'Implemented' or # these states transition per the $states table
         $currentState eq 'Duplicated' )   #   update the Integrated_In_Versions field
  {
    # ==>> $hashRef is passed into this sub without verification; it is dangerous to use ...

    if( $currentState eq 'Implemented' )
    {
      %update = ( State      => $newState,
                  Resolution => 'Fixed',
                );
    }
    else
    {
      %update = ( State => $newState, );
    }

    # this will add integrated_in_versions data, if it exists
    #
    my( $updateRequired, $updateHashRef ) = updateIiv( $version, $newState, $hashRef );
    if( $updateRequired )
    {
      my %temp = %$updateHashRef;         # dereference the dB record data
      %update  = ( %update, %temp );      #   concatenate hashes
    }
  }
  else
  {
    $loggerMain->debug( 'Not an updatable state: $currentState = ', $currentState );
    return;
  }

  # record update needs a valid 'Assignee'
  #   if the Assignee, which is an email name, is no longer an employee
  #     the SW lead is the Assignee
  #
  my $emailName      = $dBRecord{ Assignee };
  my $validEmailName = validateAssignee( $CQProject, $emailName );

  my %eMail = ( Assignee => $validEmailName, );
  %update   = ( %update, %eMail );  #   concatenate hashes

  $loggerMain->debug( 'Calling doAction: $idKey  = ', $idKey );
  $loggerMain->debug( '                  $action = ', $action );
  $loggerMain->debug( Dumper( %update ) );

  doAction( $idKey, $action, \%update ); # commit to the dB

  my %hash = (
               State                  => $newState, # the 'next' state for 'this' cqId
               Integrated_In_Versions => [],        # uses Hook for all states except 'Integrated'
              );

  unless( $currentState eq 'Integrated' ) # recurse until process is completed
  {
    $loggerMain->debug( 'Recursing changeDefectState: $idKey  = ', $idKey );
    $loggerMain->debug( Dumper( %hash ) );
    %update = ( %update, %hash );  #   concatenate hashes
    $loggerMain->debug( Dumper( %update ) );

    changeDefectState( $version, $idKey, \%update )
  }

  return;

} # changeDefectState

################################################################################
# validateAssignee - get Assignee from 'users' table
#
sub validateAssignee
{
  my $project   = shift;
  my $emailName = shift || 'admin';

  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  #my $logger = get_logger( $subroutine );
  #$logger->level( $validateAssignee_LogLevel );
  $loggerMain->debug( '$emailName : ', $emailName);

  if( $cq->find( 'users', "email=$emailName", qw( fullname ) ) )
  {
    $loggerMain->debug( "User email : ", $emailName );
    return $emailName;
  }
  else # get SW lead from config file
  {
    $loggerMain->debug( 'Unable to validate $emailName = ', $emailName );
    $loggerMain->debug( '$swLead      = ', $projectDataRef->{ $project }{ swLead }, "\n" );
    $loggerMain->debug( '$swLeadEmail = ', $projectDataRef->{ $project }{ swLeadEmail }, "\n" );
    return $projectDataRef->{ $project }{ swLeadEmail };
  }

  return 'admin'; # just in case

} # validateAssignee


sub doAction
{
  my( $key, $action, $hashRef ) = @_;
  my %params = %$hashRef;

  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  #my $logger = get_logger( $subroutine );
  #$logger->level( $doAction_LogLevel );

  $loggerMain->debug( "/\\" x 60 );
  $loggerMain->debug( '$key    = ', $key );
  $loggerMain->debug( '$action = ', $action );
  $loggerMain->debug( Dumper( %params ) );

  my $retryCount = 0;
  my $modifyResult;

  RETRYLOOP: while( $retryCount < $MAX_RETRIES ) # retries implemented because of occassional cqdB timeout experience
  {

    ############################################## TESTING #######################################################
    #given( $key )
    #  {
    #    when( 'MobC00223740' )
    #    {
    #      print "$subroutine ", __LINE__, ": \$key = $key\t\$action = $action\n" if $debugDoAction;
    #      print "$subroutine ", __LINE__, "\n", Dumper( %params ), if $debugDoAction;
    #
    #      ############################# for DEBUGGING on PRODUCTION #############################################
    #      ( $modifyResult )= $cq->modify( 'Defect', $key, $action, %params );
    #      checkRESTError()if $debugMain_Level_0;
    #      ############################# for DEBUGGING on PRODUCTION #############################################
    #    }
    #
    #    default
    #    {
    #      ############################# for DEBUGGING on PRODUCTION #############################################
    #      #$modifyResult = $cq->modify( 'Defect', $key, $action, %params );
    #      #checkRESTError()if $debugMain_Level_0;
    #      ############################# for DEBUGGING on PRODUCTION #############################################
    #
    #      $modifyResult = 'OK'; # for DEBUGGING on PRODUCTION
    #
    #    } # default
    #
    #  } # given
    ############################################## TESTING #######################################################

    if( $nonExecMode )                        # NONEXEC_MODE is an EC parameter
    {
      $loggerMain->debug( 'No CQdB update. $nonExecMode = ', $nonExecMode );
      $modifyResult = 'OK';                   # for DEBUGGING on PRODUCTION; does not update the CQ dB
    }
    else
    {
      $loggerMain->debug( 'CQdB update. $nonExecMode = ', $nonExecMode );
      ( $modifyResult ) = $cq->modify( 'Defect', $key, $action, %params );
    }

    last RETRYLOOP if $modifyResult eq 'OK' or
                      $modifyResult !~ /timeout/x;

      my( $restStatus, $restMsg ) = checkRESTError();
      $loggerMain->warn( '$restStatus   = ', $restStatus, ' $restMsg = ', $restMsg ) unless( $restStatus == $REST_OK );

      $loggerMain->warn( '$modifyResult = ', $modifyResult );

      sleep $SLEEP_VALUE;
      $retryCount++;

  } # RETRYLOOP

  if( $modifyResult eq 'OK' )
  {
    $doActionCount++;
  }
  elsif( $modifyResult =~ /Error/ix )
  {
    push @xCqId, $key;
    $statistics{ exceptions } += 1;

    $loggerMain->debug( '$key                      = ', $key );
    $loggerMain->error( '$action                   = ', $action );
    $loggerMain->error( '$modifyResult             = ', $modifyResult );

    $loggerMain->error( '$retryCount               = ', $retryCount );
    $loggerMain->error( '$statistics{ exceptions } = ', $statistics{ exceptions } );

    $loggerMain->error( Dumper( @xCqId ) );

  }
  else
  {
    carp 'CARP! Unaccounted for: $modifyResult = ', $modifyResult, "\n";
  }

  $statistics{ retries } += $retryCount if $retryCount > 0;

  $loggerMain->debug( '$doActionCount = ', $doActionCount );
  $loggerMain->debug( "/\\" x 60 );

  updateModifiedCQIDsHash( $key, $action, \%cqIdsProcessed );

  return;

} # doAction()

################################################################################
# findOrAddVersionRecord -
#
################################################################################
sub findOrAddVersionRecord
{
  my ($table, $versionString, $projectName, @fields) = @_;
  my( $subroutine ) = (caller(0))[3];

  local $| = 1;

  #my $logger = get_logger( $subroutine );
  #   $logger->level( $findOrAddVersionRecord_LogLevel );

  $loggerMain->debug( '$table         = ', $table );
  $loggerMain->debug( '$versionString = ', $versionString );
  $loggerMain->debug( '$projectName   = ', $projectName );
  $loggerMain->debug( Dumper( @fields ) );

  my( $result,     $nbrRecs ) = $cq->find( $table, "VersionStr=$versionString", @fields );
  my( $restStatus, $restMsg ) = checkRESTError();

  $loggerMain->debug( '$nbrRecs = ', $nbrRecs );
  $loggerMain->debug( '$result  = ', $result );

  $loggerMain->error( '$restStatus = ', $restStatus ) unless( $restStatus == $REST_OK );
  $loggerMain->error( '$restMsg    = ', $restMsg )    if $restMsg;

  if( $nbrRecs and $nbrRecs > 0 )  # $cq->getnext will generate error if $nbrRecs == 0
  {
    print "Record(s) exist ...\n" if $debugFindOrAddVersionRecord;

    if( $debugFindOrAddVersionRecord ) # verify for debug purposes
    {
      my $count = 0;
      while( my %dBRecord = $cq->getNext( $result ) )
      {
        my( $restStatus, $restMsg ) = checkRESTError();

        $loggerMain->warn( "\$restStatus : ", $restStatus) unless( $restStatus == $REST_OK );
        $loggerMain->debug( Dumper( %dBRecord ) );

        last if ++$count > 5; # limit the printout
      }
    }
  }
  else
  {
    $loggerMain->debug( 'No record found. Adding to $table = ', $table );

    #my $response = $cq->add( $table, (  VersionStr => $versionString,
    #                                    Projects   => {
    #                                                   Project => [$projectName],
    #                                                  },
    #                                  ),
    #                        );
    # 20130123 : interface seems to have changed.
    #            consider what to do for this version string under other projects
    #
    my %record = (
                    VersionStr => $versionString,
                    Projects   => [$projectName],
                  );

    my $response = $cq->add( $table, \%record );

    my( $restStatus, $restMsg ) = checkRESTError();
    $loggerMain->warn( '$restStatus   = ', $restStatus) unless( $restStatus == $REST_OK );
    $loggerMain->debug( 'add $response = ', $response );
  }
  return;
} # findOrAddRecord

################################################################################
# sub updateIiv - update Integrated-In-Version record
#
################################################################################
sub updateIiv
{
  my( $thisVersion, $newState, $dBRecordRef ) = @_;
  my( $subroutine ) = (caller(0))[3];

  local $| = 1;
  #my $logger = get_logger( $subroutine );
  #   $logger->level( $updateIiv_LogLevel );

  my %dBRecord                = %$dBRecordRef;
  my $currentState            = $dBRecord{ State };
  my $integratedInVersionsRef = $dBRecord{ Integrated_In_Versions };
  my @iivArray                = @$integratedInVersionsRef;

  $loggerMain->debug( '$thisVersion = ', $thisVersion );
  $loggerMain->debug( '$currentState    = ', $currentState );
  $loggerMain->debug( '$newState    = ', $newState );
  $loggerMain->debug( Dumper( %dBRecord ) );
  $loggerMain->debug( Dumper( $integratedInVersionsRef ) );
  $loggerMain->debug( Dumper( @iivArray ) );

  my $versionExists = 0;
  my %update;
  my $updatedIiv    = 0;

  if( @iivArray > 0 ) # if there is existing information in 'Integrated_In_Versions', capture it and rewrite with new
  {
    $loggerMain->debug( 'Integrated_In_Versions is NOT EMPTY' );

    chomp( @iivArray );
    while( my ($i, $v) = each @iivArray ) # version already in list?
    {
      print "$subroutine ", __LINE__, ": \@iivArray index: $i, value: $v\n" if $debugUpdateIiv;
      $versionExists = 1 if $v eq $thisVersion;
    }

    unless( $versionExists ) # append if current version not in list
    {
      $loggerMain->debug( 'current version not in list; APPENDING $thisVersion = ', $thisVersion );
      push @iivArray, $thisVersion; # append
      %update = (
                  State                  => $newState,
                  Integrated_In_Versions => {
                                              VersionInfo => \@iivArray
                                            },
                  );
      $updatedIiv = 1;
    }
    else
    {
      $loggerMain->debug( 'current version in list; NOT APPENDING $thisVersion = ', $thisVersion );
      $updatedIiv = 0;
    } # unless
  }
  else # add new version to empty list
  {
    $loggerMain->debug( 'Integrated_In_Versions is EMPTY' );
    %update = (
                State                  => $newState,
                Integrated_In_Versions => {
                           VersionInfo => [ $thisVersion ]
                },
              );
    $updatedIiv = 1;
  }

  $loggerMain->debug( 'Updated Integrated_In_Versions field...' );
  $loggerMain->debug( Dumper( %update ) );

  return $updatedIiv, \%update;
} # updateIiv


sub checkRESTError
{
  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  #my $logger = get_logger( $subroutine );
  #$logger->level( $checkRESTError_LogLevel );

  my $errNum = $cq->error();

  $loggerMain->debug( '$errNum = ', $errNum );

  my $errMsg;
  unless( $errNum == $REST_OK )
  {
    $errMsg = $cq->errmsg();
    $loggerMain->debug( '$errMsg = ', $errMsg);
  }
  return $errNum, $errMsg;
}


######################################################################
#
# Subroutine
#     open_ec_connection
#
# Description
#     opens the EC connection and turns off abortOnErorr
#
# Globals
#     $EC
#
# Returns
#
#
######################################################################
sub open_ec_connection
{
  # No need for params if invoked from a EC job step
  $EC = new ElectricCommander->new();

  # Turn abortOnError OFF...this prevents the API from dying on any
  #   error and lets you inspect error codes yourself
  $EC->abortOnError(1);

  return;
}

######################################################################
# Subroutine
#     get_info_from_ec
# Description
#     gets information from the open EC connection
# Globals
#     $EC
# Returns
#     updated %INPUT_VALUES based on @INPUT_FIELDS
######################################################################
sub get_info_from_ec
{
  # get everything in batch mode. One call to the server and we are done!
  my $batch = $EC->newBatch( 'parallel' );

  # loop our database for getting properties in batch mode...run batch command at the end
  foreach my $input( @INPUT_FIELDS )
  {
    $INPUT_VALUES{ $input } = $batch->getProperty( $input ); # these are ids; hash stores values
  }

  $batch->submit(); # get the data

  foreach my $input( @INPUT_FIELDS ) # get properties value
  {
    $INPUT_VALUES{ $input } = $batch->findvalue( $INPUT_VALUES{ $input }, 'property/value' )->value();
  }
  return;
}

######################################################################
# Subroutine
#     rmWorkingDir
# Description
#
# Globals
#
# Returns
#
######################################################################
sub rmWorkingDir
{
  my $dir = shift;
  my( $subroutine )   = (caller(0))[3];

  local $| = 1;

  print "$subroutine ", __LINE__, ": working directory is $dir\n" if $debugGetWorkingSetPath;

  if( -e $dir )
  {
    remove_tree( $dir );
    print "$subroutine ", __LINE__, ": deleted working directory $dir\n" if $debugGetWorkingSetPath;
  }
  return;
}

######################################################################
# Subroutine
#     createWorkingDir
# Description
#
# Globals
#
# Returns
#
######################################################################
sub createWorkingDir
{
  my $dir = shift;
  my( $subroutine )   = (caller(0))[3];

  local $| = 1;

  print "$subroutine ", __LINE__, ": working directory is $dir\n" if $debugCreateWorkingDir;

  # my $mkdirResponse = qx{ mkdir $dir };

  my $makePathResponse = make_path( $dir,
                                    { verbose => $debugCreateWorkingDir,
                                      error   => \my $err,
                                    }
                                   );

  print "$subroutine ", __LINE__, ": attempted to create directory $dir \$makePathResponse = $makePathResponse\n" if $debugCreateWorkingDir;

  if( @$err )
  {
    for my $diag( @$err )
    {
     my( $file, $message ) = %$diag;
     if( $file eq '' )
     {
      print "$subroutine ", __LINE__, "__ERROR__ : general error : \$message = $message\n";
     }
     else
     {
      print "$subroutine ", __LINE__, "__ERROR__ : creating \$file = $file : \$message = $message\n";
     }
    }
  }
  else
  {
    print "$subroutine ", __LINE__, ": No make_path error encountered \$dir = $dir\n" if $debugCreateWorkingDir;
  }
  return;
}

######################################################################
# Subroutine
#     getWorkingSetPath
# Description
#
# Globals
#
# Returns
#
######################################################################
sub getWorkingSetPath
{
  my( $subroutine )   = (caller(0))[3];
  local $| = 1;

  my $unameResponse = qx{ uname -n }; # get machine name
  chomp( $unameResponse );
  print "$subroutine ", __LINE__, ": \$unameResponse = $unameResponse\n" if $debugGetWorkingSetPath;

  my $wsPath;
  my $lsfMachine   = 'eca-sj1-02';               # for testing
  my $localMachine = qr/lc\-sj|xl\-sj/ix;        # for testing

  if( $unameResponse eq $lsfMachine or    # EC running this script on lsf queue, or
      $unameResponse =~ $localMachine )   #   local processor
  {
    $wsPath = '/tmp/cqChangeState';
  }
  else                                    # EC running this script on bsub queue
  {
    $wsPath = '/build/cqChangeState';
  }
 return $wsPath;
}

######################################################################
# Subroutine
#     trimWhitespace
# Description
#
# Globals
#
# Returns
#
######################################################################
sub trimWhitespace
{
  my $var = shift;
  $var =~ s/^\s+//x; # strip white space from the beginning
  $var =~ s/\s+$//x; # strip white space from the end
  return $var;
}

######################################################################
# Subroutine
#     updateModifiedCQIDsHash
# Description
#
# Globals
#
# Returns
#
######################################################################
sub updateModifiedCQIDsHash
{
  my( $pKey, $pAction, $pHashRef ) = @_;
  my( $subroutine ) = (caller(0))[3];

  local $| = 1;

  my %hash = %$pHashRef;           # when you dereference you lose the link to the global hash
  my @actionArray;

  if( exists $hash{$pKey} )        # if key exists, unpack array for update
  {
    my $arrayRef     = $hash{$pKey}{ Actions };
    @actionArray     = @$arrayRef;     # dereference array
    my $actionExists = ( (grep { $_ eq $pAction } @actionArray) ? 1 : 0 ); # outer parens required
    unless( $actionExists ) { push @actionArray, $pAction; }               # avoid duplicates; append current action
  }
  else                             # add the Key and Action
  {
    @actionArray = $pAction;       # add element to empty array
  }

  $hash{ $pKey }{ Actions } = \@actionArray;

  print "$subroutine ", __LINE__, ": ", Dumper( %hash ) if $debugUpdateModifiedCQIDsHash;

  %$pHashRef = %hash;              # assign local copy to the global

  return;
}

sub eMailMessage
{
  my $text = shift;

  Email::Stuff->to         ( 'dsass@corp.com'       )
              ->from       ( "$ENV{USER}\@corp.com" )
              ->subject    ( $script                   )
              ->text_body  ( $text                      )
              #->attach_file(                           )
              ->send;
  return;
}

sub getDate_Time
{
  my $t = shift || time;
  my( $subroutine ) = (caller(0))[3];
  local $| = 1;

  my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime( $t );

  $year += 1900;
  $mon++;

  my $yyyymmdd        = sprintf( '%d%02d%02d', $year, $mon, $mday );
  my $yyyymmdd_hhmmss = sprintf( '%d%02d%02d_%02d%02d%02d', $year, $mon, $mday, $hour, $min, $sec );
  my $mm_dd_yyyy      = sprintf( '%02d/%02d/%d', $mon, $mday, $year );

  push my @formattedTime, ( $yyyymmdd, $yyyymmdd_hhmmss, $mm_dd_yyyy );
  return \@formattedTime;
}

# retrieve Project data: SW lead name & SW lead email name
#                        from xml configuration file.
#
sub getProjectData
{
  my $doc = shift; # parser object
  my %hash;
  for my $projectNode( $doc->findnodes( '/projects/project' ) )
  {
    my $projectName = $projectNode->getAttribute( 'name' );

    $hash{ $projectName }{ swLead }      = $projectNode->getAttribute( 'swLead' );
    $hash{ $projectName }{ swLeadEmail } = $projectNode->getAttribute( 'swLeadEmail' );
  } # PROJECTLOOP

  return \%hash;

} #getProjectData

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
  my $dir = shift || '';

  unless( $dir )
  {
    if( $^O =~ /x$/ix ) # Unix or Linux
    {
      $dir = qx( pwd );
      $dir =~ s{(.*)$}{$1/}x;
    }
    elsif( $^O =~ /MSWin/ix )
    {
      $dir = qx( echo %cd% );
      $dir =~ s{(.*)$}{$1\\}x;
    }
    else
    {
      croak "CROAK! Operating system not recognized!: \$^O = ", $^O, "\n";
    }
  }

  $dir =~ s{\s+?}{}gx;
  chomp $dir;

  my $ext = qw( .log );
  my $logFileName = $dir . $script . '_log4perl' . $ext;

  # create a configuration definition
  #
  my $log_conf = qq(
                    log4perl.rootLogger              = DEBUG, LOG1, SCREEN
                    log4perl.appender.SCREEN         = Log::Log4perl::Appender::Screen
                    log4perl.appender.SCREEN.stderr  = 0
                    log4perl.appender.SCREEN.layout  = Log::Log4perl::Layout::PatternLayout
                    log4perl.appender.SCREEN.layout.ConversionPattern = %d %L %p %m %n
                    log4perl.appender.LOG1           = Log::Log4perl::Appender::File
                    log4perl.appender.LOG1.filename  = $logFileName
                    log4perl.appender.LOG1.mode      = write
                    log4perl.appender.LOG1.layout    = Log::Log4perl::Layout::PatternLayout
                    log4perl.appender.LOG1.layout.ConversionPattern = %d %L %p %m %n
                   );

  return \$log_conf;
}


sub createCommittedDataWorkbook
{
  my $pHRef = shift;

  my $PROJECT             = $pHRef->{ project        };
  my $manifest            = $pHRef->{ manifest       };
  my $committedCqIdsRef   = $pHRef->{ committedcqs   };

  my $file    = '_Committed_CQs.xlsx';
  my $cid     = 'tbd';

  my $BUILDDATE       = localtime(time);
     $BUILDDATE       =~ s/ /_/g;
     $BUILDDATE       =~ s/:/-/g;

  my $COMMITS   = 'tbd';

  my $CQIDs           = 'tbd';
  my $APPROVED_BY_CCB = 'tbd';
  my $CRITICAL_CQIDs  = 'tbd';
  my $MAJOR_CQIDs     = 'tbd';
  my $WITHOUT_CQIDs   = 'tbd';

  my $NONIMPLEMENTED_CQIDs     = 'tbd';
  my $NOTAPPROVED_BY_CCB       = 'tbd';
  my $CQIDS_INCORRECT_PROJECT  = 'tbd';
  my $CQIDS_INCORRECT_PLATFORM = 'tbd';

  my $extras = $FALSE;
  my @EXTRA;

  my $MAPPINGS = 'tbd';

  my $SDB   = $FALSE;

  local $| = 1;
  my( $subroutine ) = (caller(0))[3];

  $loggerMain->info( $subroutine, ' starting...' );

  my $timeFormatsRef   = getDate_Time( time );
  my $today_mm_dd_yyyy = $timeFormatsRef->[2];

  system( "rm -f ${excelDirectory}${newTag}${file}" ) if( -e $excelDirectory . $newTag . $file );

  my $cdWorkbook = Excel::Writer::XLSX->new( $excelDirectory . $newTag . $file );
  my $worksheet  = $cdWorkbook->add_worksheet( 'Committed Records' );

  $worksheet->set_landscape();
  $worksheet->repeat_rows(8,9);

  my $Title      = $cdWorkbook->add_format('color'     => 'navy','bold' => 1,'size' => 14);
  my $Bhead      = $cdWorkbook->add_format('color'     => 'white','bg_color' => 'black','bold' => 1,'size' => 10);
  my $bhead      = $cdWorkbook->add_format('color'     => 'white','bg_color' => 'black','bold' => 1,'size' => 10,'align' => 'center');
  my $Bframe     = $cdWorkbook->add_format('size'      => 10,'border' => 2,'border_color' => 'black');
  my $bframe     = $cdWorkbook->add_format('size'      => 10,'border' => 2,'border_color' => 'black','align' => 'center');
  my $bframe_red = $cdWorkbook->add_format('color'     => 'red','size' => 10,'border' => 2,'border_color' => 'black','align' => 'center');
  my $git        = $cdWorkbook->add_format('bg_color'  => 'cyan','color' => 'black','bold' => 1,'size' => 12,'align' => 'top','border' => 1,'border_color' => 'black');
  my $clearquest = $cdWorkbook->add_format('bg_color'  => 'lime','color' => 'black','bold' => 1,'size' => 12,'align' => 'top','border' => 1,'border_color' => 'black');
  my $git_head   = $cdWorkbook->add_format('bg_color'  => 'blue','color' => 'white','bold' => 1,'size' => 10,'align' => 'top','align' => 'center','border' => 1,'border_color' => 'black');
  my $extra_head = $cdWorkbook->add_format('bg_color'  => 'yellow','color' => 'black','bold' => 1,'size' => 10,'align' => 'top','align' => 'center','border' => 1,'border_color' => 'black');
  my $cq_head    = $cdWorkbook->add_format('bg_color'  => 'green','color' => 'white','bold' => 1,'size' => 10,'align' => 'top','align' => 'center','border' => 1,'border_color' => 'black');
  my $rb_head    = $cdWorkbook->add_format('bg_color'  => 'brown','color' => 'white','bold' => 1,'size' => 10,'align' => 'top','border' => 1,'border_color' => 'black');
  my $cqid       = $cdWorkbook->add_format('bg_color'  => 'yellow','color' => 'black','bold' => 1,'size' => 12,'align' => 'top','align' => 'center','border' => 1,'border_color' => 'black');
  my $rb         = $cdWorkbook->add_format('bg_color'  => 'orange','color' => 'black','bold' => 1,'size' => 12,'align' => 'top','border' => 1,'border_color' => 'black');
  my $extra      = $cdWorkbook->add_format('bg_color'  => 'yellow','color' => 'black','bold' => 1,'size' => 10,'align' => 'top','border' => 1,'border_color' => 'black');
  my $Color3     = $cdWorkbook->add_format('color'     => 'red','align' => 'top');
  my $text       = $cdWorkbook->add_format('text_wrap' => 1,'align' => 'top');
  my $text_right = $cdWorkbook->add_format('text_wrap' => 1,'align' => 'top');

  $text_right->set_align('right');

  my $top        = $cdWorkbook->add_format('align' => 'top');
  my $topCenter  = $cdWorkbook->add_format('align' => 'top', 'align' => 'center');

  if( $SDB ) {
       $worksheet->merge_range(0,0,0,5,"SDB $manifest : Product CCB: CLs SDB SDBP Propagation Map - $BUILDDATE", $Title);
  } else {
       $worksheet->merge_range(0,0,0,5,"[$manifest] - Android Daily GIT Commits and Associated Defect-IDs from ClearQuest - $BUILDDATE", $Title);
  }

  $worksheet->merge_range(2,2,2,3,'Metric',$Bhead);
  $worksheet->write(2,4,'Count',$bhead);
  $worksheet->merge_range(3,2,3,3,'Number of GIT Commits (CommitID)',$Bframe);
  $worksheet->write(3,4,$COMMITS,$bframe);
  $worksheet->merge_range(4,2,4,3,'Number of ClearQuest Entries (CQID)',$Bframe);
  $worksheet->write(4,4,$CQIDs,$bframe);
  $worksheet->merge_range(5,2,5,3,'Number of CQIDs Approved By CCB',$Bframe);
  $worksheet->write(5,4,$APPROVED_BY_CCB,$bframe);
  $worksheet->merge_range(6,2,6,3,'Number of Critical CQIDs',$Bframe);
  $worksheet->write(6,4,$CRITICAL_CQIDs,$bframe);
  $worksheet->merge_range(7,2,7,3,'Number of Major CQIDs',$Bframe);
  $worksheet->write(7,4,$MAJOR_CQIDs,$bframe);

  if( !$SDB )
  {
    $worksheet->merge_range(2,6,2,8,'Non-Compliance Metric',$Bhead);
    $worksheet->write(2,9,'Count',$bhead);
    $worksheet->merge_range(3,6,3,8,'Number of CommitID Without CQIDs',$Bframe);

    if( $WITHOUT_CQIDs ) {
         $worksheet->write(3,9,$WITHOUT_CQIDs,$bframe_red);
    } else {
         $worksheet->write(3,9,$WITHOUT_CQIDs,$bframe);
    }

    $worksheet->merge_range( 4,6,4,8,'Number of CQIDs in Non-Implemented State', $Bframe);

    if( $NONIMPLEMENTED_CQIDs ) {
         $worksheet->write(4,9,$NONIMPLEMENTED_CQIDs,$bframe_red);
    } else {
         $worksheet->write(4,9,$NONIMPLEMENTED_CQIDs,$bframe);
    }

    $worksheet->merge_range(5,6,5,8,'Number of CQIDs NOT Approved by CCB',$Bframe);

    if( $NOTAPPROVED_BY_CCB ) {
         $worksheet->write(5,9,$NOTAPPROVED_BY_CCB,$bframe_red);
    } else {
         $worksheet->write(5,9,$NOTAPPROVED_BY_CCB,$bframe);
    }

    $worksheet->merge_range(6,6,6,8,'Number of CQIDs With Incorrect Project Name',$Bframe);
    if( $CQIDS_INCORRECT_PROJECT ) {
         $worksheet->write(6,9,$CQIDS_INCORRECT_PROJECT,$bframe_red);
    } else {
         $worksheet->write(6,9,$CQIDS_INCORRECT_PROJECT,$bframe);
    }

    $worksheet->merge_range(7,6,7,8,'Number of CQIDs With Incorrect Platform Name',$Bframe);

    if( $CQIDS_INCORRECT_PLATFORM )
    {
      $worksheet->write(7,9,$CQIDS_INCORRECT_PLATFORM,$bframe_red);
    }
    else
    {
      $worksheet->write(7,9,$CQIDS_INCORRECT_PLATFORM,$bframe);
    }
  }

  my $row             = 10; # Row,Column
  my $col             = 0;

  $worksheet->merge_range($row,$col,$row,($col+7),'GIT',$git);
  $col += 8;

  if( $extras )
  {
    foreach my $name (@EXTRA)
    {
         $worksheet->merge_range($row,$col,$row+1,$col,$name,$extra);
         $worksheet->set_column($col,$col++,(length($name)*2));
    }
  }

  if( $SDB )
  {
    $worksheet->merge_range($row,$col,$row,($col+4),'ClearQuest',$clearquest);
  }
  else
  {
    $worksheet->merge_range($row,$col,$row,($col+13),'ClearQuest',$clearquest);
  }

  $row++;
  $col = 0;

  $worksheet->write($row,$col,'Commit ID',$git_head);
  $worksheet->set_column($col,$col++,12);
  $worksheet->write($row,$col,'Component Name',$git_head);
  $worksheet->set_column($col,$col++,24);
  $worksheet->write($row,$col,'Date',$git_head);
  $worksheet->set_column($col,$col++,25);
  $worksheet->write($row,$col,'Creator',$git_head);
  $worksheet->set_column($col,$col++,40);
  $worksheet->write($row,$col,'Problem',$git_head);
  $worksheet->set_column($col,$col++,50);
  $worksheet->write($row,$col,'Solution',$git_head);
  $worksheet->set_column($col,$col++,50);
  $worksheet->write($row,$col,'# of Files',$git_head);
  $worksheet->set_column($col,$col++,10);
  $worksheet->write($row,$col,'# of Lines',$git_head);
  $worksheet->set_column($col,$col++,20);

  $col += $extras;

  $worksheet->write($row,$col,'CQID',$cqid);
  $worksheet->set_column($col,$col++,14);

  if ($SDB)
  {
    $worksheet->write($row,$col,'Product Migration',$cq_head);
    $worksheet->set_column($col,$col++,25);
    $worksheet->write($row,$col,'Platform',$cq_head);
    $worksheet->set_column($col,$col++,20);
    $worksheet->write($row,$col,'Title',$cq_head);
    $worksheet->set_column($col,$col++,25);
    $worksheet->write($row,$col,'Category Type',$cq_head);
    $worksheet->set_column($col,$col++,15);
  }
  else
  {
    $worksheet->write($row,$col,'Approved by CCB',$cq_head);
    $worksheet->set_column($col,$col++,17);
    $worksheet->write($row,$col,'Severity',$cq_head);
    $worksheet->set_column($col,$col++,11);
    $worksheet->write($row,$col,'State',$cq_head);
    $worksheet->set_column($col,$col++,11);
    $worksheet->write($row,$col,'Project',$cq_head);
    $worksheet->set_column($col,$col++,12);
    $worksheet->write($row,$col,'Title',$cq_head);
    $worksheet->set_column($col,$col++,25);
    $worksheet->write($row,$col,'Priority',$cq_head);
    $worksheet->set_column($col,$col++,20);
    $worksheet->write($row,$col,'Category Type',$cq_head);
    $worksheet->set_column($col,$col++,15);
    $worksheet->write($row,$col,'Assignee Fullname',$cq_head);
    $worksheet->set_column($col,$col++,25);
    $worksheet->write($row,$col,'Submitter Username',$cq_head);
    $worksheet->set_column($col,$col++,19);
    $worksheet->write($row,$col,'Submit Date',$cq_head);
    $worksheet->set_column($col,$col++,20);
    $worksheet->write($row,$col,'Platform',$cq_head);
    $worksheet->set_column($col,$col++,20);
    $worksheet->write($row,$col,'Entry Type',$cq_head);
    $worksheet->set_column($col,$col++,12);
    $worksheet->write($row,$col,'IMS Case ID',$cq_head);
    $worksheet->set_column($col,$col++,12);
  }

  $row++;
  $col = 0;

  # @g_dataArray holds has references to git-specific data
  #
  my $platform;
  my $reponame;
  my $componentRef;
  my $commitTime;

  #4049 INFO $platform   = AP
  #4050 INFO $reponame   = repo_aosp/platform/packages/apps/Contacts
  #4051 INFO $commitTime = Wed Jan 2 2013 09:20:11 PM -0800
  #4052 INFO $component  = SCALAR(0xa1ed0d8)
  #4053 INFO

  #for my $hashRef( @g_dataArray )
  #{
  #  for my $commitKey( keys %$hashRef )
  #  {
  #    $platform     = $hashRef->{$commitKey}{platform};
  #    $reponame     = $hashRef->{$commitKey}{reponame};
  #    $componentRef = $hashRef->{$commitKey}{component};
  #    $commitTime   = $hashRef->{$commitKey}{committime};
  #  }
  #
  #  $loggerMain->info( '$platform      = ', $platform );
  #  $loggerMain->info( '$reponame      = ', $reponame );
  #  $loggerMain->info( '$commitTime    = ', $commitTime );
  #  $loggerMain->info( '$componentRef  = ', $componentRef );
  #  $loggerMain->info( "\n" );
  #
  #}


  # committed cqIds
  #
  #4060 INFO $committedCqIdsRef = {
  #                     'MobC00271655' => '46f2d759a4fdb1dbec40fee2bd706afee47f8c34',
  #                     'MobC00271604' => '81686bcfffdae2806af5f6c988eb7d9230bc8e20',
  #                     'MobC00271649' => 'f1f5e7d84da8bab954f8cfed03835d624bd10908',
  #                     'MobC00269697' => 'b23b7bd403bedcb476ba5016bd4583e028a125e6',
  #                     'MobC00271561' => '03285f7e8f029d3294e207d1019c68746db8c7c4'
  #                   };
  #
  #$loggerMain->info( Dumper( $committedCqIdsRef ) );


  OUTERLOOP: while( my ($cqId, $gitId ) = each %$committedCqIdsRef )
  {
    $loggerMain->info( '$cqId  = ', $cqId );
    $loggerMain->info( '$gitId = ', $gitId );

    DATALOOP: for my $hashRef( @g_dataArray )
    {
      for my $commitKey( keys %$hashRef )
      {
        next DATALOOP unless $commitKey eq $gitId;

          $platform     = $hashRef->{$commitKey}{platform};
          $reponame     = $hashRef->{$commitKey}{reponame};
          $componentRef = $hashRef->{$commitKey}{component};
          $commitTime   = $hashRef->{$commitKey}{committime};

          $loggerMain->debug( '$commitKey     = ', $commitKey );
          $loggerMain->debug( '$platform      = ', $platform );
          $loggerMain->debug( '$reponame      = ', $reponame );
          $loggerMain->debug( '$commitTime    = ', $commitTime );
          $loggerMain->debug( Dumper( $componentRef ) );
          $loggerMain->debug( "\n" );

          my $component = $$componentRef;

          # extract details from the component
          #
          my( $author )       = $component =~ /^Author:\s+(.+)/m;
          $loggerMain->debug( Dumper( $author ) );

          my( $local_date )    = $component =~ /^Date:\s+(.+)/m;
          $loggerMain->debug( Dumper( $local_date ) );

          #my @Date          = split(/ /,$local_date);
          #$local_date       = $Date[1] . ' ' . $Date[2] . ', ' . $Date[4] . ' ' . $Date[3];

          my( $problem )       = $component =~ /.*?\n\s*\[Problem\]\s*?\n(.+?)\n\s*\[Solution\]\s*?\n/s;
          $loggerMain->debug( Dumper( $problem ) );

          my( $solution )      = $component =~ /.*?\n\s*\[Solution\]\s*?\n(.+?)\n\s*\[Reviewers\]\s*?\n/s;
          $loggerMain->debug( Dumper( $solution ) );

          my( $merge )         = $component =~ /^Merge:\s+(.+)/m;
          $loggerMain->debug( Dumper( $merge ) );

          if( $merge )
          {
            $solution       = $component =~ /\n\n(.+?)\n\n/s;
            $problem        = "Merged: $merge";
          }
          elsif( !$problem && !$solution)
          {
            $problem = $component =~ /\n\n(.+?)\n\n/s;
            if( !$problem )
            {
              $problem = $component =~ /\n\n(.+?)\n/s;
            }
          }

          my( $notes )          = $component =~ /\[corp INTERNAL NOTES\]\n(.+)/s;
          $loggerMain->debug( Dumper( $notes ) );

          # 1 files changed, 7 insertions(+), 4 deletions(-)
          #
          my( $changes )        = $component =~ /(\d+) files changed/;
          my( $insertions )     = $component =~ /(\d+) insertions/;
          my( $deletions )      = $component =~ /(\d+) deletions/;

          my $lines             = $changes + $insertions + $deletions;

          my( @count )          = $notes =~ /\S+\s+\|\s+(\d+)\s+[\+\-]/g;
          my $files             = scalar( @count );

          $loggerMain->info( "Generating Excel row for $commitKey..." );

          # git commit information
          #
          $worksheet->write_string($row,$col++,substr($commitKey,0,8),$top);
          $worksheet->write($row,$col++,$reponame,$top);
          $worksheet->write($row,$col++,$commitTime,$top);
          $worksheet->write($row,$col++,$author,$top);
          $worksheet->write($row,$col++,$problem,$text);
          $worksheet->write($row,$col++,$solution,$text);
          $worksheet->write($row,$col++,$files,$topCenter);
          $worksheet->write($row,$col++,$lines,$topCenter);

          # CQ information
          #
          my @excelRecordFields = qw( Approved_by_CCB
                                      Severity
                                      State
                                      Project
                                      Title
                                      Priority
                                      Category_Type
                                      Assignee
                                      Submitter
                                      Submit_Date
                                      Platform
                                      Entry_Type
                                      IMS_Case_ID
                                    );

          $loggerMain->info( "Starting dB query for Excel data..." );

          $excelDataHashRef = getExcelData( 'Defect', $cqId, @excelRecordFields );

          my $approvedByCCB = $excelDataHashRef->{ $cqId }{ Approved_by_CCB };
             $approvedByCCB = $approvedByCCB ? 'Yes' : 'No';


          my $severity      = $excelDataHashRef->{ $cqId }{ Severity };
          my $state         = $excelDataHashRef->{ $cqId }{ State };
          my $project       = $excelDataHashRef->{ $cqId }{ Project };
          my $title         = $excelDataHashRef->{ $cqId }{ Title };
          my $priority      = $excelDataHashRef->{ $cqId }{ Priority };
          my $categoryType  = $excelDataHashRef->{ $cqId }{ Category_Type };

          my $assignee      = $excelDataHashRef->{ $cqId }{ 'Assignee' };

          my $assigneeFullname;
          my $assigneeemail;

          if( $assignee )
          {
            $loggerMain->debug( '$assignee = ', $assignee );

            my %assignee = $cq->get( 'users', $assignee, qw( fullname email ) );

            $assigneeFullname = $assignee{ fullname };
            $assigneeemail    = $assignee{ email    };

            $loggerMain->debug( '$assigneeFullname = ', $assigneeFullname );
            $loggerMain->debug( '$assigneeemail    = ', $assigneeemail );
          }
          else
          {
            $assigneeFullname = 'Not defined';
            $assigneeemail    = 'Not defined';
          }

          my $submitter     = $excelDataHashRef->{ $cqId }{ 'Submitter' };

          my $submitterFullname;
          my $submitterEmail;
          my $submitterLogin;

          if( $submitter )
          {
            my %submitter   = $cq->get( 'users', $submitter, qw( fullname email login_name ) );

            $submitterFullname = $submitter{ fullname   };
            $submitterEmail    = $submitter{ email      };
            $submitterLogin    = $submitter{ login_name };

            $loggerMain->debug( '$submitter         = ', $submitter   );
            $loggerMain->debug( '$submitterFullname = ', $submitterFullname );
            $loggerMain->debug( '$submitteremail    = ', $submitterEmail );
            $loggerMain->debug( '$submitterLogin    = ', $submitterLogin );
          }
          else
          {
            $submitterFullname = 'Not defined';
            $submitterEmail    = 'Not defined';
            $submitterLogin    = 'Not defined';
          }

          my $submitDate    = $excelDataHashRef->{ $cqId }{ Submit_Date };
          my $platform      = $excelDataHashRef->{ $cqId }{ Platform };
          my $entryType     = $excelDataHashRef->{ $cqId }{ Entry_Type };
          my $IMSCaseID     = $excelDataHashRef->{ $cqId }{ IMS_Case_ID };
             $IMSCaseID     = 'Not defined' unless $IMSCaseID;

          $worksheet->write($row,$col++,$cqId,$top);
          $worksheet->write($row,$col++,$approvedByCCB,$topCenter);
          $worksheet->write($row,$col++,$severity,$top);
          $worksheet->write($row,$col++,$state,$top);
          $worksheet->write($row,$col++,$project,$top);
          $worksheet->write($row,$col++,$title,$top);
          $worksheet->write($row,$col++,$priority,$top);
          $worksheet->write($row,$col++,$categoryType,$top);
          $worksheet->write($row,$col++,$assigneeFullname,$top);
          $worksheet->write($row,$col++,$submitterLogin,$top);
          $worksheet->write($row,$col++,$submitDate,$top);
          $worksheet->write($row,$col++,$platform,$top);
          $worksheet->write($row,$col++,$entryType,$top);
          $worksheet->write($row,$col++,$IMSCaseID,$top);

          $row++;
          $col = 0;

        next OUTERLOOP;

      } # for $commitKey

    } # DATALOOP

  } # OUTERLOOP

  $loggerMain->info( 'Completed generating Committed Data Excel file' );

  $cdWorkbook->close();

  return;
}

__END__

=pod

=head1 NAME

change_cq_states.pl - Perl script for Integrated State Change (in build repos) launched via Electric Commander.

=head1 SYNOPSIS

<TBS>

=head1 RUN INSTRUCTIONS

  How to run change_cq_states.pl from Electric Commander:

  In EC navigate to -
    Projects: MobCom SW Build
    Procedure: change-cq-states

=head1 REQUIREMENTS

=head2 ORIGINAL

=head3 LISTS

=over 3

=item List 1

  This is a Hybrid Build System (HBS). There is no distinction between AP/CP.
  Get a list of [all] CQ commits. Combine ap (git) and cp (p4) CQID [commit] lists.
  This list represents ALL commits between the two tags [for all projects].

=item List 2

  Create a list of CQs from the CQ dB that are in 'implemented' state for the given platform (project).

=item Remainder

  The rest will be flagged for review:

=over 3

=item a.

CQs in List2 but not in List1

=item b.

Commits between 2 tags that don't have an associated CQ

=back

=back

=head2 ADDITIONAL REQUIREMENTS

  20121022: Ignore CQ records with:
              Category      eq Software
              Category_Type eq Tools
              Sub-Category  eq MTT (Mobile Tracking Tool)
            Do not change state of these records.

=head1 SEE ALSO

=head2 JIRA: MPGSWCM-1317 SI Release ClearQuest Implement to Integrate Refactor (Description and Comments)

TBD

=head2 JIRA: MPGSWCM-1222 Integrate State Change via REST (Description and Comments)

TBD

=head1 AUTHOR

Dennis Sass, E<lt>dsass@corp.com<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by corp, Inc.

<License TBD>

=cut
