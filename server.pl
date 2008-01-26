#!/usr/bin/perl -w
use strict;

my $port = 1225;

use lib "/home/tonh/perl-modules/WEC-SMTP/blib/lib";
use WEC qw(api=1 loop SMTP::Server);
use WEC::Socket qw(inet);

WEC->init;

my $n;
my $socket = inet(LocalPort => $port, 
		  ReuseAddr => 1);
my $server = WEC::SMTP::Server->new(Handle	=> $socket,
				    Mail	=> \&mail);
loop();

sub mail {
    my ($connection, $from, $to, $data) = @_;
    print STDERR "from: $from, to: [@$to]\n--------\n$data--------\n";

    my ($sec,$min,$hour,$mday,$mon,$year) = gmtime;
    my $file = sprintf("cyc_%04d%02d%02d%02d%02d%02d.%03d", 
		       $year+1900, $mon+1, $mday, $hour, $min, $sec, $n++);
    open(my $fh, ">", $file) || die "Could not create $file: $!";
    print($fh $data) || die "Could not write $file: $!";
    close($fh) || die "Could not close $file: $!";
}
