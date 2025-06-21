#!/bin/bash
set -e

RC_FILE="/etc/kolla/demo-openrc.sh"
if [[ -f "$RC_FILE" ]]; then
    source "$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

EXT_NET="public"

# -------- Helper funkcija za router <-> subnet vezu --------
router_has_subnet() {
    local ROUTER=$1
    local SUBNET=$2
    openstack router show "$ROUTER" -f json | grep -q "$(openstack subnet show $SUBNET -f value -c id)"
}

# -------- test1 --------
NETWORK_NAME="demo-net-test1"
SUBNET_NAME="demo-net-test1-subnet"
ROUTER_NAME="demo-router-test1"
CIDR="10.20.0.0/24"

if ! openstack network show $NETWORK_NAME &>/dev/null; then
    openstack network create --tag course=test $NETWORK_NAME
fi

if ! openstack subnet show $SUBNET_NAME &>/dev/null; then
    openstack subnet create --network $NETWORK_NAME --subnet-range $CIDR --tag course=test $SUBNET_NAME
fi

if ! openstack router show $ROUTER_NAME &>/dev/null; then
    openstack router create $ROUTER_NAME
fi

if ! router_has_subnet $ROUTER_NAME $SUBNET_NAME; then
    openstack router add subnet $ROUTER_NAME $SUBNET_NAME
fi

if [[ "$(openstack router show $ROUTER_NAME -f value -c external_gateway_info)" != *$EXT_NET* ]]; then
    openstack router set $ROUTER_NAME --external-gateway $EXT_NET
fi

# -------- test2 --------
NETWORK_NAME="demo-net-test2"
SUBNET_NAME="demo-net-test2-subnet"
ROUTER_NAME="demo-router-test2"
CIDR="10.30.0.0/24"

if ! openstack network show $NETWORK_NAME &>/dev/null; then
    openstack network create --tag course=test $NETWORK_NAME
fi

if ! openstack subnet show $SUBNET_NAME &>/dev/null; then
    openstack subnet create --network $NETWORK_NAME --subnet-range $CIDR --tag course=test $SUBNET_NAME
fi

if ! openstack router show $ROUTER_NAME &>/dev/null; then
    openstack router create $ROUTER_NAME
fi

if ! router_has_subnet $ROUTER_NAME $SUBNET_NAME; then
    openstack router add subnet $ROUTER_NAME $SUBNET_NAME
fi

if [[ "$(openstack router show $ROUTER_NAME -f value -c external_gateway_info)" != *$EXT_NET* ]]; then
    openstack router set $ROUTER_NAME --external-gateway $EXT_NET
fi

# -------- test3 --------
NETWORK_NAME="demo-net-test3"
SUBNET_NAME="demo-net-test3-subnet"
ROUTER_NAME="demo-router-test3"
CIDR="10.40.0.0/24"

if ! openstack network show $NETWORK_NAME &>/dev/null; then
    openstack network create --tag course=test $NETWORK_NAME
fi

if ! openstack subnet show $SUBNET_NAME &>/dev/null; then
    openstack subnet create --network $NETWORK_NAME --subnet-range $CIDR --tag course=test $SUBNET_NAME
fi

if ! openstack router show $ROUTER_NAME &>/dev/null; then
    openstack router create $ROUTER_NAME
fi

if ! router_has_subnet $ROUTER_NAME $SUBNET_NAME; then
    openstack router add subnet $ROUTER_NAME $SUBNET_NAME
fi

if [[ "$(openstack router show $ROUTER_NAME -f value -c external_gateway_info)" != *$EXT_NET* ]]; then
    openstack router set $ROUTER_NAME --external-gateway $EXT_NET
fi

# -------- MINIO --------
NETWORK_NAME="demo-net-minio"
SUBNET_NAME="demo-net-minio-subnet"
ROUTER_NAME="demo-router-minio"
CIDR="10.50.0.0/24"

if ! openstack network show $NETWORK_NAME &>/dev/null; then
    openstack network create --tag course=test $NETWORK_NAME
fi

if ! openstack subnet show $SUBNET_NAME &>/dev/null; then
    openstack subnet create --network $NETWORK_NAME --subnet-range $CIDR --tag course=test $SUBNET_NAME
fi

if ! openstack router show $ROUTER_NAME &>/dev/null; then
    openstack router create $ROUTER_NAME
fi

if ! router_has_subnet $ROUTER_NAME $SUBNET_NAME; then
    openstack router add subnet $ROUTER_NAME $SUBNET_NAME
fi

if [[ "$(openstack router show $ROUTER_NAME -f value -c external_gateway_info)" != *$EXT_NET* ]]; then
    openstack router set $ROUTER_NAME --external-gateway $EXT_NET
fi

echo "Sve mreže, subneti i routeri su spremni!"
