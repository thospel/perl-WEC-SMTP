package WEC::SMTP::Client;
use 5.006;
use strict;
use warnings;
use Carp;

use WEC::SMTP::Connection::Client;
use WEC::SMTP::Constants qw(PORT);

our $VERSION = "0.01";
our @CARP_NOT	= qw(WEC::FieldClient);

use base qw(WEC::Client);

my $default_options = {
    %{__PACKAGE__->SUPER::client_options},
    ClientHost	=> undef,
};

sub default_options {
    return $default_options;
}

sub connection_class {
    return "WEC::SMTP::Connection::Client";
}

1;
