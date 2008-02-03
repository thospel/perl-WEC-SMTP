package WEC::SMTP::Connection::Server;
use 5.006;
use strict;
use warnings;
use Carp;
use Sys::Hostname;
use Socket qw(inet_aton AF_INET);
use POSIX qw(strftime);

my $LF = "\x0a";
my $CR = "\x0d";
my $CRLF = "$CR$LF";

my @extensions = qw(HELP);

use WEC::Connection qw(SERVER CLIENT);

our $VERSION = "1.000";

use base qw(WEC::Connection);

our @CARP_NOT	= qw(WEC::FieldConnection);
# use fields qw(greeting_host helo_host mail_from mail_to);

use constant {
    HELO	=> 1,
    MAIL	=> 2,
};

sub init_server {
    my __PACKAGE__ $connection = shift;

    # No multiplexing in SMTP
    $connection->{host_mpx}	= 0;
    $connection->{peer_mpx}	= 0;

    $connection->{greeting_host} =
	defined $connection->{options}{GreetingHost} ?
	$connection->{options}{GreetingHost} : hostname;

    $connection->{in_want}	= 0;
    $connection->{in_process}	= \&server_greeting;
}

sub server_greeting {
    my __PACKAGE__ $connection = shift;

    # Unportable. %z is a GNU extension
    my $time = strftime("%a, %d %b %Y %H:%M:%S %z", localtime);
    $time =~ s/, 0/, /;

    my $peer_address = $connection->peer_address;
    ($connection->{peer_ip}) = $peer_address =~ m!^tcp://(.*):\d+\z! or
	croak "Could not parse peer address $peer_address";
    my $iaddr = inet_aton($connection->{peer_ip});
    $connection->{peer_name} = gethostbyaddr($iaddr, AF_INET);
    $connection->{peer_name} = "unknown" unless
	defined $connection->{peer_name};
    $connection->{peer} = "$connection->{peer_name} [$connection->{peer_ip}]";
    $connection->{mode} = "SMTP";

    my $greeting = "$connection->{greeting_host} ESMTP";
    if (defined $connection->{options}{ServerName}) {
	$greeting .= " $connection->{options}{ServerName}";
	$greeting .= " $connection->{options}{ServerVersion}" if
	    defined $connection->{options}{ServerVersion};
    }
    $connection->send(220, "$greeting; $time");
    $connection->start_state;
}

my %dispatch =
    (QUIT => \&d_quit,
     HELO => \&d_helo,
     EHLO => \&d_ehlo,
     MAIL => \&d_mail,
     RCPT => \&d_rcpt,
     DATA => \&d_data,
     NOOP => \&d_noop,
     RSET => \&d_rset,
     HELP => \&d_help,
     VRFY => \&d_vrfy,
     );

sub d_noop {
    my __PACKAGE__ $connection = shift;
    $connection->send(250, "OK");
}

sub d_rset {
    my __PACKAGE__ $connection = shift;
    $connection->start_state;
    $connection->send(250, "Reset state");
}

sub d_quit {
    my __PACKAGE__ $connection = shift;
    $connection->send_close(221, "$connection->{greeting_host} closing connection");
}

sub start_state {
    my __PACKAGE__ $connection = shift;

    # State reset
    $connection->{in_state}	= HELO;
    $connection->{in_want}	= 1;
    $connection->{in_process}	= \&want_line;

    # Data reset
    $connection->{mail_from} = undef;
    $connection->{mail_to} = [];
    $connection->{mail_data} = undef;
}

sub d_helo {
    (my __PACKAGE__ $connection, my $line) = @_;
    if ($line !~ /^\s*HELO\s+(\S+)\s*\z/i) {
	$connection->send(501, "Invalid domain name");
	return;
    }
    $connection->{helo_host} = $1;
    $connection->{mode} = "SMTP";

    $connection->send(250, "$connection->{greeting_host} Hello $connection->{peer}, pleased to meet you");
    $connection->start_state;
}

sub d_ehlo {
    (my __PACKAGE__ $connection, my $line) = @_;
    if ($line !~ /^\s*EHLO\s+(\S+)\s*\z/i) {
	$connection->send(501, "Invalid domain name");
	return;
    }
    $connection->{helo_host} = $1;
    $connection->{mode} = "ESMTP";

    $connection->send(250, "$connection->{greeting_host} Hello $connection->{peer}, pleased to meet you", @extensions);
    $connection->start_state;
}

sub d_mail {
    my __PACKAGE__ $connection = shift;
    if ($connection->{in_state} != HELO) {
	$connection->send(503, "Sender already specified");
	return;
    }
    my $line = shift;
    if ($line !~ /^\s*MAIL\s+FROM\s*:\s*(.*\S)\s*\z/i) {
	$connection->send(501, "Syntax error in parameters scanning");
	return;
    }
    my $raw_from = $1;
    my $from = $raw_from =~ /^<(.*)>\z/ ? $1 : $raw_from;

    $connection->send(250, "$raw_from... Sender ok");
    $connection->{mail_from} = $from;
    $connection->{in_state} = MAIL;
}

sub d_rcpt {
    my __PACKAGE__ $connection = shift;
    if ($connection->{in_state} != MAIL) {
	$connection->send(503, "Need MAIL before RCPT");
	return;
    }
    my $line = shift;
    if ($line !~ /^\s*RCPT\s+TO\s*:\s*(.*\S)\s*\z/i) {
	$connection->send(501, "Syntax error in parameters scanning");
	return;
    }
    my $raw_to = $1;
    my $to = $raw_to =~ /^<(.*)>\z/ ? $1 : $raw_to;

    $connection->send(250, "$raw_to... Recipient ok");
    push @{$connection->{mail_to}}, $to;
}

sub d_vrfy {
    my __PACKAGE__ $connection = shift;
    $connection->send(252, "Cannot VRFY user; try RCPT to attempt delivery (or try finger)");
}

sub rfc822_escape {
    my $text = shift;
    return $text unless $text =~ /[()<>\@,;:\\\".\[\] \x00-\x1f\x7f]/;
    $text =~ s/([\"\\$CR])/\\$1/og;
    return qq("$text");
}

sub rfc822_comment_escape {
    my $text = shift;
    return $text unless $text =~ /[\\()$CR]/o;
    $text =~ s/([\\()$CR])/\\$1/og;
    return $text;
}

# --Ton Still needs to be implemented
sub rfc822_path_escape {
    return shift;
}

sub d_data {
    my __PACKAGE__ $connection = shift;
    if ($connection->{in_state} != MAIL) {
	# $connection->{in_state} == HELO
	$connection->send(503, "Need MAIL command");
	return;
    }
    if (!@{$connection->{mail_to}}) {
	$connection->send(503, "Need RCPT (recipient)");
	return;
    }

    $connection->{mail_data} =
	sprintf("Received: from %s (%s)",
		rfc822_escape($connection->{helo_host}),
		rfc822_comment_escape($connection->{peer}));
    if (defined $connection->{options}{ServerName}) {
	$connection->{mail_data} .=
	    " by " . rfc822_escape($connection->{options}{ServerName});
	$connection->{mail_data} .= " (" .
	    rfc822_comment_escape($connection->{options}{ServerVersion}) . ")"
	    if defined $connection->{options}{ServerVersion};
    }
    $connection->{mail_data} .= " with $connection->{mode}";
    $connection->{mail_data} .=
	sprintf(" for <%s>", rfc822_path_escape(@{$connection->{mail_to}})) if
	@{$connection->{mail_to}} == 1;
    # The date we add is when we start receiving DATA
    my $time = strftime("%a, %d %b %Y %H:%M:%S %z", localtime);
    $time =~ s/, 0/, /;
    $connection->{mail_data} .= "; $time$CRLF";

    $connection->send(354, 'Enter mail, end with "." on a line by itself');
    $connection->{in_process}	= \&want_dot;
}

sub d_help {
    (my __PACKAGE__ $connection, my $line) = @_;
    if ($line =~ /^\s*HELP\s+(.*\S)\s*\z/i) {
	my $topic = uc $1;
	if (!$dispatch{$topic}) {
	    $connection->send(504, "HELP topic \"$1\" unknown");
	    return;
	}
	$connection->send(214, "Nobody bothered to write this help");
    } else {
	my $line = "";
	if (defined($connection->{options}{ServerName})) {
	    $line .= "This is $connection->{options}{ServerName}";
	    $line .= " version $connection->{options}{ServerVersion}" if
		defined $connection->{options}{ServerVersion};
	    $line .= "\n";
	}
	$line .= "Topics:\n";
	my @commands = sort keys %dispatch;
	while (@commands) {
	    $line .= "      ";
	    for (my $i=0; $i<4 && @commands; $i++) {
		$line .= sprintf("%-7s", shift @commands);
	    }
	    $line .= "\n";
	}
	$line .= "For more info use \"HELP <topic>\".\n";
	$line .= "End of HELP info";
	$connection->send(214, $line);
    }
}

sub want_line {
    # Probably should check for line getting too long here
    my __PACKAGE__ $connection = shift;
    my $pos = index $_, $LF, $connection->{in_want}-1;
    if ($pos < 0) {
	$connection->{in_want} = 1+length;
	return;
    }
    my $line = substr($_, 0, $pos+1, "");
    $connection->{in_want} = 1;
    $line =~ s/$CR?$LF\z//o;
    if (my ($command) = $line =~ /(\S+)/) {
	if (my $fun = $dispatch{uc($command)}) {
	    $fun->($connection, $line);
	    return;
	}
    }
    $connection->send(500, "Command unrecognized: \"$line\"");
}

sub want_dot {
    my __PACKAGE__ $connection = shift;
    # Wrong! ^ is after \n, not $LF which need not be the same
    if (/^\.$CR?$LF/om) {
	$connection->{mail_data} .= substr($_, 0, $-[0]);
	substr($_, 0, $+[0]) = "";
	$connection->data;
	return;
    }
    if ($_ eq "." || $_ eq ".$CR") {
	$connection->{in_want} = 1+length;
	return;
    }
    $connection->{in_want} = 1;
    my $pos = rindex $_, $LF;
    if ($pos < 0) {
	$connection->{in_process} = \&want_newline;
	$connection->{mail_data} .= $_;
	$_ = "";
	return;
    }
    $connection->{mail_data} .= substr($_, 0, $pos+1, "");
}

sub want_newline {
    my __PACKAGE__ $connection = shift;
    if (/$LF\.$CR?$LF/o) {
	$connection->{mail_data} .= substr($_, 0, $-[0]+1);
	substr($_, 0, $+[0]) = "";
	$connection->data;
	return;
    }
    my $pos = rindex $_, $LF;
    if ($pos < 0) {
	$connection->{mail_data} .= $_;
	$_ = "";
	return;
    }
    $connection->{mail_data} .= substr($_, 0, $pos+1, "");
    $connection->{in_process} = \&want_dot;
}

sub data {
    my __PACKAGE__ $connection = shift;
    die "No Mail handler\n" unless $connection->{options}{Mail};
    # Wrong! ^ is after \n, not $LF which need not be the same
    $connection->{mail_data} =~ s/^\.//mg;
    $connection->{options}{Mail}->($connection,
				   $connection->{mail_from},
				   $connection->{mail_to},
				   $connection->{mail_data});
    # $connection->send(451, "Requested action aborted: error in processing: $error");
    $connection->send(250, "Message accepted for delivery");

    $connection->{in_want} = 1;
    $connection->{in_process} = \&want_line;

    $connection->start_state;
}

sub send : method {
    my __PACKAGE__ $connection = shift;
    die "Attempt to send on a closed Connection" unless
        $connection->{out_handle};
    my $code = sprintf("%03d", shift);
    die "Message is utf8" if utf8::is_utf8($_[0]);
    my @lines = map {split /\n/} @_ or croak "Empty message";
    my $last  = pop @lines;

    $connection->send0 if $connection->{out_buffer} eq "";
    $connection->{out_buffer} .= "$code-$_$CRLF" for @lines;
    $connection->{out_buffer} .= "$code $last$CRLF";
}

1;
