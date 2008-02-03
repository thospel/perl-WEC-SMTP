package WEC::SMTP::Connection::Client;
use 5.006;
use strict;
use warnings;
use Carp;
use Socket qw(sockaddr_family unpack_sockaddr_in AF_INET);

my $lf = "\x0a";
my $cr = "\x0d";
my $crlf = "$cr$lf";

use WEC::Connection qw(SERVER CLIENT);

our $VERSION = "1.000";

use base qw(WEC::Connection);

our @CARP_NOT	= qw(WEC::FieldConnection);

use constant {
    GREETING	=> 1,
};

my @allowed_modes = qw(TEXT BINARY);
my %allowed_modes = map {$_ => 1 } @allowed_modes;

sub init_client {
    my __PACKAGE__ $connection = shift;

    # No multiplexing in SMTP
    $connection->{host_mpx}	= 0;
    $connection->{peer_mpx}	= 0;

    $connection->{in_want}	= 1;
    $connection->{in_process}	= \&response;
    $connection->{in_state}	= \&greeting;
    $connection->{lines}	= [""];
    $connection->{to_do}	= [];
    $connection->begin_handshake;
}

sub response {
    my __PACKAGE__ $connection = shift;
    # print STDERR "response: '$_'\n";
    my $pos = index($_, $lf);
    if ($pos < 0) {
	$connection->{lines}[-1] .= $_;
	$_ = "";
	return;
    }
    $connection->{lines}[-1] .= substr($_, 0, $pos+1, "");
    if ($connection->{lines}[-1] !~ s/\A(\d+)[^\S$lf]/$1-/) {
	push @{$connection->{lines}}, "";
	return;
    }
    my $code = $1;
    my $lines = $connection->{lines};
    $connection->{lines} = [""];
    for (@$lines) {
	s/$cr?$lf\z//g;
	s/\A\Q$code-// || croak "Line does not start with $code-";
    }
    $connection->{in_state}->($connection, $code, $lines);
}

sub greeting {
    (my __PACKAGE__ $connection, my $code, my $greeting) = @_;
    if ($code != 220) {
	die "Unexpected answer $code @$greeting. Should become a callback";
    }
    if (defined($connection->{options}{ClientHost})) {
	$connection->{hello_client} = $connection->{options}{ClientHost};
    } else {
	my $handle = $connection->{in_handle} || die "No in_handle";
	my $sockaddr = getsockname($handle);
	my $family = sockaddr_family($sockaddr);
	$family == AF_INET || die "Unexpected socket family $family";
	my ($port, $addr) = unpack_sockaddr_in($sockaddr);
	if (defined(my $name = gethostbyaddr($addr, $family))) {
	    $name =~ /\A[a-z0-9.-]+\z/ || die "Invalid hostname '$name'";
	    $connection->{hello_client} = $name;
	} else {
	    $connection->{hello_client} = "[" . inet_ntoa($addr) . "]";
	}
    }
    # print STDERR "helo=$connection->{hello_client}\n";
    $connection->{in_state}	= \&ehlo;
    $connection->send("EHLO $connection->{hello_client}");
}

sub parse_hello {
    my __PACKAGE__ $connection = shift;
    my $hello = shift;
    my ($domain, $rest) = $hello =~ /\A\s*(\S+)(.*)\z/ or
	croak "Could not parse helo response $hello";
    $connection->{hello_server} = $domain;
    if ($rest =~ s/\A\s+//) {
	$rest =~ s/\s+\z//;
	$connection->{hello_greeting} = $rest;
    }
}

sub ehlo {
    (my __PACKAGE__ $connection, my $code, my $extensions) = @_;
    if ($code == 500 || $code == 502) {
	$connection->{in_state}	= \&helo;
	$connection->send("HELO $connection->{hello_client}");
	return;
    } elsif ($code != 250) {
	die "Unexpected EHLO answer $code @$extensions. Should become a callback";
    }
    $connection->parse_hello(shift @$extensions);
    my %extensions;
    for (@$extensions) {
	my ($keyword, @params) = split " ", uc $_;
	next unless defined $keyword;
	die "Multiple declarations of extension $keyword" if 
	    $extensions{$keyword};
	$extensions{$keyword} = \@params;
    }
    $connection->{extensions} = \%extensions;
    $connection->{in_state}   = \&silence;
    $connection->end_handshake;
}

sub silence {
    (my __PACKAGE__ $connection, my $code, my $lines) = @_;
    die "Unexpected lines from server: $code @$lines";
}

sub helo {
    (my __PACKAGE__ $connection, my $code, my $answer) = @_;
    if ($code != 250) {
	die "Unexpected HELO answer $code @$answer. Should become a callback";
    }
    $connection->parse_hello(shift @$answer);
    $connection->{extensions} = undef;
    
    print STDERR "helo=$code @$answer\n";
    $connection->{in_state} = \&silence;
    $connection->end_handshake;
}

# returns:
#  undef if we know nothing about any extensions (plain unextended SMTP)
#  0     if the extension wasn't announced
#  [params] if the extension was announced (the params array can be empty)
sub extension_parameters {
    my __PACKAGE__ $connection = shift;
    return unless $connection->{extensions};
    my $extension = uc shift;
    return $connection->{extensions}{$extension} || 0;
}

sub mail {
    (my __PACKAGE__ $connection, my %options) = @_;
    croak "Attempt to send on a closed Connection" unless
        $connection->{out_handle};
    croak "Already quit" if $connection->{has_quit};

    defined(my $from = delete $options{From}) ||
	croak "No From specified";
    defined(my $to = delete $options{To}) ||
	croak "No To specified";
    defined(my $message = delete $options{Message}) ||
	croak "No Message specified";
    my $mode = delete $options{Message};
    $mode = "text" if !defined $mode;
    $mode = uc $mode;
    $allowed_modes{$mode} || die "Unknown mode '$mode'";
    
    # Should do more serious rfc checking here --Ton
    croak "Invalid From" if $from =~ /$lf/;

    my @to = grep {
	defined() || croak "Undefined To";
	croak "Invalid To" if /$lf/;
	1;
    } ref $to ? @$to : $to;
    @to || croak "No To";

    utf8::downgrade($message, 1) || croak "Wide character in message";
    $message =~ s/\r?\n/$crlf/g if $mode eq "text";
    # Incorrect, $lf is not necessarily \n, so ^ is wrong
    $message =~ s/^\./../mg;
    $message .= "$crlf.";

    push @{$connection->{to_do}}, ["MAIL", $from, \@to, $message, -1];
    return if $connection->{cork};
    $connection->start_command;
}

sub quit {
    my __PACKAGE__ $connection = shift;
    croak "Already quit" if $connection->{has_quit};
    $connection->{has_quit} = 1;
    push @{$connection->{to_do}}, ["QUIT"];
    return if $connection->{cork};
    $connection->start_command;
}

sub start_command {
    my __PACKAGE__ $connection = shift;
    return if 
	!@{$connection->{to_do}} || $connection->{in_state} != \&silence;
    my $command = $connection->{to_do}[0][0];
    if ($command eq "QUIT") {
	# But what if some older command is still pending ??
	$connection->send_close("QUIT");
    } elsif ($command eq "MAIL") {
	$connection->send("MAIL FROM:<$connection->{to_do}[0][1]>");
	$connection->{in_state} = \&mail_from;
    } else {
	croak "start_command '$command' unimplemented";
    }
}

sub mail_from {
    (my __PACKAGE__ $connection, my $code, my $answer) = @_;
    if ($code != 250) {
	shift @{$connection->{to_do}};
	$connection->{in_state} = \&silence;
	die "Unexpected MAIL FROM answer $code @$answer. Should become a callback";
    }
    my $to = $connection->{to_do}[0][2][++$connection->{to_do}[0][4]];
    $connection->send("RCPT TO:<$to>");
    $connection->{in_state} = \&rcpt_to;
}

sub rcpt_to {
    (my __PACKAGE__ $connection, my $code, my $answer) = @_;
    if ($code != 250 && $code != 251) {
	shift @{$connection->{to_do}};
	$connection->{in_state} = \&silence;
	# Probably should do something extra for code 551
	die "Unexpected RCPT TO answer $code @$answer. Should become a callback";
    }
    my $to = $connection->{to_do}[0][2][++$connection->{to_do}[0][4]];
    if (defined($to)) {
	$connection->send("RCPT TO:<$to>");
    } else {
	$connection->send("DATA");
	$connection->{in_state} = \&data;
    }
}

sub data {
    (my __PACKAGE__ $connection, my $code, my $answer) = @_;
    if ($code != 354) {
	shift @{$connection->{to_do}};
	$connection->{in_state} = \&silence;
	die "Unexpected DATA answer $code @$answer. Should become a callback";
    }

    $connection->send($connection->{to_do}[0][3]);
    $connection->{to_do}[0][3] = undef;
    $connection->{in_state} = \&data_done;
}

sub data_done {
    (my __PACKAGE__ $connection, my $code, my $answer) = @_;
    shift @{$connection->{to_do}};
    $connection->{in_state} = \&silence;
    if ($code != 250) {
	die "Unexpected DATA submission answer $code @$answer. Should become a callback";
    }
    $connection->start_command;
}

sub uncork {
    my __PACKAGE__ $connection = shift;
    $connection->SUPER::uncork(@_);
    $connection->start_command;
}

sub send : method {
    my __PACKAGE__ $connection = shift;
    die "Attempt to send on a closed Connection" unless
        $connection->{out_handle};
    croak "utf8 encoded string" if utf8::is_utf8($_[0]);

    # print STDERR "send: $message\n";
    $connection->send0 if $connection->{out_buffer} eq "";
    $connection->{out_buffer} .= shift;
    $connection->{out_buffer} .= $crlf;
}

1;
