#!/usr/bin/perl
#
# $Id: fwfallover.pl,v 1.6 2006-04-06 11:40:03 atterdag Exp $
#
# fwfallover.pl - Valdemar Lemche <valdemar@lemche.net>
#
# fwfallover.pl is Copyright (C) 2003 Valdemar Lemche.  All rights reserved.
# This script is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
#
# This script is release TOTALLY as it is. If it will have any negative 
# impact on your systems, make you sleepless at night or even be the cause
# of world war; I will claim no responsibility! You may use this script at 
# you OWN risk.
#

$VERSION = "0.4.1.1beta";

# Standard Modules
use Getopt::Std;
use Net::Ping;
use Sys::Syslog;

# Third Party Modules
use Device::SerialPort;
use Net::Ifconfig::Wrapper;
use Net::SNMP;
use Proc::Daemon;
use Proc::PID_File;

# Testing Modules
#use Data::Dumper;

getopts('vfhc:p:');

die "Usage: fwfallover.pl [-v] [-f] [-h] [-c file] [-p pidfile]\n\t-v\tverbosive output\n\t-f\tstay in and print output to foreground\n\t-h\tthis help\n\t-c\tuse file as configuration file\n\t-p\tplace PID in pidfile\n\nversion $VERSION\n" if ($opt_h);

$SIG{'TERM'} = 'shutdown';
$SIG{'INT'}  = 'shutdown';
$SIG{'USR1'} = 'verbose';
$SIG{'USR2'} = 'verbose';

if ($opt_c) { configuration($opt_c); }
else { configuration("/etc/fwfallover.conf"); }

if ($opt_p) { $PIDFile = $opt_p; }
else { $PIDFile = "/var/run/fwfallover.pid"; }

unless ($opt_f) { Proc::Daemon::Init; }

openlog( 'fwfallover.pl', 'cons,pid', $SyslogFacility );
check4pid();
msghandlr( 'alert', "fwfallover.pl version $VERSION started",'' ,'');
msghandlr( 'alert', 'initializing on port:', $PortName, '1' );
my $PortObj = new Device::SerialPort($PortName) || msghandlr( 'crit', "Can't open $PortName:", $!, '2' );
$PortObj->handshake('rts');
$PortObj->baudrate(9600);
$PortObj->parity('odd');
$PortObj->databits(8);
$PortObj->stopbits(1);
$PortObj->user_msg(1);
$PortObj->error_msg(1);

msghandlr( 'notice', 'checking if the other end is initializing...', '', '' );
$PortObj->write("anybody there?\n");
sleep($SleepInterval);
my $input = $PortObj->input;
if ( $input =~ /ping/ ) {
    msghandlr( 'notice', "got ping, sleeping $SleepInterval seconds", '', '3' );
    sleep($SleepInterval);
}
msghandlr( 'info', 'sending initial ping', '', '30' );
$PortObj->write("ping\n");
sleep($SleepInterval);
$input = $PortObj->input;
if ( $input =~ /pong/ ) {
    msghandlr( 'info', 'got pong', '', '41' );
    slave();
}
else {
    msghandlr( 'notice', 'no answer, resending second initial ping', '', '42' );
    $PortObj->write("ping\n");
    sleep($SleepInterval);
    $input = $PortObj->input;
    if ( $input =~ /pong/ ) {
        msghandlr( 'notice', 'got pong', '', '41' );
        slave();
    }
    else {
        msghandlr( 'notice', 'still no answer, resending third initial ping',
            '', '42' );
        $PortObj->write("ping\n");
        sleep($SleepInterval);
        $input = $PortObj->input;
        if ( $input =~ /pong/ ) {
            msghandlr( 'notice', 'got pong', '', '41' );
            slave();
        }
        else {
            master();
        }
    }
}

sub configuration {
    $pingProtocol     = "icmp";
    $pingTimeout      = "0.2";
    $pingPacketSize   = "56";
    $PortName         = "/dev/ttyS0";
    $MasterModeScript = "/etc/init.d/rc.firewall";
    $SleepInterval    = "5";
    $SyslogFacility   = "none";
    $SNMPTRAPReceiver = "none";
    $SNMPCommunity    = "private";
    open( CONFFILE, $_[0] ) || die "Can't open $_[0]: $!\n";
    while (<CONFFILE>) {
        chomp;
        if (/^PortName /) {
            ( $parameter, $PortName ) = split ( / /, $_ );
        }
        if (/^MasterModeScript /) {
            ( $parameter, $MasterModeScript ) = split ( / /, $_ );
        }
        if (/^SleepInterval /) {
            ( $parameter, $SleepInterval ) = split ( / /, $_ );
        }
        if (/^SyslogFacility /) {
            ( $parameter, $SyslogFacility ) = split ( / /, $_ );
        }
        if (/^ThisFirewall /) {
            ( $parameter, $ThisFirewall ) = split ( / /, $_ );
        }
        if (/^OtherFirewall /) {
            ( $parameter, $OtherFirewall ) = split ( / /, $_ );
        }
        if (/^Gateway /) {
            ( $parameter, $Gateway ) = split ( / /, $_ );
        }
        if (/^SNMPTRAPReceiver /) {
            ( $parameter, $SNMPTRAPReceiver ) = split ( / /, $_ );
        }
        if (/^SNMPCommunity /) {
            ( $parameter, $SNMPCommunity ) = split ( / /, $_ );
        }
    }
    close(CONFFILE) || die "Can't close $_[0]: $!\n";
    unless ($ThisFirewall)  { die "Gateway have not been specified in $_[0]\n"; }
    unless ($OtherFirewall) { die "OtherFirewall have not been specified in $_[0]\n"; }
    unless ($Gateway)       { die "ThisFirewall have not been specified in $_[0]\n"; }
}

sub check4pid {
    umask 0122;
    msghandlr( 'crit', "Already running, shutting down...", '', '2' ) if ( hold_pid_file($PIDFile) );
    umask 0;
}

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
        -enterprise   => '.1.3.6.1.4.1.16971.10',
        -agentaddr    => $ThisFirewall,
        -generictrap  => '6',
        -specifictrap => $_[0],
        -varbindlist => [ ".1.3.6.1.4.1.16971.10.0.$_[0]", OCTET_STRING, $_[1] ]
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

sub master {
    msghandlr( 'alert', 'entering master mode', '', '10' );
    system($MasterModeScript) && msghandlr( 'crit', "Can't execute $MasterModeScript: ", $!, '11' ) && exit(1);
    while (1) {
        my $input = $PortObj->input;
        if ( $input =~ /ping/ ) {
            msghandlr( 'info', 'got ping',     '', '31' );
            msghandlr( 'info', 'sending pong', '', '40' );
            $PortObj->write("pong\n");
        }
	else {
	    msghandlr( 'info', 'no ping received', '', '32' );
	}
#        $PortObj->purge_rx;
        $p = Net::Ping->new($pingProtocol, $pingTimeout, $pingPacketSize);
        unless ( $p->ping($OtherFirewall) ) {
	    msghandlr( 'info', 'resending once ICMP ping received to ', 'OtherFirewall','');
            unless ( $p->ping($OtherFirewall) ) {
		msghandlr( 'info', 'resending twice ICMP ping received to ', 'OtherFirewall','');
                unless ( $p->ping($OtherFirewall) ) {
	    	    msghandlr( 'info', 'no ICMP pong received from ', 'OtherFirewall', '44' );
        	    $client = "down";
		}
	    }
        }
	else { 
	    msghandlr( 'info', 'got ICMP pong received from ', 'otherfirewall', '43' );
	}
        unless ( $p->ping($Gateway) ) {
	    msghandlr( 'info', 'resending once ICMP ping received to ', 'Gateway','');
    	    unless ( $p->ping($Gateway) ) {
		msghandlr( 'info', 'resending twice ICMP ping received to ', 'Gateway','');
    		unless ( $p->ping($Gateway) ) {
		    msghandlr( 'info', 'no ICMP pong received from ', 'Gateway', '44' );
        	    $router = "down";
		}
	    }
        }
	else { 
	    msghandlr( 'info', 'got ICMP pong received from ', 'gateway', '43') ;
	}
        $p->close();
        if ( $client eq "down" and $router eq "down" ) {
            slave();
        }
        sleep($SleepInterval);
    }
}

sub slave {
    msghandlr( 'alert', 'entering slave mode', '', '20' );
    mastermodeteardown();
    while (1) {
        $PortObj->purge_tx;
        msghandlr( 'info', 'sending ping', '', '30' );
        $PortObj->write("ping\n");
        sleep($SleepInterval);
        my $input = $PortObj->input;
        if ( $input =~ /pong/ ) {
            msghandlr( 'info', 'got pong', '', '41' );
        }
        else {
            msghandlr( 'warning', 'resending once ping', '', '42' );
            $PortObj->write("ping\n");
            sleep($SleepInterval);
            $input = $PortObj->input;
            if ( $input =~ /pong/ ) {
                msghandlr( 'info', 'got pong', '', '41' );
            }
            else {
                msghandlr( 'warning', 'resending twice ping', '', '30' );
                $PortObj->write("ping\n");
                sleep($SleepInterval);
                $input = $PortObj->input;
                if ( $input =~ /pong/ ) {
                    msghandlr( 'notice', 'got pong', '', '41' );
                }
                else {
                    $p = Net::Ping->new($pingProtocol, $pingTimeout, $pingPacketSize);
                    unless ( $p->ping($OtherFirewall) ) { 
			msghandlr( 'info', 'no ICMP pong received from ', 'otherfirewall', '44' );
			$master = "down";
		    }
		    else {
			msghandlr( 'info', 'got ICMP pong from ', 'otherfirewall', '43' );
		    }
                    if     ( $p->ping($Gateway) ) {
			msghandlr( 'info', 'got ICMP pong received from ', 'gateway', '43');
			$router = "up";
		    }
		    else {
			msghandlr( 'info', 'no ICMP pong received from ', 'gateway', '44' );
		    }
                    $p->close();
                    if ( $master eq "down" and $router eq "up" ) {
                        msghandlr( 'alert', 'master is not responding to ICMP ping; properly down', '', '13' );
                    }
                    msghandlr( 'alert', 'master did not respond to 3 pings over serial port', '', '12' );
		    master();
                }
            }
        }
        sleep($SleepInterval);
    }
}

sub mastermodeteardown {
    msghandlr( 'crit', 'masterModeTearDown', '', '50' );
    my $Info = Net::Ifconfig::Wrapper::Ifconfig( 'list', '', '', '' ) || msghandlr( 'crit', "unable to list interfaces: ", $@, '15' );
#    print Dumper(\%{$Info});
    scalar( keys( %{$Info} ) ) || msghandlr( 'crit', "No interface found. Something wrong?", '', '51' );
    foreach $Iface ( sort( keys( %{$Info} ) ) ) {
#	print "$Iface\n";
        unless ( $Iface eq "lo" ) {
	    unless ( $Info->{$Iface}{'inet'}{$ThisFirewall} ) {
		$Result = Net::Ifconfig::Wrapper::Ifconfig( 'down', $Iface, '', '');
	        $Result or msghandlr( 'alert', "unable to shutdown interface, $Iface: $@", $Iface, '52' );
		$Result = undef;
	    }
            foreach $Ip ( keys %{ $Info->{$Iface}{'inet'} } ) {
                unless ( $Ip eq $ThisFirewall ) {
                    msghandlr( 'notice', "removing $Ip from $Iface", '', '' );
		    $Result = Net::Ifconfig::Wrapper::Ifconfig( '-alias', $Iface, $Ip, '' );
		    $Result or msghandlr( 'alert', "unable to remove ip, $Ip: $@", $Ip, '53' );
		    $Result = undef;
                }
            }
        }
    }
    sleep($SleepInterval);
}

sub shutdown {
    msghandlr( 'crit', "caught $_[0], shutting down gracefully", '', '250' );
    mastermodeteardown();
    undef $PortObj;
    msghandlr( 'notice', "shutdown successful...", '', '251' );
    closelog;
    exit;
}

sub verbose {
    if ( $_[0] eq 'USR1' ) {
	unless ( $opt_v ) {
	    $opt_v;
	    msghandlr( 'notice', "caught $_[0], turning verbosity on", '', '' );
	} else {
	    msghandlr( 'notice', "caught $_[0], but verbosity is already on", '', '' );
	}
    } elsif ( $_[0] eq 'USR2' ) {
	if ( $opt_v ) {
	     undef $opt_v;
	    msghandlr( 'notice', "caught $_[0], verbosity off", '', '' );
	} else {
	    msghandlr( 'notice', "caugth $_[0], but verbosity is already off",'','');
	}
    }
}
