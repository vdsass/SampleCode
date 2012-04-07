#!c:\Perl\bin\perl5.10.0.exe
#
# genSLOC.pl --iniFile dirpath\filename.txt --debug [0-10]
#   generate Source Lines of Code (SLOC) from a Rhapsody model:
#   1) create directories in ClearCase 7.x.x VOB for SLOC generated from a model
#   2) create directories as final target of SLOC
#   3) run RhapsodyCL.exe (command-line) against a model to generate SLOC
#   4) copy generated code
#
#   INPUTS:
#       Command line parameters: following are optional
#                          --debug [0-10] prints debug to STDOUT and a logfile
#                          --iniFile script environment keyword/parameter file
#                                    defaults to script run directory $Bin\genSLOC.txt

use strict;
use warnings;
use Cwd;
use Getopt::Long;
use File::Find;
use File::Copy;

use FindBin qw($Bin);
$Bin =~ s^/^\\^g;

use File::Path;
use File::stat;

# locally defined modules
use Get_DT;
use Debug_P;

my $DebugLevel   = 2;             # default is to print little or nothing
my $iniFile      = "";
my $perlScript   = $0;

my $sb = stat($perlScript);
my $perlScriptStat = sprintf "Running perlScript %s, Modified on %s\n",
                     $perlScript, scalar localtime $sb->mtime;

GetOptions ('inifile=s' => \$iniFile,
            'debug=s'   => \$DebugLevel,
            );

my $kwFile = $iniFile;
open(KW_FILE, "$kwFile") || die ("Can't open keyword file: $kwFile\n");

my(%csc_info) = ();
my($key,$value) = ('','');

while (<KW_FILE>) {
    chomp;
    ($key,$value)   = split(/=/,$_);
    $csc_info{$key} = $value;
}

close(KW_FILE);

my $model_root = "";
my $sloc_root  = "";
my $csc_name   = "";
my $rpy_name   = "";

foreach $key (keys (%csc_info)) {
    $model_root = $csc_info{$key} if ($key eq "MODEL_ROOT");
    $sloc_root  = $csc_info{$key} if ($key eq "SLOC_ROOT");
    $csc_name   = $csc_info{$key} if ($key eq "CSC_NAME");
    $rpy_name   = $csc_info{$key} if ($key eq "RPY_NAME");
}

my $log_File = $Bin."\\".$csc_name."_genSLOCpl.log";

open(LOG_FILE, "> $log_File") || die ("Can't open log file: $log_File\n");

my($yymmdd, $run_time, $hour, $min, $sec) = Get_DT::get_DT();

if ($model_root eq "" or $sloc_root eq "" or $csc_name eq "" or $rpy_name eq "" ) {
    debugp (0, "genSLOC.pl - ERROR! A KEYWORD is empty. Check the keyword file.\n");
    exit;
}

Debug_P::debugp (\*LOG_FILE, $DebugLevel,1, "$perlScriptStat\n");
Debug_P::debugp (\*LOG_FILE, $DebugLevel,3, "Log file is $log_File\n");
Debug_P::debugp (\*LOG_FILE, $DebugLevel,1, "DATE: $yymmdd\t $run_time\n");
Debug_P::debugp (\*LOG_FILE, $DebugLevel,1, "COMMAND LINE IS:\n\tiniFile: $iniFile\n\tDebugLevel: $DebugLevel\n");
Debug_P::debugp (\*LOG_FILE, $DebugLevel,3, "genSLOC.pl - model_root = " . $model_root . "\n");
Debug_P::debugp (\*LOG_FILE, $DebugLevel,3, "genSLOC.pl - sloc_root  = " . $sloc_root . "\n");
Debug_P::debugp (\*LOG_FILE, $DebugLevel,3, "genSLOC.pl - csc_name   = " . $csc_name . "\n");
Debug_P::debugp (\*LOG_FILE, $DebugLevel,3, "genSLOC.pl - rpy_name   = " . $rpy_name . "\n");

# create directories in ClearCase if they don't exist
# define the component and configuration directories
# ... these are coincident with the Rhapsody model
#
my (@slocDirs) = ("_Common_SLOC\\CommonSLOC\\",
                  "_Developed_SLOC\\DevelopedSLOC\\",
                  "_IDL_SLOC\\IDLSLOC\\"
                  );

my $model_path = $model_root."\\".$csc_name;
my $sloc_path  = $sloc_root."\\".$csc_name;

foreach my $suffix (@slocDirs) {

  my $fullModel_path = $model_path.$suffix;    # append tail of the tree
  my $fullSloc_path  = $sloc_path.$suffix;

  # if the directory tree exists, delete it and all files within, then create it
  # otherwise, create the tree
  #
  if (-e $fullModel_path) {

    rmtree( $fullModel_path );
    Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "genSLOC.pl - ".$fullModel_path." deleted.\n");

    mkpath( $fullModel_path );
    Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "genSLOC.pl - ".$fullModel_path." created.\n");

  } else {

    mkpath( $fullModel_path );
    Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "genSLOC.pl - ".$fullModel_path." created.\n");

  };

  if (-e $fullSloc_path) {

    rmtree( $fullSloc_path );
    Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "genSLOC.pl - ".$fullSloc_path." deleted.\n");

    mkpath( $fullSloc_path );
    Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "genSLOC.pl - ".$fullSloc_path." created.\n");

  } else {

    mkpath( $fullSloc_path );
    Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "genSLOC.pl - ".$fullSloc_path." created.\n");

  };

  $fullModel_path = "";
  $fullSloc_path  = "";

 }

# Run Rhapsody model to create SLOC
#   backticks execute an external command
#
my $cmd1 = "-cmd=open $model_root\\$rpy_name.rpy";
my $cmd2 = "-cmd=setlog $model_root\\genSLOC.log";
my $cmd3 = "-cmd=regenerate $csc_name"."_Common_SLOC CommonSLOC";
my $cmd4 = "-cmd=regenerate $csc_name"."_Developed_SLOC DevelopedSLOC";
my $cmd5 = "-cmd=regenerate $csc_name"."_IDL_SLOC IDLSLOC";
my $cmd6 = "-cmd=exit";
my $temp_cmd = "C:\\Rhapsody\\RhapsodyCL.exe $cmd1 $cmd2 $cmd3 $cmd4 $cmd5 $cmd6";

Debug_P::debugp (\*LOG_FILE, $DebugLevel,6, "rhapsody_cmd is $temp_cmd");
my @rhapsody_cmd = `"C:\\Rhapsody\\RhapsodyCL.exe $cmd1 $cmd2 $cmd3 $cmd4 $cmd5 $cmd6"`;

foreach my $response (@rhapsody_cmd) {
   Debug_P::debugp (\*LOG_FILE, $DebugLevel,6, "\nrhapsody_cmd_response: $response\n");
}

# prepare for IDL processing
#
Debug_P::debugp (\*LOG_FILE, $DebugLevel,9, "start IDL processing. Set OE_HOME=Z:\\NGC_AMF_Tools\\ois\\ORBexpress\n");

$ENV{"OE_HOME"} = "Z:\\NGC_AMF_Tools\\ois\\ORBexpress";

my @idl_directory = $model_path.$slocDirs[2];

Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "genSLOC.pl - Attempting to delete .h and .cpp files from IDLSLOC\n");
find(\&delete_h, @idl_directory);
find(\&delete_cpp, @idl_directory);

my $idl_fileCount = 0;
my %idl_fileList  = ();

find(\&scan_idl, @idl_directory);

foreach my $key ( sort keys %idl_fileList ) {
  Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "found file: $idl_fileList{$key}\n");
};

chdir $idl_directory[0];
Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "chdir: $idl_directory[0]\n");

my @idl2cpp_status = ();
my $cmd_path       = "Z:\\Tools\\ois\\ORBexpress\\RT_2.6.4\\host\\x86-winnt\\bin\\idl2cpp.cmd";
my $include_path   = "Z:\\Interface\\Code\\SCA_API\\Source\\Sca_x86_Win32_OE264\\Debug\\";

foreach my $idl_file ( sort keys %idl_fileList ) {
  Debug_P::debugp (\*LOG_FILE, $DebugLevel,5, "running idl2cpp.cmd: $cmd_path -bm -fxcpp -q -m -a -i$include_path $idl_fileList{$idl_file}\n");
  my $idl2cpp_cmd = "$cmd_path -bm -fxcpp -q -m -a -i$include_path $idl_fileList{$idl_file}";

  @idl2cpp_status = `"$idl2cpp_cmd"`;

  foreach my $result ( @idl2cpp_status ) {
    Debug_P::debugp (\*LOG_FILE, $DebugLevel,6, "idl2cpp status: $result");
  };
}

my @copy_directory = ();
my $copySloc_path  = "";

foreach my $suffix (@slocDirs) {

  my $fullModel_path = $model_path.$suffix;    # append tail of the tree
  my $fullSloc_path  = $sloc_path.$suffix;

  $copySloc_path     = $sloc_path.$suffix;
  @copy_directory    = ($fullModel_path);

  find(\&copyFiles, @copy_directory);

  $fullModel_path = "";
  $fullSloc_path  = "";
  $copySloc_path  = "";
}

chdir $model_root;

close LOG_FILE;
exit;

sub copyFiles() {
	if ( -f and /\.h$/ or -f and /\.cpp$/ or -f and /\.idl$/) {
      Debug_P::debugp (\*LOG_FILE, $DebugLevel,7, "copy: $_ to $copySloc_path\n");
      copy( $_, $copySloc_path ) or die "Copy failed, $!";
	}
}

sub delete_h() {
	if ( -f and /\.h$/ ) {
        unlink $File::Find::dir.$_;
        Debug_P::debugp (\*LOG_FILE, $DebugLevel,7, "deleted file: $File::Find::dir$_\n");
	}
	return;
}

sub delete_cpp() {
	if ( -f and /\.cpp$/ ) {
        unlink $File::Find::dir.$_;
        Debug_P::debugp (\*LOG_FILE, $DebugLevel,7, "deleted file: $File::Find::dir$_\n");
	}
	return;
}

sub scan_idl() {
	if ( -f and /\.idl$/ ) {
		# use file count as hash key
		$idl_fileCount++;
		$idl_fileList{$idl_fileCount} = $File::Find::dir.$_;
	}
	return;
}
