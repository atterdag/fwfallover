#!/bin/sh
#
# $Id: iptables-propagate.sh,v 1.2 2006-04-06 11:40:03 atterdag Exp $
#
# AUTHOR: Valdemar Lemche <valdemar@lemche.net>
#

FIREWALL1=firewall1
FIREWALL2=firewall1

case `hostname` in
    $FIREWALL1)
        TARGET=$FIREWALL2
        ;;
    $FIREWALL2)
        TARGET=$FIREWALL1
        ;;
esac

/usr/bin/scp -q /usr/local/sbin/iptables-propagate.sh $TARGET:/usr/local/sbin/iptables-propagate.sh
/usr/bin/scp -q /etc/fwinterfaces.cfg $TARGET:/etc/fwinterfaces.cfg

echo "Saving Rule Base: "
/etc/init.d/iptables save active
echo 
echo "Transfering Rule Base to $TARGET: "
/usr/bin/scp -q /var/lib/iptables/active $TARGET:/var/lib/iptables/active
echo
echo "Applying Rule base on $TARGET: "
/usr/bin/ssh $TARGET "/etc/init.d/iptables restart"
echo
