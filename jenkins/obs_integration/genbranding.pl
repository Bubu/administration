#!/usr/bin/perl
#
# This script automates package build for jenkins based on OBS
# Copyright Klaas Freitag <freitag@owncloud.com>
#
# Released under GPL V.2.
#
#
use Getopt::Std;
use Config::IniFiles;
use File::Copy;
use File::Basename;
use File::Path;
use File::Find;
use ownCloud::BuildHelper;
use Cwd;
use Template;

use strict;
use vars qw($miralltar $themetar $templatedir $dir $opt_h $opt_o $opt_b $opt_c $opt_n $opt_f);

sub help() {
  print<<ENDHELP

  genbranding - Generates a branding from mirall sources and a branding

  Both the mirall and the branding tarball have to be passed ot this
  script. It combines both and creates a new branded source pack. It also
  creates packaging input files (spec-file and debian packaging files).

  This script reads the following input files
  - OEM.cmake from the branding tarball
  - a file mirall/package.cfg from the branding dir.
  - templates for the packaging files from the local templates directory

  Options:
  -h:           help, displays help text
  -b:           build the package locally before uploading
  -o:           osc mode, build against ownCloud obs
  -c "params":  additional osc paramters
  -n:           don't recreate the tarball, use an existing one.
  -f:           force upload, upload even if nothing changed.

  Call example:
  ./genbranding.pl mirall-1.5.3.tar.bz2 cern.tar.bz2

  Output will be in directory cern-client

  Options:
  -h      this help text.

ENDHELP
;
  exit 1;
}


# ======================================================================================
sub getFileName( $ ) {
  my ($tarname) = @_;
  $tarname = basename($tarname);
  $tarname =~ s/\.tar.*//;
  return $tarname;
}

# Extracts the mirall tarball and puts the theme tarball the new dir
sub prepareTarBall( ) {
    print "Preparing tarball...";

    system("/bin/tar", "xif", $miralltar);
    print "Extract mirall...\n";
    my $mirall = getFileName( $ARGV[0] );
    my $theme = getFileName( $ARGV[1] );
    my $newname = $mirall;
    $newname =~ s/-/-$theme-/;
    move($mirall, $newname);
    chdir($newname);
    print "Extracting theme...\n";
    system("/bin/tar", "--wildcards", "-xif", "$themetar", "*/mirall/*");
    chdir("..");

    print " success: $newname\n";
    return $newname;
}

# read all files from the template directory and replace the contents
# of the .in files with values from the substition hash ref.
sub createClientFromTemplate($) {
    my ($substs) = @_;

    print "Create client from template\n";
    foreach my $log( keys %$substs ) {
	print "  - $log => $substs->{$log}\n";
    }

    my $clienttemplatedir = "$templatedir/client";
    my $theme = getFileName( $ARGV[1] );
    my $targetDir = "$theme-client";

    if( $opt_o ) {
	$targetDir = "oem/$targetDir";
    } else {
	mkdir("$theme-client");
    }
    opendir(my $dh, $clienttemplatedir);
    my $source;
    # all files, excluding hidden ones, . and ..
    my $tt = Template->new(ABSOLUTE=>1);

    foreach my $source (grep ! /^\./,  readdir($dh)) {
        my $target = $source;
        $target =~ s/BRANDNAME/$theme/;

        if($source =~ /\.in$/) {
            $target =~ s/\.in$//;
            $tt->process("$clienttemplatedir/$source", $substs, "$targetDir/$target") or die $tt->error();
        } else {
            copy("$clienttemplatedir/$source", "$targetDir/$target");
        }
     }
     closedir($dh);

     return cwd();
}

# Create the final themed tarball 
sub createTar($$)
{
    my ($clientdir, $newname) = @_;
    my $tarName = "$clientdir/$newname.tar.bz2";
    if( $opt_n ) {
	die( "Option -n given, but no tarball $tarName exists\n") unless( -e $tarName );
	return;
    }

    system("/bin/tar", "cjfi", $tarName, $newname);
    rmtree("$newname");
    print " success: Created $tarName\n";
}

# open the OEM.cmake 
sub readOEMcmake( $ ) 
{
    my ($file) = @_;
    my %substs;

    print "Reading OEM cmake file: $file\n";
    
    die("Could not open <$file>\n") unless open( OEM, "$file" );
    my @lines = <OEM>;
    close OEM;
    
    foreach my $l (@lines) {
	if( $l =~ /^\s*set\(\s*(\S+)\s*"(\S+)"\s*\)/i ) {
	    my $key = $1;
	    my $val = $2;
	    print "  * found <$key> => $val\n";
	    $substs{$key} = $val;
	}
    }

    if( $substs{APPLICATION_SHORTNAME} ) {
	$substs{shortname} = $substs{APPLICATION_SHORTNAME};
	$substs{displayname} = $substs{APPLICATION_SHORTNAME};
    }
    if( $substs{APPLICATION_NAME} ) {
	$substs{displayname} = $substs{APPLICATION_NAME};
    }
    if( $substs{APPLICATION_DOMAIN} ) {
	$substs{projecturl} = $substs{APPLICATION_DOMAIN};
    }
    # more tags: APPLICATION_EXECUTABLE, APPLICATION_VENDOR, APPLICATION_REV_DOMAIN, THEME_CLASS, WIN_SETUP_BITMAP_PATH
    return %substs;
}

sub getSubsts( $ ) 
{
    my ($subsDir) = @_;
    my $cfgFile;

    find( { wanted => sub {
	if( $_ =~ /mirall\/package.cfg/ ) {
	    print "Substs from $File::Find::name\n";
	    $cfgFile = $File::Find::name;
          } 
        },
	no_chdir => 1 }, "$subsDir");

    print "Reading substs from $cfgFile\n";
    my %substs;

    my $oemFile = $cfgFile;
    $oemFile =~ s/package\.cfg/OEM.cmake/;
    %substs = readOEMcmake( $oemFile );

    # read the file package.cfg from the tarball and also remove it there evtl.
    my %s2;
    if( -r "$cfgFile" ) {
	%s2 = do $cfgFile;
    } else {
	die "ERROR: Could not read package config file $cfgFile!\n";
    }

    foreach my $k ( keys %s2 ) {
	$substs{$k} = $s2{$k};
    }

    # calculate some subst values, such as 
    $substs{tarball} = $subsDir unless( $substs{tarball} );
    $substs{pkgdescription_debian} = debianDesc( $substs{pkgdescription} );
    $substs{sysconfdir} = "/etc/". $substs{shortname} unless( $substs{sysconfdir} );
    $substs{maintainer} = "ownCloud Inc." unless( $substs{maintainer} );
    $substs{maintainer_person} = "ownCloud packages <packages\@owncloud.com>" unless( $substs{maintainer_person} );
    $substs{desktopdescription} = $substs{displayname} . " desktop sync client" unless( $substs{desktopdescription} );

    return \%substs;
}

# main here.
getopts('fnbohc:');

help() if( $opt_h );
help() unless( defined $ARGV[0] && defined $ARGV[1] );

# remember the base dir.
$dir = getcwd;

# Not used currently
# mkdir("packages") unless( -d "packages" );

$miralltar = $dir .'/'. $ARGV[0];
$themetar = $dir .'/'. $ARGV[1];
$templatedir = $dir .'/'. "templates";
print "Mirall Tarball: $miralltar\n";
print "Theme Tarball: $themetar\n";

# if -o (osc mode) check if an oem directory exists
my $theme = getFileName( $ARGV[1] );

if( $opt_o ) {
    unless( -d "./oem" && -d "./oem/.osc" ) {
	print "Checking out package oem/$theme-client\n";
	checkoutPackage( "oem", "$theme-client", $opt_c );
	chdir('../..'); # checkoutPackage chdirs into the package checkout
    } else {
	# Update the checkout
	my @osc = oscParams($opt_c);
	push @osc, 'up';
	chdir( 'oem');
	doOSC( @osc );
	chdir( '..' );
    }
}

my $dirName = prepareTarBall();

# returns hash reference
my $substs = getSubsts($dirName);

createClientFromTemplate( $substs );

my $clientdir = ".";


if( $opt_o ) {
    $clientdir = "oem/$theme-client";
}
createTar($clientdir, $dirName);

# Check if really files were added and if the tarball was already added
# to the osc repo
my $changeCnt = 0;

if( $opt_o ) {
    chdir( $clientdir );
    my %changes = oscChangedFiles($opt_c);

    foreach my $f (keys %changes) {
	if( $f eq $dirName . ".tar.bz2" && $changes{$f} eq '?' ) {
	    my @osc = oscParams($opt_c);
	    push @osc, ('add', $dirName . ".tar.bz2");
	    $changeCnt++;
	} else {
	    print "  Status of $f: $changes{$f}\n";
	    # count files with real changes
	    if( $changes{$f} eq '?' ) {
		print "Error: An unexpected file <$f> was found in the osc package.\n";
		die("Please remove or osc add and try again!\n");
	    }
	    $changeCnt++;
	}
    }
    chdir( "../.." );
}

# Finished if nothing changed.
if( $changeCnt == 0 && ! $opt_f ) {
    print "No changes to the package, exit!\n";
    exit(0);
}

# Add changelog entries
if( $opt_o ) {
    $clientdir = "oem/$theme-client";

    chdir( $clientdir );
    my $change = "  automatically generated branding added.";
    addDebChangelog( "$theme-client", $change, $substs->{version} );
    addSpecChangelog( "$theme-client", $change );
    chdir( "../.." );
}

# Build the package
my $buildOk = 0;
if( $opt_b ) {
    my @osc = oscParams($opt_c);
    push @osc, ('build', '--no-service', '--clean', 'openSUSE_13.1', 'x86_64', "$theme-client.spec");
    print "XXX osc " . join( " ", @osc ) . "\n";
    chdir( "oem/$theme-client" );
    $buildOk = doOSC( @osc );
    chdir( "../.." );
}

# push to obs.
if( $opt_o ) {
    if( $opt_b ) {
	die( "Local build failed, no uplaod!" ) unless ( $buildOk );
    }
    chdir( "oem/$theme-client" );

    my @osc = oscParams($opt_c);
    push @osc, ('diff');
    doOSC( @osc );

    @osc = oscParams($opt_c);
    push @osc, ('commit', '-m', 'Pushed by genbranding.pl');

    $buildOk = doOSC( @osc );
    chdir( "../.." );
}