#!/usr/bin/perl
use strict;
use warnings;
use File::Which; 
use Time::Out qw(timeout) ;
use Data::Dumper;
use Carp;
use WWW::Mechanize;
use HTML::TreeBuilder 5 -weak; # Ensure weak references in use
use Getopt::Long;

## catch help flag
{
	my $help;
	GetOptions ("help"  => \$help);
	if($help) {
		croak
			"Usage: ./historious-archiver.pl\n" . 
			"Environment variables: \n" . 
			"\t HISTORIOUS_DEBUG=0,1,2 controls debug level\n" . 
			"\t HISTORIOUS_USERNAME=.. login username\n" . 
			"\t HISTORIOUS_PASSWORD=.. login password\n" . 
			"\t HISTORIOUS_SAVEPATH=/save/path/ destination path";
	}
}

my $DEBUG = ($ENV{'HISTORIOUS_DEBUG'} || 0);
my $username = $ENV{'HISTORIOUS_USERNAME'};
my $password = $ENV{'HISTORIOUS_PASSWORD'};
my $wantPath = ($ENV{'HISTORIOUS_SAVEPATH'} || "$ENV{'HOME'}/historious/");
my $phantomJsBinary = "phantomjs";
my $phantomJsPng	= $wantPath . "save_png.js";
my $renderTimeout = 30_000; ## ms

unless( $username && $password) {
	croak "must set environment variables HISTORIOUS_USERNAME and HISTORIOUS_PASSWORD";
}

chdir($wantPath) || croak($@);
my $bp = which($phantomJsBinary);
unless($bp) {
	croak "can't find phantomjs binary `$phantomJsBinary` in \$PATH";
}

sub dwarn($) {
	warn @_ if $DEBUG;
}

dwarn "debug: $DEBUG, username: $username, savepath: $wantPath, binaryPath: $bp, scriptPath: $phantomJsPng, renderTimeout: $renderTimeout";

{
my $renderjs =  <<"SELEMANDER";
system = require('system');

var url = system.args[1];
var outfile = system.args[2];
//var width = system.args[3];
//var height = system.args[4];

var page = require('webpage').create();
//page.viewportSize = { width: width, height: height };

page.open(url, function (status) {
	if (status !== 'success') {
		console.log('Unable to load the address: ',status);
				page.render(outfile);
		phantom.exit();
	} else {
		window.setTimeout(function () {
				console.log('saving to ',outfile);
				page.render(outfile);
				phantom.exit();
		}, $renderTimeout);
	}
});
SELEMANDER
open(my $f, ">", $phantomJsPng);
print $f $renderjs."\n";
close($f);
}

## make sure to add some sort of sqlite database to track stuff here?
## or possibly use the on disk copy of the file as authorative? easier.
my $mech = WWW::Mechanize->new();
my $url = 'https://historio.us/login/';

dwarn "logging in";
login($mech,$url);
dwarn "fetching bookmarks";
$mech->get("http://$username.historio.us/export/");
dwarn "extracting links";
my @links = extract_bookmarks($mech->content);
dwarn "got " . scalar(@links) . " links";

foreach my $l (@links) {
	my $output = $wantPath . "/" . hrefToFilename($l->{'href'});
	if( -s $output ) {
		dwarn "$output exists, skipping";
		next;
	}

	dwarn "rendering $output";
	my $tmp = mktemp();
	if(render(
		binary => $phantomJsBinary,
		script => $phantomJsPng,
		input => $l->{'href'},
		timeout => 120,
		output => $tmp,
	)) {
		dwarn "moving $tmp => $output";
		rename($tmp,$output) || croak("$! $@");
	} else {
		carp "rendering $output failed";
	}
}

sub mktemp {
	my $c;
	my $td = ($ENV{'TMPDIR'} || "/tmp/");
	while(1) {
		my $tmp = "$td/historious_output_" . int(rand(99999)) . ".png";
		if(! -f $tmp) {
			dwarn "temporary output to $tmp";
			return $tmp;
		}
		if(++$c > 100) {
			croak "it looks like $wantPath is full of temporary files ($wantPath/historious_output_*), ensure no running processes then remove them";
		}
	}
}

sub extract_bookmarks {
	my $content = shift;
	my $tree = HTML::TreeBuilder->new_from_content($content);

	my @pool;
	foreach my $link ($tree->look_down(_tag => "a")) {
		push(@pool,{ href => $link->attr("HREf"), tags => [split(/, /, $link->attr("TAGS"))] });
	}
	return @pool;
}

sub login {
	my ($mech,$url) = @_;

	$mech->get($url);
	return $mech->submit_form(
		form_number => 1,
		fields      => {
			username    => $username,
			password    => $password,
		}
	);
}


sub render {
	my %args = @_;

	my $dbg = "--debug=" . ($DEBUG>1 ? "true" : "false");

	my $error;	## throw error out of timeout block.
	timeout $args{'timeout'} => sub {
		system($args{'binary'}, "--ignore-ssl-errors=true", "--web-security=false", $dbg, $args{'script'}, $args{'input'}, $args{'output'});
		$error = systemRetError($?,$!);
	};

	if( ($@) || ($error)  || (! -f $args{'output'}) ) {
		carp "rendering $args{'input'} failed, returning error";
		return 0;
	}
	return 1;
}

sub systemRetError {
	my ($ret,$err) = @_;

	my $s;
	if ($ret == -1) {
		$s =  "system() error: failed to execute: $err";
	} elsif ($ret & 127) {
		$s =  sprintf("system() error: child died with signal %d, %s coredump\n", ($ret & 127),  ($ret & 128) ? 'with' : 'without');
	} elsif (sprintf("%d", $ret >> 8) != 0) {
		$s = sprintf("system() error: child exited with value %d\n", $ret >> 8);
	}

	if($s) {
		carp $s;
		return 1;
	}
	return 0;
}

sub hrefToFilename {
	my $input = shift;
	$input =~ s/\W/_/gi;
	return substr(quotemeta($input),0,250) . ".png";
}
