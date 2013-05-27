#!/usr/bin/perl
use warnings;
use strict;

use Carp;
use Data::Dumper::Simple;

use English;

use feature qw(switch);
use File::Path qw(make_path remove_tree);
use FindBin qw($Bin);

use Getopt::Long;

use Log::Log4perl qw( get_logger :levels );

use Readonly;

use Sys::Hostname;

use Storable qw( dclone ); # deep copy array w/refs

use Template;

use utf8;

use XML::LibXML;

local $| = 1;
my( $script )   = $FindBin::Script =~ /(.*)\.pl$/x;

my( $TRUE, $FALSE,
    $g_currentDir, $g_logDir,
    $dataFilePath, $configFilePath, $logLevel, $debug, $help,
    $CRITICAL_CPP_THRESHOLD,   $MAJOR_CPP_THRESHOLD,   $MINOR_CPP_THRESHOLD,
    $CRITICAL_JAVA_THRESHOLD,  $MAJOR_JAVA_THRESHOLD,  $MINOR_JAVA_THRESHOLD,
    $CRITICAL_MODEM_THRESHOLD, $MAJOR_MODEM_THRESHOLD, $MINOR_MODEM_THRESHOLD
  );

# for Windows and Linux
#
my $dirSeparator = ( $OSNAME =~ /^MSWin/x ) ? '\\' : '/';

#  get input args
#   read the script's config file
#     assign threshold values and other initialization variables
#
getInputArguments();
setConfiguration( getConfig( $configFilePath ) );

my $debugLevel0 = $FALSE; # some debug is needed before $loggerMain is ready

my $logFilePath = createDir( $g_logDir );
Log::Log4perl::init( loggerInit( $logFilePath, $debug ) );
my $loggerMain  = get_logger( $script );
   $loggerMain->level( getLoggerLevel( $logLevel ) );

my $project  = 'Project:';
my $hardware = 'Ganymede';

my @columns   = qw(DATE CRITICAL_GPP_CPP CRITICAL_MODEM_CPP CRITICAL_GPP_JAVA
                         MAJOR_GPP_CPP    MAJOR_MODEM_CPP    MAJOR_GPP_JAVA
                         MINOR_GPP_CPP    MINOR_MODEM_CPP    MINOR_GPP_JAVA);
my @dates;

getData( $dataFilePath );

# 1. create a easily sorted temporary date (yyyymmdd) associated with each array hash element
# 2. sort the result
# 3. copy the sorted date & data hashes back into the array
#
@dates =  map  { $_->[0] }
          sort { $a->[1] cmp $b->[1] }
          map  { [ $_, ( sprintf( '%4u%02u%02u', ( split '/', $_->{ DATE } )[2,0,1] ) ) ] } @dates;


$loggerMain->debug( Dumper(@dates) );


# re-format data for display; keep no-color copy for metrics
#
my @colorDates = @{ dclone( \@dates ) };
$loggerMain->debug( Dumper(@colorDates) );

createColorMarkup( \@colorDates );
$loggerMain->debug( Dumper( @colorDates ) );

# Template::Toolkit
# template file, $script.tt, will map data to html
#
my $tt = Template->new;

my %linePointColors = (
                        critical => {
                                      GPP =>   {
                                                 line => '"rgba(255,0,0,1)"',
                                                 point=> '"rgba(255,0,0,1)"',
                                               },
                                      MODEM => {
                                                 line => '"rgba(0,0,0,1)"',
                                                 point=> '"rgba(0,0,0,1)"',
                                               },
                                      JAVA=>   {
                                                 line => '"rgba(0,0,255,1)"',
                                                 point=> '"rgba(0,0,255,1)"',
                                               },
                                    },
                        major    => {
                                      GPP =>   {
                                                 line => '"rgba(0,255,0,1)"',
                                                 point=> '"rgba(0,255,0,1)"',
                                               },
                                      MODEM => {
                                                 line => '"rgba(100,100,0,1)"',
                                                 point=> '"rgba(100,100,0,1)"',
                                               },
                                      JAVA=>   {
                                                 line => '"rgba(225,100,25,1)"',
                                                 point=> '"rgba(225,100,25,1)"',
                                               },
                                    },
                      );

$loggerMain->debug( Dumper( %linePointColors ) );

$tt->process( $script . '_html.tt',
             { project    => $project,
               hardware   => $hardware,
               colordates => \@colorDates,
               dates      => \@dates,
               colors     => \%linePointColors,
               copyright  => '2013 swdeveloperatcoxdotnet',
             },
             $script . '.html' )
  or croak '__CROAK__ $tt->error = ', $tt->error;

exit;

################################################################################

sub createColorMarkup
{
  my $aRef    = shift;
  my $aLength = @$aRef;
  for( my $i=0; $i<$aLength; $i++ )
  {
    if( $aRef->[$i]{CRITICAL_GPP_CPP} <  $CRITICAL_CPP_THRESHOLD )
    {
      $aRef->[$i]{CRITICAL_GPP_CPP} = '<font color="green">' . $aRef->[$i]{CRITICAL_GPP_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{CRITICAL_GPP_CPP} == $CRITICAL_CPP_THRESHOLD )
    {
      $aRef->[$i]{CRITICAL_GPP_CPP} = '<font color="black">' . $aRef->[$i]{CRITICAL_GPP_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{CRITICAL_GPP_CPP} >  $CRITICAL_CPP_THRESHOLD )
    {
      $aRef->[$i]{CRITICAL_GPP_CPP} = '<font color="red">'   . $aRef->[$i]{CRITICAL_GPP_CPP} . '</font>&nbsp;';
    }
    else
    {
      carp 'No match for $CRITICAL_CPP_THRESHOLD = ', $CRITICAL_CPP_THRESHOLD, qw(\n);
    }


    if( $aRef->[$i]{MAJOR_GPP_CPP} <  $MAJOR_CPP_THRESHOLD )
    {
      $aRef->[$i]{MAJOR_GPP_CPP} = '<font color="green">' . $aRef->[$i]{MAJOR_GPP_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MAJOR_GPP_CPP} == $MAJOR_CPP_THRESHOLD )
    {
      $aRef->[$i]{MAJOR_GPP_CPP} = '<font color="black">' . $aRef->[$i]{MAJOR_GPP_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MAJOR_GPP_CPP} >  $MAJOR_CPP_THRESHOLD )
    {
      $aRef->[$i]{MAJOR_GPP_CPP} = '<font color="red">'   . $aRef->[$i]{MAJOR_GPP_CPP} . '</font>&nbsp;';
    }
    else
    {
      carp 'No match for $MAJOR_CPP_THRESHOLD = ', $MAJOR_CPP_THRESHOLD, qw(\n);
    }


    if( $aRef->[$i]{MINOR_GPP_CPP} <  $MINOR_CPP_THRESHOLD )
    {
      $aRef->[$i]{MINOR_GPP_CPP} = '<font color="green">' . $aRef->[$i]{MINOR_GPP_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MINOR_GPP_CPP} == $MINOR_CPP_THRESHOLD )
    {
      $aRef->[$i]{MINOR_GPP_CPP} = '<font color="black">' . $aRef->[$i]{MINOR_GPP_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MINOR_GPP_CPP} >  $MINOR_CPP_THRESHOLD )
    {
      $aRef->[$i]{MINOR_GPP_CPP} = '<font color="red">'   . $aRef->[$i]{MINOR_GPP_CPP} . '</font>&nbsp;';
    }
    else
    {
      carp 'No match for $MINOR_CPP_THRESHOLD = ', $MINOR_CPP_THRESHOLD, qw(\n);
    }


    if( $aRef->[$i]{CRITICAL_GPP_JAVA} <  $CRITICAL_JAVA_THRESHOLD )
    {
      $aRef->[$i]{CRITICAL_GPP_JAVA} = '<font color="green">' . $aRef->[$i]{CRITICAL_GPP_JAVA} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{CRITICAL_GPP_JAVA} == $CRITICAL_JAVA_THRESHOLD )
    {
      $aRef->[$i]{CRITICAL_GPP_JAVA} = '<font color="black">' . $aRef->[$i]{CRITICAL_GPP_JAVA} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{CRITICAL_GPP_JAVA} >  $CRITICAL_JAVA_THRESHOLD )
    {
      $aRef->[$i]{CRITICAL_GPP_JAVA} = '<font color="red">'   . $aRef->[$i]{CRITICAL_GPP_JAVA} . '</font>&nbsp;';
    }
    else
    {
      carp 'No match for $CRITICAL_JAVA_THRESHOLD = ', $CRITICAL_JAVA_THRESHOLD, qw(\n);
    }


    if( $aRef->[$i]{MAJOR_GPP_JAVA} <  $MAJOR_JAVA_THRESHOLD )
    {
      $aRef->[$i]{MAJOR_GPP_JAVA} = '<font color="green">' . $aRef->[$i]{MAJOR_GPP_JAVA} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MAJOR_GPP_JAVA} ==  $MAJOR_JAVA_THRESHOLD )
    {
      $aRef->[$i]{MAJOR_GPP_JAVA} = '<font color="black">' . $aRef->[$i]{MAJOR_GPP_JAVA} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MAJOR_GPP_JAVA} >  $MAJOR_JAVA_THRESHOLD )
    {
      $aRef->[$i]{MAJOR_GPP_JAVA} = '<font color="red">'   . $aRef->[$i]{MAJOR_GPP_JAVA} . '</font>&nbsp;';
    }
    else
    {
      carp 'No match for $MAJOR_JAVA_THRESHOLD = ', $MAJOR_JAVA_THRESHOLD, qw(\n);
    }


    if( $aRef->[$i]{MINOR_GPP_JAVA} <  $MINOR_JAVA_THRESHOLD )
    {
      $aRef->[$i]{MINOR_GPP_JAVA} = '<font color="green">' . $aRef->[$i]{MINOR_GPP_JAVA} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MINOR_GPP_JAVA} ==  $MINOR_JAVA_THRESHOLD )
    {
      $aRef->[$i]{MINOR_GPP_JAVA} = '<font color="black">' . $aRef->[$i]{MINOR_GPP_JAVA} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MINOR_GPP_JAVA} >  $MINOR_JAVA_THRESHOLD )
    {
      $aRef->[$i]{MINOR_GPP_JAVA} = '<font color="red">'   . $aRef->[$i]{MINOR_GPP_JAVA} . '</font>&nbsp;';
    }
    else
    {
      carp 'No match for $MINOR_JAVA_THRESHOLD = ', $MINOR_JAVA_THRESHOLD, qw(\n);
    }


    if( $aRef->[$i]{CRITICAL_MODEM_CPP} <  $CRITICAL_MODEM_THRESHOLD )
    {
      $aRef->[$i]{CRITICAL_MODEM_CPP} = '<font color="green">' . $aRef->[$i]{CRITICAL_MODEM_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{CRITICAL_MODEM_CPP} ==  $CRITICAL_MODEM_THRESHOLD )
    {
      $aRef->[$i]{CRITICAL_MODEM_CPP} = '<font color="black">' . $aRef->[$i]{CRITICAL_MODEM_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{CRITICAL_MODEM_CPP} >  $CRITICAL_MODEM_THRESHOLD )
    {
      $aRef->[$i]{CRITICAL_MODEM_CPP} = '<font color="red">'   . $aRef->[$i]{CRITICAL_MODEM_CPP} . '</font>&nbsp;';
    }
    else
    {
      carp 'No match for $CRITICAL_MODEM_THRESHOLD = ', $CRITICAL_MODEM_THRESHOLD, qw(\n);
    }


    if( $aRef->[$i]{MAJOR_MODEM_CPP} <  $MAJOR_MODEM_THRESHOLD )
    {
      $aRef->[$i]{MAJOR_MODEM_CPP} = '<font color="green">' . $aRef->[$i]{MAJOR_MODEM_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MAJOR_MODEM_CPP} ==  $MAJOR_MODEM_THRESHOLD )
    {
      $aRef->[$i]{MAJOR_MODEM_CPP} = '<font color="black">' . $aRef->[$i]{MAJOR_MODEM_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MAJOR_MODEM_CPP} >  $MAJOR_MODEM_THRESHOLD )
    {
      $aRef->[$i]{MAJOR_MODEM_CPP} = '<font color="red">'   . $aRef->[$i]{MAJOR_MODEM_CPP} . '</font>&nbsp;';
    }
    else
    {
      carp 'No match for $MAJOR_MODEM_THRESHOLD = ', $MAJOR_MODEM_THRESHOLD, qw(\n);
    }


    if( $aRef->[$i]{MINOR_MODEM_CPP} <  $MINOR_MODEM_THRESHOLD )
    {
      $aRef->[$i]{MINOR_MODEM_CPP} = '<font color="green">' . $aRef->[$i]{MINOR_MODEM_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MINOR_MODEM_CPP} ==  $MINOR_MODEM_THRESHOLD )
    {
      $aRef->[$i]{MINOR_MODEM_CPP} = '<font color="black">' . $aRef->[$i]{MINOR_MODEM_CPP} . '</font>&nbsp;';
    }
    elsif( $aRef->[$i]{MINOR_MODEM_CPP} >  $MINOR_MODEM_THRESHOLD )
    {
      $aRef->[$i]{MINOR_MODEM_CPP} = '<font color="red">'   . $aRef->[$i]{MINOR_MODEM_CPP} . '</font>&nbsp;';
    }
    else
    {
      carp 'No match for $MINOR_MODEM_THRESHOLD = ', $MINOR_MODEM_THRESHOLD, qw(\n);
    }

  }
  return;
}

sub getData
{
  my $file = shift;

  # read/process input file (.csv assumed) identified on the command line
  # EXAMPLE: 1/1/2013,16,92,11,68,79,71,335,264,212
  #
  open my $fh, '<', $file;
  while( <$fh> )
  {
    chomp;
    next if /^\s*$/x;
    my %date;
    @date{@columns} = split /,/x;
    push @dates, \%date;
  }
  close $fh;
  return;
}

sub setConfiguration
{
  my $hRef = shift;

  Readonly::Scalar $TRUE  => 1;
  Readonly::Scalar $FALSE => 0;

  Readonly::Scalar $g_currentDir             => $Bin;

  Readonly::Scalar $g_logDir                 => $g_currentDir . $dirSeparator . $hRef->{ logdir };

  Readonly::Scalar $CRITICAL_CPP_THRESHOLD   => $hRef->{ CRITICAL_CPP_THRESHOLD   };
  Readonly::Scalar $MAJOR_CPP_THRESHOLD      => $hRef->{ MAJOR_CPP_THRESHOLD      };
  Readonly::Scalar $MINOR_CPP_THRESHOLD      => $hRef->{ MINOR_CPP_THRESHOLD      };

  Readonly::Scalar $CRITICAL_JAVA_THRESHOLD  => $hRef->{ CRITICAL_JAVA_THRESHOLD  };
  Readonly::Scalar $MAJOR_JAVA_THRESHOLD     => $hRef->{ MAJOR_JAVA_THRESHOLD     };
  Readonly::Scalar $MINOR_JAVA_THRESHOLD     => $hRef->{ MINOR_JAVA_THRESHOLD     };

  Readonly::Scalar $CRITICAL_MODEM_THRESHOLD => $hRef->{ CRITICAL_MODEM_THRESHOLD };
  Readonly::Scalar $MAJOR_MODEM_THRESHOLD    => $hRef->{ MAJOR_MODEM_THRESHOLD    };
  Readonly::Scalar $MINOR_MODEM_THRESHOLD    => $hRef->{ MINOR_MODEM_THRESHOLD    };

  return;
}


sub createDir
{
  my $dir = shift;

  return $dir if -e $dir;

  my( $subroutine )   = (caller(0))[3];
  local $| = 1;

  print "$subroutine ", __LINE__, ": directory is $dir\n" if $debugLevel0;

  my $makePathResponse = make_path( $dir,
                                    {
                                      verbose => $FALSE,
                                      error   => \my $err,
                                    }
                                   );

  print "$subroutine ", __LINE__, ": attempted to create directory $dir \$makePathResponse = $makePathResponse\n" if $debugLevel0;

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
    print "$subroutine ", __LINE__, ": No make_path errors encountered \$dir = $dir\n" if $debugLevel0;
  }
  return $dir;
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
  my $dir      = shift;
  my $test     = shift;

  my $logFileName = $dir . '/' . formattedDateTime()->{ yyyymmddhhmmss } . '_' . $script . '.log';

  # $test mode writes to the screen and a file
  #
  my $log_conf;
  if( $test )
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

sub getConfig
{
  my $xmlFilePath = shift;

  print $script, ' ', __LINE__, ' $xmlFilePath = ', $xmlFilePath, "\n" if $debugLevel0;

  local $| = 1;

  my $doc;
  my $parser = XML::LibXML->new();

  # eval logic courtesy of:
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

  print $script, ' ', __LINE__, " No XML or system errors...\n" if $debugLevel0;

  my %config;

  for my $covIgnoredDirectoriesNode( $doc->findnodes( '/configuration/*' ) )
  {
    my $name  = $covIgnoredDirectoriesNode->getAttribute( 'name' );
    my $value = $covIgnoredDirectoriesNode->getAttribute( 'value' );
    print $script, ' ', __LINE__, ' name = ', $name, ' $value = ', $value, "\n" if $debugLevel0;

    $config{ $name } = $value;
  }
  print $script, ' ', __LINE__, Dumper( %config ) if $debugLevel0;
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

sub getInputArguments
{
  my $USAGE = << "_EOT_";
"Usage: $script
-datafile 'data file path'
-configfile 'confoguration file path'
[-debug]
[-loglevel [DEBUG|INFO|WARN|ERROR|FATAL]]
[-h|?|help]"
_EOT_

  $USAGE  = join ' ', split m{\n}x, $USAGE;
  $USAGE .= "\n";

  croak $USAGE unless GetOptions(
                                  "datafile=s"   => \$dataFilePath,
                                  "configfile=s" => \$configFilePath,
                                  "loglevel=s"   => \$logLevel,
                                  "debug"        => \$debug,
                                  "h|?|help"     => \$help,
                                );

  croak '__CROAK__ -datafile <path to data file> is required!'            unless $dataFilePath;
  croak '__CROAK__ -configfile <path to configuration file> is required!' unless $configFilePath;

  print $USAGE and exit if $help;

  $logLevel = $WARN unless $logLevel;

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

__END__

=pod

=encoding utf8

=head1 NAME

metrics.pl

=head1 SYNOPSIS

Perl script to read software defect measures and create an HTML file to display
the data in table and graph form.

=head1 DESCRIPTION

metrics.pl was created to demonstrate use of Perl CPAN modules, Perl coding style,
and integration with HTML and JavaScript.

CPAN modules demonstrated include:

=over 2

=item * Log::Log4Perl

=item * Readonly

=item * Template::Toolkit

=item * XML::LibXML

=back

=head1 USAGE

Usage: perl metrics.pl -datafile 'file path' -configfile 'configuration file path'
                      [-loglevel [DEBUG|INFO|WARN|ERROR|FATAL]] [-debug] [-h|?|help]"

Example: perl metrics.pl -datafile measures.csv -configfile metrics.xml

=head1 REQUIRED ARGUMENTS

A comma-separated variable (.csv) data file and a configuration file (.xml) are required.
See measures.csv for data file format.
See metrics.xml for configuration format.

=head1 OPTIONS

Optional command line arguments are shown in USAGE surrounded by brackets ( [] ).
If the optional argument is not present the script will use a default value.

=over 2

=item * -debug : (boolean) prints trace statements to show script progress and data details

=back

=head1 DIAGNOSTICS

log4perl trace statements

=head1 EXIT STATUS

Exits with 0 for non-error execution.
Error conditions within the script will cause it to croak at the point of failure.

=head1 CONFIGURATION

metrics.xml contains log file path and threshold measurement values.

=head1 DEPENDENCIES

See the 'use <module>' list at the top of the script.
Developed and tested using ActiveState Perl v5.16.3 on Windows and Perl v5.10.1 on Linux.
See 'INCOMPATIBILITIES.'

=head1 INCOMPATIBILITIES

Using Amazon (AWS) RHEL instance and Perl v5.10.1 required changing switch statements
in createColorMarkup() to a set of if statements due to backward incompatibility. This
results in a Perl::Critic high complexity complaint for createColorMarkup().

=head1 BUGS AND LIMITATIONS

none observed

=head1 AUTHOR

Dennis Sass, E<lt>swdeveloperatcoxdotnetE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright 2013 Dennis Sass, All rights reserved.
This program is free software; you can redistribute it and/or modify it under the
same terms as Perl.

=cut
