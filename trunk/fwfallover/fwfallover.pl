#!/usr/bin/perl
#
# fwfallover.pl - Valdemar Lemche <valdemar@lemche.net>
#
# This script is release TOTALLY as it is, and under no license at all. If it
# will have any negative impact on your systems, make you sleepless at night
# or cause world war, I claim no responsibility!
#
# The script is just a tiny perl script I made to make two firewalls perform
# simple fallover using the serial port to avoid network issues.
#
# Basically its just a simple master/slave relation. Master is the side that
# comes up first and the slave checks if master is up, if not, the slave will
# try to become the master itself.
#

use Device::SerialPort;
use Getopt::Std;
use Net::Ifconfig::Wrapper;
use Net::Ping;
use Net::SNMP;
use Sys::Syslog;

getopts('vfh');

die "Usage: fwfallover.pl [-v] [-f] [-h]\n\t-v verbose output\n\t-f print output to foreground\n\t-h this help\n\nversion 0.1 alpha\n" if ($opt_h);

#
# IMPORTENT OPTIONS ARE SET HERE!
#
$PortName         = "/dev/ttyS0";
$MasterModeScript = "/usr/local/sbin/nonofwinterfaces.pl";
$SleepInterval    = "5";
$SyslogFacility   = "local3";
$ThisFirewall     = "192.116.202.103";
$OtherFirewall    = "192.116.202.90";
$Gateway          = "192.116.202.1";
$SNMPTRAPReceiver = "192.116.202.103";
$SNMPCommunity    = "private";
$pingProtocol     = "icmp";

openlog( 'fwfallover.pl', 'cons,pid', $SyslogFacility );
syslog( 'alert', "initializing on port: $PortName" );
snmptrap( '1', "$PortName");
if ($opt_f) {
    $now = localtime;
    print "$now: initializing on port: $PortName\n";
}
my $PortObj = new Device::SerialPort("$PortName") || errorhandler("Can't open $PortName:","$!","2");
$PortObj->handshake('rts');
$PortObj->baudrate(9600);
$PortObj->parity("odd");
$PortObj->databits(8);
$PortObj->stopbits(1);
$PortObj->user_msg(1);
$PortObj->error_msg(1);

syslog( 'info', 'checking if the other end is initializing...' );
if ($opt_f) {
    $now = localtime;
    print "$now: checking if the other end is initializing...\n";
}
$PortObj->write("anybody there?\n");
sleep($SleepInterval);
my $input = $PortObj->input;
if ( $input =~ /ping/ ) {
    syslog( 'notice', 'got ping, sleeping $SleepInterval seconds' );
    snmptrap('3', 'sleeping');
    if ($opt_f) {
        $now = localtime;
        print "$now: got ping, sleeping $SleepInterval seconds\n";
    }
    sleep($SleepInterval);
}

syslog( 'info', 'sending initial ping' );
if ($opt_f) {
    $now = localtime;
    print "$now: sending initial ping\n";
}
$PortObj->write("ping\n");
sleep($SleepInterval);
$input = $PortObj->input;
if ( $input =~ /pong/ ) {
    loginput( 'info', 'pong' );
    slave();
} else {
    syslog( 'notice', 'no answer, resending second initial ping' );
    if ($opt_f) {
        $now = localtime;
        print "$now: no answer, resending second initial ping\n";
    }
    $PortObj->write("ping\n");
    sleep($SleepInterval);
    $input = $PortObj->input;
    if ( $input =~ /pong/ ) {
        loginput( 'notice', 'pong' );
        slave();
    } else {
        syslog( 'notice', 'still no answer, resending third initial ping' );
        if ($opt_f) {
            $now = localtime;
            print "$now: still no answer, resending third initial ping\n";
        }
        $PortObj->write("ping\n");
        sleep($SleepInterval);
        $input = $PortObj->input;
        if ( $input =~ /pong/ ) {
            loginput( 'notice', 'pong' );
            slave();
        } else {
            master();
        }
    }
}

closelog;

sub master {
    syslog( 'alert', 'entering master mode' );
    snmptrap( '10', '');
    if ($opt_f) {
        $now = localtime;
        print "$now: entering master mode\n";
    }
    system($MasterModeScript);# || errorhandler("Can't execute $MasterModeScript:", "$!", "11");
    while (1) {
        my $input = $PortObj->input;
        if ( $input =~ /ping/ ) {
            loginput( 'info', 'ping' );
            logsend( 'info',  'pong' );
            $PortObj->write("pong\n");
        }
        $PortObj->purge_rx;
        $p = Net::Ping->new($pingProtocol);
        unless ($p->ping($OtherFirewall)) { $client = "down"; }
        unless ($p->ping($Gateway)) { $router = "down"; }
        $p->close();
        if ( $client eq "down" and $router eq "down" ) { slave(); }
        sleep($SleepInterval);
    }
}

sub slave {
    syslog( 'alert', 'entering slave mode' );
    snmptrap('20','');
    if ($opt_f) {
        $now = localtime;
        print "$now: entering slave mode\n";
    }
    mastermodeteardown();
    while (1) {
        $PortObj->purge_tx;
        logsend( 'info', 'ping' );
        $PortObj->write("ping\n");
        sleep($SleepInterval);
        my $input = $PortObj->input;
        if ( $input =~ /pong/ ) {
            loginput( 'info', 'pong' );
        } else {
            syslog( 'warning', 'resending once ping' );
            snmptrap('41','1');
            if ($opt_f) {
                $now = localtime;
                print "$now: resending once ping\n";
            }
            $PortObj->write("ping\n");
            sleep($SleepInterval);
            $input = $PortObj->input;
            if ( $input =~ /pong/ ) {
                loginput( 'notice', 'pong' );
            } else {
                syslog( 'warning', 'resending twice ping' );
                snmptrap( '41','2');
                if ($opt_f) {
                    $now = localtime;
                    print "$now: resending twice ping\n";
                }
                $PortObj->write("ping\n");
                sleep($SleepInterval);
                $input = $PortObj->input;
                if ( $input =~ /pong/ ) {
                    loginput( 'notice', 'pong' );
                } else {
                    $p = Net::Ping->new($pingProtocol);
                    unless ( $p->ping($OtherFirewall)) { $master = "down"; }
                    if ( $p->ping($Gateway)) { $router = "up"; }
                    $p->close();
                    if ( $master eq "down" and $router eq "up" ) {
                        snmptrap('13','');
                        master();
                    }
                    snmptrap('12','');
                }
            }
        }
        sleep($SleepInterval);
    }
}

sub loginput {
    if ($opt_v) {
        syslog( $_[0], "got $_[1]" );
        if ( $_[1] eq "ping" ) {
            snmptrap('30','1')
        } elsif ( $_[1] eq "pong" ) {
            snmptrap('40','1')
        }
        if ($opt_f) {
            $now = localtime;
            print "$now: got $_[1]\n";
        }
    }
}

sub logsend {
    if ($opt_v) {
        syslog( $_[0], "sending $_[1]" );
        if ($opt_f) {
            $now = localtime;
            print "$now: sending $_[1]\n";
        }
    }
}

sub snmptrap {
    my ($session, $error) = Net::SNMP->session(-hostname=>$SNMPTRAPReceiver,
                                               -community=>$SNMPCommunity,
                                               -port => 162
                                              );
    if (!defined($session)) {
        printf("ERROR: %s.\n", $error);
        syslog('crit', "snmp session could not be established: $error");
    }
    my $result = $session->trap(-enterprise => '1.3.6.1.4.1',
                                -agentaddr => $ThisFirewall,
                                -generictrap => '6',
                                -specifictrap => '0',
                                -varbindlist => [ "1.3.6.1.4.1.16971.10.0.$_[0]", OCTET_STRING, $_[1]]
                               );
    if (!defined($result)) {
        printf("ERROR: %s.\n", $session->error);
        $session->close;
        syslog('crit',"snmp trap sending failed: $session->error");
    }
    $session->close;
}

sub errorhandler {
    $message = $_[0];
    $error = $_[1];
    $snmptrap = $_[2];
    syslog('alert',"$_[0]: $_[1]");
    snmptrap( $snmptrap, $error);
    die "$_[0]: $_[1]\n";
}

sub mastermodeteardown {
    syslog('crit','masterModeTearDown');
    snmptrap('14','1');
    my $Info = Net::Ifconfig::Wrapper::Ifconfig('list', '', '', '') or errorhandler("unable to list interfaces","$@", '15');
    scalar(keys(%{$Info})) or errorhandler("No one interface found. Something wrong?",'1','15');
    foreach $Iface (sort(keys(%{$Info}))) {
        unless ( $Iface eq "lo") {
            foreach $Ip ( keys %{ $Info->{$Iface}{'inet'} } ) {
                unless ( $Ip eq $ThisFirewall ) {
                    $Result = Net::Ifconfig::Wrapper::Ifconfig('-alias', $Iface, $Ip, '');
                    $Result or syslog('alert',"unable to remove ip, $Ip: $@");
                }
            }
        }
    }
    sleep($SleepInterval);
}
