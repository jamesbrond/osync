#######################################################################
#
# RisWeb PL/SQL patch
# Checks for modification in PLSQLScripts and creates a patch ready
# to be uploaded to the Oracle DB
#
#######################################################################
use feature ":5.12";
use strict;
use warnings;
use Config::Simple;
use File::Basename;
use experimental 'smartmatch';
use Getopt::Long;
use Log::Log4perl;

sub show_help {
  print
"\nRisWeb PL/SQL patch\nChecks for modification in PLSQLScripts and creates a patch ready\nto be uploaded to the Oracle DBUsage:\n\n plsq_patch2 <options>\n\nOptions:\n"
    . "\t-h --help\t\tshow help\n"
    . "\t-host --oracle-host\tset database orcale host\n"
    . "\t-sid --oracle-sid\tset database orcale SID\n"
    . "\t-u --oracle-user\tset database orcale username\n"
    . "\t-p --oracle-pwd\t\tset database orcale password\n"
    . "\t-q --quiet\t\tsuppress debug messages\n"
    . "\t-s --source\t\tset database PL/SQL source path\n"
    . "\t-e --exclude\t\tcomma separated list of files to escape\n"
    . "\t--sqlplus \t\tset path to sqlplus\n"
    . "\t--svn \t\t\tset path to svn\n"
    . "\t-v --verbose\t\tincrease verbosity level\n"
    . "\t-vv --very-verbose\tincrease verbosity to higher level\n";
  exit 0;
}
my ( $debug, $lrepo, $sqlplus, $svn );
my @excludes = ();
my %oracle   = (
  host => '',
  sid  => '',
  user => '',
  pwd  => '',
);
GetOptions(
  "h|help"             => \&show_help,
  "q|quiet"            => sub { $debug = "FATAL" },
  "host|oracle-host=s" => \$oracle{'host'},
  "sid|oracle-sid=s"   => \$oracle{'sid'},
  "u|oracle-user=s"    => \$oracle{'user'},
  "p|oracle-pwd=s"     => \$oracle{'pwd'},
  "s|source=s"         => \$lrepo,
  "e|exclude=s"        => sub { @excludes = split /\s*,\s*/, $_[1] }
  ,    # split( ',', $_[1] ) },
  "sqlplus=s"       => \$sqlplus,
  "svn=s"           => \$svn,
  "v|verbose"       => sub { $debug = "DEBUG" },
  "vv|very-verbose" => sub { $debug = "TRACE" }
) or die("Error in command line arguments\n");
$debug = 'ERROR' unless $debug;
my $log4perl_conf = qq(
	log4perl.rootLogger = $debug, Screen
    log4perl.appender.Screen = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr = 0
    log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Screen.layout.ConversionPattern = [%p]\t%d{HH:mm}.%r (%L) %m %n
);
Log::Log4perl::init( \$log4perl_conf );
my $L = Log::Log4perl->get_logger('plsql_patch');

sub raise_error {
  $L->error("$_[1]");
  exit $_[0];
}
raise_error( 1, "No source path defined" )     unless $lrepo;
raise_error( 2, "No svn defined" )             unless $svn;
raise_error( 3, "No sqlplus defined" )         unless $sqlplus;
raise_error( 4, "No Oracle host defined" )     unless $oracle{'host'};
raise_error( 5, "No Oracle sid defined" )      unless $oracle{'sid'};
raise_error( 6, "No Oracle user defined" )     unless $oracle{'user'};
raise_error( 7, "No Oracle password defined" ) unless $oracle{'pwd'};
my $script_path = dirname(__FILE__);

chdir($lrepo);
my $cfg = new Config::Simple( $script_path . '/.rev' );
$L->trace("config file: $script_path/.rev");
my $rev = $cfg->param('oracle.rev');
$L->trace("SVN command: $svn");
$L->trace("SQLPlus command: $sqlplus");
$L->debug("query locale SVN $lrepo");
$L->trace("$svn info $lrepo 2>&1");
my $output = qx|"$svn" info $lrepo 2>&1|;
my ($head) = $output =~ /Revision: (\w*)/s;
$L->info("last revision checked: $rev - HEAD revision: $head ");

if ( $rev == $head ) {
  $L->info("nothing to do");
  exit 0;
}
$L->debug("check for changes in PLSQL scripts");
$L->trace("$svn log $lrepo -r $rev:HEAD -v 2>&1");
$output = qx|"$svn" log $lrepo -r $rev:HEAD -v 2>&1|;
my @changelog = ();
for ( split /^/, $output ) {
  if ( $_ =~ /PLSQLScripts\// ) {
    my ($f) = $_ =~ /PLSQLScripts\/(.*)$/;
    if ( !( $f ~~ @changelog ) ) {
      if ( !( $f ~~ @excludes ) ) {
        $L->trace("found $f");
        push( @changelog, $f );
      } else {
        $L->trace("skip $f");
      }
    }
  }
}
my $arrSize = @changelog;
$L->info("found $arrSize PL/SQL files to update");
my $f;
my $patch = $script_path . "/.tmp";
$L->trace("temporaty patch: $patch");

my $spoolfile = $script_path . "/patch\_$rev\_$head.log";
$L->debug("spool to $spoolfile");

for (@changelog) {
  $L->debug("execute \"$_\" PL/SQL script");

  $f = $lrepo . '/' . $_;
  if ( -f $f ) {
    open( PATCH, ">:encoding(UTF-8)", $patch )
      or $L->fatal( "Could not open file '" . $patch . "': $!" )
      && die "Could not open file '" . $patch . "': $!";
    print PATCH "SET DEFINE OFF\n";
    print PATCH "SET TERMOUT OFF\n";
    print PATCH "SET PAGESIZE 0\n";
    print PATCH "SET TRIMSPOOL ON\n";
    print PATCH "SET LINESIZE 120\n\n";
    print PATCH "SPOOL $spoolfile APPEND\n\n";
    print PATCH "PROMPT " . "*" x 120 . "\n";
    printf PATCH "PROMPT ** %-115s**\n", "FILE: $f";
    print PATCH "PROMPT " . "*" x 120 . "\n\n";
    open( X, "<:encoding(UTF-8)", "$f" ) or $L->fatal($!) && die $!;
    print PATCH <X>;
    print PATCH "\n\n";
    close(X);
    print PATCH "PROMPT " . "*" x 120 . "\n\n";
    print PATCH "SPOOL OFF\n";
    print PATCH "QUIT\n";
    close(PATCH);
    $output =
qx|"$sqlplus" -s $oracle{'user'}/$oracle{'pwd'}\@$oracle{'host'}/$oracle{'sid'} \@"$patch" 2>&1|;
    unlink $patch;
  }
}

$rev = $head;
$L->debug("Save configuration");
$cfg->param( 'oracle.rev', $rev );
$cfg->save();

exit 0;

# ~@:-]
