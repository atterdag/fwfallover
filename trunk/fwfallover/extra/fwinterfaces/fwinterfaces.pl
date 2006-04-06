#!/usr/bin/perl
#
# $Id: fwinterfaces.pl,v 1.2 2006-04-06 11:40:03 atterdag Exp $
#
# AUTHOR: Valdemar Lemche <valdemar@lemche.net>
#
# fwinterfaces.pl is Copyright (C) 2003 Valdemar Lemche.  All rights reserved.
# This script is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
#
# This script is release TOTALLY as it is. If it will have any negative 
# impact on your systems, make you sleepless at night or even be the cause
# of world war; I will claim no responsibility! You may use this script at 
# you OWN risk.
#

use Net::Ifconfig::Wrapper;
use Sys::Syslog;
use Getopt::Std;

getopts('c:v');

if ($opt_c) {
    $config = $opt_c;
}
else {
    $config = "/etc/fwinterfaces.cfg";
}
$syslog_facility  = "local3";
$SNMPTRAPReceiver = "none"; # use "none" to disable SNMP
$SNMPCommunity    = "none"; # use "none" to disable SNMP

openlog( 'fwinterfaces.pl', 'cons,pid', $syslog_facility );

open( CONFIG, $config ) || die "can't open $config, $!\n";
while (<CONFIG>) {
    chomp $_;
    unless ( $_ =~ /^#/ ) {
        ( $IfaceName, $Addr, $Mask ) = split ( /:/, $_ );
        my $IfaceInfo = Net::Ifconfig::Wrapper::Ifconfig( 'list', '', '', '' );
        if ( $IfaceInfo->{$IfaceName}{'status'} eq "0" ) {
	    msghandlr( 'notice', "bringing up $IfaceName with address $Addr", '', '');
            $Result = Net::Ifconfig::Wrapper::Ifconfig( 'inet', $IfaceName, $Addr, $Mask );
	    $Result or msghandlr( 'alert', "unable to bring up $IfaceName with $Ip: $@", '$@', '1' );
	    $Result = undef;
        }
        else {
            for $ip ( keys %{ $IfaceInfo->{$IfaceName}{'inet'} } ) {
                if ( $ip eq $Addr ) { $found = 1; }
            }
            if ( $found eq 1 ) {
		msghandlr( 'notice', "$Addr is found on interface $IfaceName which is up: not adding", '', '');
            }
            else {
		msghandlr( 'info', "adding to $IfaceName address $Addr netmask $Mask", '', '' );
                $Result = Net::Ifconfig::Wrapper::Ifconfig( 'alias', $IfaceName, $Addr, $Mask );
		$Result or msghandlr( 'alert', "unable to add $Addr netmask $Mask to $IfaceName: $@", '$@', '2' );
		$Result = undef;
            }
        }
    }
}
close(CONFIG);
closelog;

sub msghandlr {
    if ( $_[0] eq 'info' ) {
        if ($opt_v) {
            msgsendr( $_[0], $_[1], $_[2], $_[3] );
        }
    }
    else {
        msgsendr( $_[0], $_[1], $_[2], $_[3] );
    }
}

sub msgsendr {
    unless ( $SyslogFacility eq "none" ) {
        syslog( $_[0], "$_[1]$_[2]" );
    }
    unless ( $SNMPTRAPReceiver eq "none" ) {
        unless ( $_[3] eq '' ) {
            snmptrap( $_[3], $_[2] );
        }
    }
    if ($opt_f) {
        $now = localtime;
        print "$now: $_[1]$_[2]\n";
    }
}

sub snmptrap {
    my ( $session, $error ) = Net::SNMP->session(
        -hostname    => $SNMPTRAPReceiver,
        -community   => $SNMPCommunity,
        -port        => 162,
        -nonblocking => 0x1
    );
    if ( !defined($session) ) {
        printf( "ERROR: %s.\n", $error );
        msghandlr( 'crit', 'snmp session could not be established: ', $error, '' );
    }
    my $result = $session->trap(
        -enterprise   => '.1.3.6.1.4.1.16971.11',
        -generictrap  => '6',
        -specifictrap => $_[0],
        -varbindlist => [ ".1.3.6.1.4.1.16971.11.0.$_[0]", OCTET_STRING, $_[1] ]
    );
    if ( !defined($result) ) {
        printf( "ERROR: %s.\n", $session->error );
        $session->close;
        msghandlr( 'crit', 'snmp trap sending failed: ', "$session->error",
            '' );
    }
    $session->snmp_event_loop;
    $session->close;
}
