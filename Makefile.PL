#!/usr/bin/perl -w
# $Id: Makefile.PL 2693 2008-01-02 09:54:19Z hospelt $
use 5.006;
use ExtUtils::MakeMaker;
use vars qw($VERSION);
$VERSION = "1.000";

WriteMakefile
    (NAME	=> 'WEC::SMTP',
     VERSION	=> '0.01', # finds $VERSION
     PREREQ_PM	=> {
	 WEC		=> 0.01,
	 "Test::More"	=> 0.11,	# For the tests only
     },
     AUTHOR	=> 'Ton Hospel <WEC::SMTP@ton.iguana.be>',
     $^O eq "MSWin32" ? (
         PM_FILTER	=> '$(PERL) -p -e1',
     ) : (),
     clean		=> {
         FILES => '$(DISTNAME).ppd ppm cover_db',
     },
);

# START MY
# END MY
