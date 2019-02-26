#######################################################################
#
# RisWeb Babelin patch
# Checks for modification of lang-* and update Babelin database
#
# Usage:
# perl babelin.pl -vv -s C:\Users\19012248\src\ris2010\kiosk\install\kiosk\data\lang --svn C:\Users\19012248\bin\svn\bin\svn.exe --user jbrond --project 2
#
#######################################################################
use strict;
use feature ":5.12";
use warnings;
use Config::Simple;
use File::Basename;
use experimental 'smartmatch';
use DBI;
use Getopt::Long;
use Log::Log4perl;

sub show_help {
  print
"\nRisWeb Babelin patch\nChecks for modification in languages scripts and update Babelin server DBUsage:\n\n babelin <options>\n\nOptions:\n"
    . "\t-h --help\t\tshow help\n"
    . "\t-q --quiet\t\tsuppress debug messages"
    . "\t-p --project\tproject identifier"
    . "\t-s --source\t\tset local source repository\n"
    . "\t-v --verbose\t\tincrease verbosity level\n"
    . "\t-vv --very-verbose\tincrease verbosity to higher level\n";
  exit 0;
}

sub filelines {
  for ( $_[0] ) { }
  return $.;
}

sub back_and_print {
  my $text = shift @_;    # no tabs, no newlines!
  print "\b" x 80;
  print " " x 80;
  print "\b" x 80;
  print $text;
}

sub progress {
  my ( $curr, $tot ) = @_;
  return sprintf( "%.2f", $curr * 100 / $tot );
}
my $script_path = dirname(__FILE__);
my ( $debug, $lrepo, $user, $svn, $pid, $prefix );
GetOptions(
  "h|help"          => \&show_help,
  "q|quiet"         => sub { $debug = "FATAL" },
  "s|source=s"      => \$lrepo,
  "p|project=i"     => \$pid,
  "f|prefix:s"      => \$prefix,
  "svn=s"           => \$svn,
  "u|user:s"        => \$user,
  "v|verbose"       => sub { $debug = "DEBUG" },
  "vv|very-verbose" => sub { $debug = "TRACE" }
) or die("Error in command line arguments\n");
$prefix = ''        unless $prefix;
$user   = 'unknown' unless $user;
$debug  = 'ERROR'   unless $debug;
my $log4perl_conf = qq(
	log4perl.rootLogger = $debug, Screen
    log4perl.appender.Screen = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr = 0
    log4perl.appender.Screen.layout = Log::Log4perl::Layout::SimpleLayout
);
Log::Log4perl::init( \$log4perl_conf );
my $L = Log::Log4perl->get_logger('babelin');

sub raise_error {
  $L->error("$_[1]");
  exit $_[0];
}
raise_error( 1, "No source path defined" ) unless $lrepo;
raise_error( 2, "No svn defined" )         unless $svn;

$L->trace("Config file: $script_path/.rev");
my $cfg          = new Config::Simple( $script_path . '/.rev' );
my $babelin_host = $cfg->param('babelin.host');
my $babelin_port = $cfg->param('babelin.port');
my $babelin_db   = $cfg->param('babelin.db');
my $babelin_user = $cfg->param('babelin.user');
my $babelin_pass = $cfg->param('babelin.pass');
$L->debug("Connect to Babelin DB");
$L->trace(
  "DBI:mysql:database=$babelin_db;host=$babelin_host;port=$babelin_port");
my $dbh = DBI->connect(
  "DBI:mysql:database=$babelin_db;host=$babelin_host;port=$babelin_port",
  $babelin_user, $babelin_pass, { 'RaiseError' => 1, 'mysql_enable_utf8' => 1 } );

$L->debug("Query remote database to get last revision checked");
my $query = "SELECT rev FROM babel_info WHERE pid = $pid LIMIT 1";
$L->trace(qq{[SQL] $query});
my $sth = $dbh->prepare(qq{$query});
$sth->execute() or die $dbh->errstr;
$sth->bind_columns( \my $rev );

if ( !$sth->fetch ) {
  $rev = 0;
}
$sth->finish();

$L->debug("Query locale SVN $lrepo");
$L->trace("SVN command: $svn");
$L->trace("$svn info $lrepo 2>&1");
my $output         = qx|"$svn" info $lrepo 2>&1|;
my ($head)         = $output =~ /Last Changed Rev: (\w*)/s;
my ($relative_url) = $output =~ /Relative URL: \^([\w\\\/]*)/s;
$L->info("Last revision checked: $rev - HEAD revision: $head ");
$L->debug("Relative URL: $relative_url");

if ( $rev == $head ) {
  $L->info("Nothing to do");
  exit 0;
}
$L->debug("Check for changes in languages scripts");
$L->trace("$svn log $lrepo -r $rev:HEAD -v 2>&1");
$output = qx|"$svn" log $lrepo -r $rev:HEAD -v 2>&1|;

my @changelog       = ();
my $dev_has_changed = 0;
for ( split /^/, $output ) {
  if ( $_ =~ /$relative_url/ ) {
    my ($f) = $_ =~ /$relative_url\/(.*)$/;
    if ($f) {
      if ( $f =~ qr/${prefix}dev.sql$/i ) {
        $dev_has_changed = 1;
      } else {
        if ( !( $f ~~ @changelog ) ) {
          push( @changelog, $f );
        }
      }
    }
  }
}
my $arrSize = @changelog;
if ($dev_has_changed) {
  $arrSize++;
}
$L->info("Found $arrSize language files to update");

# create temporary table "lang_tmp"
$query =
'CREATE TEMPORARY TABLE lang_tmp (ns VARCHAR(42), mkey VARCHAR(64), mval VARCHAR(1024), locale VARCHAR(6))';
$L->trace("[SQL] $query");
$dbh->do(qq{$query}) or die $!;

if ($dev_has_changed) {
  my $f = $lrepo . '\\' . $prefix . 'dev.sql';
  $L->debug("update dev language from file $f");

  open( X, "<:encoding(UTF-8)", $f ) or $L->fatal( "Could not open file '" . $f . "': $!" )
    && die "Could not open file '" . $f . "': $!";
  my $lines = filelines(<X>);
  seek( X, 0, 0 );
  my $count = 0;

  while ( my $line = <X> ) {
    if ( $line =~ /insert into lang_tmp/i ) {
      $dbh->do($line);
      ++$count;
      back_and_print( "Update dev language ["
          . progress( $count, $lines )
          . "%] $count lines inserted" );
    }
  }
  $L->debug("Update dev language [100%] $count lines inserted");
  back_and_print("Update dev language [100%] $count lines inserted");
  print "\n";
  close X;

  # update babelin
  $query =
"INSERT INTO babel_dev (ns, mkey, dev, pid) SELECT ns, mkey, mval, $pid FROM lang_tmp ON DUPLICATE KEY UPDATE dev=VALUES(dev)";
  $L->trace("[SQL] $query");
  $dbh->do(qq{$query}) or die $!;
}

for (@changelog) {
  my ($filename) = $_;
  my $f = "$lrepo\\$filename";
  if ( -e $f ) {
    my ($iso) = $_ =~ /$prefix(.*)\.sql$/;
    $L->debug("update $iso language from file $f");

    # truncate lang_tmp table
    $query = 'TRUNCATE TABLE lang_tmp';
    $L->trace("[SQL] $query");
    $dbh->do(qq{$query}) or die $!;

	open( X, "<:encoding(UTF-8)", $f ) or $L->fatal( "Could not open file '" . $f . "': $!" )
    && die "Could not open file '" . $f . "': $!";
    my $lines = filelines(<X>);
    seek( X, 0, 0 );
    my $count = 0;
    while ( my $line = <X> ) {
      if ( $line =~ /insert into lang_tmp/i ) {
	    $line = $line =~ s/\\\'/\\\\\'/rg;
		my $sth = $dbh->prepare($line);
        $sth->execute() or die $dbh->errstr;
        ++$count;
        back_and_print( "Update $iso language ["
            . progress( $count, $lines )
            . "%] $count lines inserted" );
      }
    }
    close X;
    back_and_print("Update $iso language [100%] $count lines inserted");
    print "\n";

    # get Language ID
    $query = "SELECT lid FROM languages WHERE iso = '$iso' LIMIT 1";
    $L->trace(qq{[SQL] $query});
    $sth = $dbh->prepare(qq{$query});
    $sth->execute() or die $dbh->errstr;
    $sth->bind_columns( \my $lid );
    if ( !$sth->fetch ) {
      die('language $iso doesn\'t exist in babelin');
    }
    $sth->finish();

    # update babel_locales
    $query =
"INSERT IGNORE INTO babel_locales (bid, lid, val) SELECT b.bid, $lid, t.mval FROM lang_tmp t LEFT JOIN babel_dev b ON t.ns = b.ns AND t.mkey=b.mkey WHERE b.pid = $pid";
    $L->trace("[SQL] $query");
    $dbh->do(qq{$query}) or die $!;
  }
}
$query = 'DROP TABLE lang_tmp';
$L->trace(" [SQL] $query ");
$dbh->do(qq{$query}) or die $!;

$L->debug(" Save configuration ");
$sth = $dbh->prepare(
  $rev == 0
  ? qq{INSERT INTO babel_info (rev, user, pid) VALUES (?, ?, ?)}
  : qq{UPDATE babel_info SET rev=?, user=? WHERE pid=?}
);
$sth->execute( $head, $user, $pid ) or die $dbh->errstr;
$sth->finish();
$dbh->disconnect();
exit 0;

# ~@:-]
