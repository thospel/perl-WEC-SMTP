#!/usr/bin/perl -w
use strict;

use lib "/home/tonh/perl-modules/WEC-SMTP/blib/lib";
use WEC qw(api=1 loop SMTP::Client);

WEC->init;

my $client = WEC::SMTP::Client->new();
my $connection = $client->connect("tcp://dellc640:25");
$connection->mail("TheDude", "tonh\@localhost", "Waf\r\n.\r\nde\r\n\r\n");
$connection->quit;
loop();

