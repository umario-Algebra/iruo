#!/bin/bash
set -e

RC_FILE="${1:-demo-openrc.sh}"
if [[ -f "$(dirname "$0")/$RC_FILE" ]]; then
    source "$(dirname "$0")/$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

NETWORK_NAME="demo-net"
SUBNET_NAME="demo-subnet"
ROUTER_NAME="demo-router"
CIDR="10.50.0.0/24"
EXT_NET="external-net"  # promijeni ime ako ti je drugačije

# Provjera i kreiranje mreže
if openstack network show $NETWORK_NAME &>/dev/null; then
    echo "Mreža $NETWORK_NAME već postoji."
else
    openstack network create $NETWORK_NAME
    echo "Kreirana mreža: $NETWORK_NAME"
fi

# Provjera i kreiranje subnet-a
if openstack subnet show $SUBNET_NAME &>/dev/null; then
    echo "Subnet $SUBNET_NAME već postoji."
else
    openstack subnet create --network $NETWORK_NAME --subnet-range $CIDR $SUBNET_NAME
    echo "Kreiran subnet: $SUBNET_NAME"
fi

# Provjera i kreiranje routera
if openstack router show $ROUTER_NAME &>/dev/null; then
    echo "Router $ROUTER_NAME već postoji."
else
    openstack router create $ROUTER_NAME
    echo "Kreiran router: $ROUTER_NAME"
fi

# Dodavanje subneta routeru (ako već nije dodan)
if openstack router show $ROUTER_NAME -f json | grep -q $SUBNET_NAME; then
    echo "Subnet $SUBNET_NAME je već spojen na router $ROUTER_NAME."
else
    openstack router add subnet $ROUTER_NAME $SUBNET_NAME
    echo "Spojen subnet $SUBNET_NAME na router $ROUTER_NAME."
fi

# Povezivanje routera na vanjsku mrežu
if openstack router show $ROUTER_NAME -f json | grep -q $EXT_NET; then
    echo "Router $ROUTER_NAME je već spojen na external-net."
else
    openstack router set $ROUTER_NAME --external-gateway $EXT_NET
    echo "Router $ROUTER_NAME sada ima vanjski gateway na $EXT_NET."
fi

echo "Gotovo! Kreirani su mreža, subnet i router u projektu $OS_PROJECT_NAME."
