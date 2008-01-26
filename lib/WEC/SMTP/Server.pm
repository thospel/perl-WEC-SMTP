package WEC::SMTP::Server;
use 5.006;
use strict;
use warnings;
use Carp;

use WEC::SMTP::Connection::Server;
use WEC::SMTP::Constants qw(PORT);

our $VERSION = "0.01";
our @CARP_NOT	= qw(WEC::FieldServer);

use base qw(WEC::Server);

my $default_options = {
    %{__PACKAGE__->SUPER::server_options},
    ServerName		=> "WEC::SMTP",
    ServerVersion	=> $WEC::SMTP::Connection::Server::VERSION,
    GreetingHost	=> undef,
    Mail		=> undef,
};

sub default_options {
    return $default_options;
}

sub default_port {
    return PORT;
}

sub connection_class {
    return "WEC::SMTP::Connection::Server";
}

1;
