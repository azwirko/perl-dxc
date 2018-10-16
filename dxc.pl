#!/usr/bin/perl

# For Redpitaya & Pavel Demin FT8 code image @ http://pavel-demin.github.io/red-pitaya-notes/sdr-transceiver-ft8

# Gather decodes from FT8 log file /dev/shm/decode-ft8.log file of format 
#    133915 1 0 1 17   0.0  17.0  37.4   3  0.12 10137466 CQ K1RA FM18
# handles msgs: CQ CALL1 GRID, CALL1 CALL2 GRID, CALL1 CALL2 RPT, CALL1 CALL2 RR73, etc.  

# creates DXCluster like spots available via telnet port 7373
# caches calls up to 5 minutes before respotting (see $MINTIME)

# v0.7.1 - 2018/04/12 - K1RA

# Start by using following command line
# ./dxc.pl YOURCALL YOURGRID
# ./dxc.pl WX1YZ AB12DE

use strict;
use warnings;

use IO::Socket;

# minimum number of minutes to cache calls before resending
my $MINTIME = 5;


# check for YOUR CALL SIGN
if( ! defined( $ARGV[0]) || ( ! ( $ARGV[0] =~ /\w\d+\w/)) ) { 
  die "Enter a valid call sign\n"; 
}
my $mycall = uc( $ARGV[0]);

# check for YOUR GRID SQUARE (6 digit)
if( ! defined( $ARGV[1]) || ( ! ( $ARGV[1] =~ /\w\w\d\d\w\w/)) ) { 
  die "Enter a valid 6 digit grid\n";
} 
my $mygrid = uc( $ARGV[1]);

# DXCluster spot line header
my $prompt = "DX de ".$mycall."-#:";

# holds one single log file line
my $line;

# FT8 fields from FT8 decoder log file
my $gmt;
my $x;
my $snr;
my $dt;
my $freq;
my @rest;
my $ft8msg;
my $call;
my $grid;
my $cqde;

# decode current and last times
my $time;
my $ltime;

# hash of deduplicated calls per band
my %db;

# call + base key for %db hash array
my $cb;

# minute counter to buffer decode lines
my $min = 0;

# lookup table to determine base FT8 frequency used to calculate Hz offset
my %basefrq = ( 
  "184" => 1840000,
  "357" => 3573000,
  "535" => 5357000,
  "707" => 7074000,
  "1013" => 10136000,
  "1407" => 14074000,
  "1810" => 18100000,
  "2107" => 21074000,
  "2491" => 24915000,
  "2807" => 28074000,
  "5031" => 50313000
);

# used for calculating signal in Hz from base band FT8 frequency
my $base;
my $hz;

# flag to send new spot
my $send;

# fork and sockets
my $pid;
my $main_sock;
my $new_sock;

$| = 1;

$SIG{CHLD} = sub {wait ()};

# listen for telnet connects on port 7373
$main_sock = new IO::Socket::INET ( LocalPort => 7373,
                                    Listen    => 5,
                                    Proto     => 'tcp',
                                    ReuseAddr => 1,
                                  );
die "Socket could not be created. Reason: $!\n" unless ($main_sock);

while(1) {

# Loop waiting for new inbound telnet connections
while( $new_sock = $main_sock->accept() ) {

  print "New connection - ";
  print $new_sock->peerhost() . "\n";
  
  $pid = fork();
  die "Cannot fork: $!" unless defined( $pid);

  if ($pid == 0) { 
# This is the child process
    print $new_sock "DX de K1RA-# FT8 Skimmer >\n\r";

# setup tail to watch FT8 decoder log file and pipe for reading
# 193245 1 0 1  0   0.0   0.0  29.0  -2  0.31 14076009 K1HTV K1RA FM18
    open( LOG, "< /dev/shm/decode-ft8.log");
# jump to end of file    
    seek LOG, 0, 2;

# Client loop forever
    while(1) {      
# read in lines from FT8 decoder log file 
READ:
      while( $line = <LOG>) {
# check to see if this line says Decoding (end of minute for FT8 decoder)
        if( $line =~ /^Decoding/) { 

# yes - check if its time to expire calls not seen in $MINTIME window
          if( $min++ > $MINTIME) {

# yes - loop thru cache on call+baseband keys
            foreach $cb ( keys %db) {
# extract last time call was seen        
              ( $ltime) = split( "," , $db{ $cb});

# check if last time seen > $MINTIME        
              if( time() > $ltime + ( $MINTIME * 60) ) {
# yes - purge record
                delete $db{ $cb};
              }
            }
# reset 60 minute timer
            $min = 0;
          }
        } # end of a FT8 log decoder minute capture
    
# check if this is a valid FT8 decode line beginning with 6 digit time stamp    
        if( ! ( $line =~ /^\d{6}\s/) ) { 
# no - go to read next line from decoder log
          next READ; 
        }
    
# looks like a valid line split into variable fields
# print $line;
        ($gmt, $x, $x, $x, $x, $x, $x, $x, $snr, $dt, $freq, @rest)= split( " ", $line);

# extract HHMM
        $gmt =~ /^(\d\d\d\d)\d\d/;
        $gmt = $1;
    
# get UNIX time since epoch  
        $time = time();
    
# determine base frequency for this FT8 band decode    
        $base = int( $freq / 10000);

# make freq an integer  
        $freq += 0;

# make the FT8 message by appending remainder of line into one variable, space delimited  
        $ft8msg = join( " ", @rest);
  
# Here are all the various FT8 message scenarios we will recognize, extract senders CALL & GRID
# CQ CALL LLnn 
        if( $ft8msg =~ /^CQ\s([\w\d\/]{3,})\s(\w\w\d\d)/) {
          $call = $1;
          $grid = $2;
          $cqde = "CQ";
# CQ [NA,DX,xx] CALL LLnn  
        } elsif ( $ft8msg =~ /^CQ\s\w{2}\s([\w\d\/]{3,})\s(\w\w\d\d)/) {
          $call = $1;
          $grid = $2;  
          $cqde = "CQ";
# CALL1 CALL2 [R][-+]nn
        } elsif ( $ft8msg =~ /^[\w\d\/]{3,}\s([\w\d\/]{3,})\sR*[\-+][0-9]{2}/) {
          $call = $1;
          $grid = "";
          $cqde = "DE";
# CALL1 CALL2 RRR
        } elsif ( $ft8msg =~ /^[\w\d\/]{3,}\s([\w\d\/]{3,})\sRRR/) {
          $call = $1;
          $grid = "";
          $cqde = "DE";
# CALL1 CALL2 RR73 or 73
        } elsif ( $ft8msg =~ /^[\w\d\/]{3,}\s([\w\d\/]{3,})\sR*73/) {
          $call = $1;
          $grid = "";
          $cqde = "DE";
# CALL1 CALL2 GRID
        } elsif ( $ft8msg =~ /^[\w\d\/]{3,}\s([\w\d\/]{3,})\s(\w\w\d\d)/) {
          $call = $1;
          $grid = $2;
          $cqde = "DE";
        } else {
# we didn't match any message scenario so skip this line
          next READ;
        }

# does the call have at least one number in it
        if( ! ( $call =~ /\d/) ) { 
# no - maybe be TNX, NAME, QSL, so skip this line
          next READ; 
        }
    
# check cache if we have NOT seen this call on this band yet  
        if( ! defined( $db{ $call.$base}) ) { 
# yes - set flag to send it to client(s) 
          $send = 1;

# save to hash array using a key of call+baseband 
          $db{ $call.$base} = $time.",".$call.",".$grid.",".$freq.",".$snr;
        } else {
# no - we have seen call before, so get last time call was sent to client
          ( $ltime) = split( ",", $db{ $call.$base});
      
# test if current time is > first time seen + MINTIME since we last sent to client
          if( time() >= $ltime + ( $MINTIME* 60) ) {
# yes - set flag to send it to client(s) 
            $send = 1;

# resave to hash array with new time
            $db{ $call.$base} = $time.",".$call.",".$grid.",".$freq.",".$snr;
          } else {
# no - don't resend or touch time 
            $send = 0;
          }
        } # end cache check

# make sure call has at least one number in it
        if ( $call =~ /\d/ && $send ) {
          $hz = $freq - $basefrq{ $base};

if( !defined( $base) ) { print "$call $base\n"; }

# send client a spot
# DX de K1RA-#:    14074.8 5Q0X       FT8  -3 dB CQ 1234 Hz JO54        1737z
          printf $new_sock "%-15s %8.1f  %-12s FT8 %3s dB %s %4s Hz %4s   %6sZ\n\r",$prompt,$basefrq{ $base}/1000,$call,$snr,$cqde,$hz,$grid,$gmt;
        }
      
      } # end of reading LOG
    
      sleep 1;
# reset EOF flag    
      seek LOG, 0, 1;
      
      die "Socket is closed" unless $new_sock->connected;
    } # loop client forever
    
  } # else its the parent process, which goes back to accept()

} # main wait for socket loop forever

}
