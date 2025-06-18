#!/bin/bash
set -e

RC_FILE="${1:-demo-openrc.sh}"
if [[ -f "$(dirname "$0")/$RC_FILE" ]]; then
    source "$(dirname "$0")/$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

CSV_FILE="${2:-users.csv}"
if [[ ! -f "$(dirname "$0")/$CSV_FILE" ]]; then
    echo "Nema CSV datoteke $CSV_FILE!"
    exit 1
fi

cd "$(dirname "$0")"

echo "Korisnici iz CSV-a:"
tail -n +2 $CSV_FILE | while IFS=";" read ime prezime rola; do
    echo "  $ime $prezime ($rola)"
done

# Kreiraj mrežu
NETWORK_NAME="demo-net"
SUBNET_NAME="demo-subnet"
ROUTER_NAME="demo-router"
CIDR="10.10.10.0/24"

if ! openstack network show $NETWORK_NAME &>/dev/null; then
    openstack network create $NETWORK_NAME
    openstack subnet create --network $NETWORK_NAME --subnet-range $CIDR $SUBNET_NAME
    openstack router create $ROUTER_NAME
    openstack router add subnet $ROUTER_NAME $SUBNET_NAME
    # Spoji router na external network (zamijeni "public" s tvojim vanjskim networkom ako treba!)
    EXT_NET=$(openstack network list --external -f value -c Name | head -n1)
    openstack router set $ROUTER_NAME --external-gateway $EXT_NET
    echo "Mreža $NETWORK_NAME, subnet $SUBNET_NAME i router $ROUTER_NAME kreirani."
else
    echo "Mreža $NETWORK_NAME već postoji."
fi

# Kreiraj VM (jump host za prvog studenta)
VM_NAME="jump-host-1"
IMAGE_NAME="Ubuntu-22.04"   # Promijeni po potrebi!
FLAVOR_NAME="m1.small"      # Promijeni po potrebi!
KEY_NAME="demo-key"

# Provjeri postoji li keypair, ako ne, generiraj novi
if ! openstack keypair show $KEY_NAME &>/dev/null; then
    openstack keypair create $KEY_NAME > "${KEY_NAME}.pem"
    chmod 600 "${KEY_NAME}.pem"
    echo "Keypair $KEY_NAME kreiran."
fi

if ! openstack server show $VM_NAME &>/dev/null; then
    NET_ID=$(openstack network show $NETWORK_NAME -f value -c id)
    openstack server create \
        --flavor $FLAVOR_NAME \
        --image $IMAGE_NAME \
        --key-name $KEY_NAME \
        --network $NET_ID \
        $VM_NAME
    echo "VM $VM_NAME kreiran."
else
    echo "VM $VM_NAME već postoji."
fi

echo "Osnovna infrastruktura kreirana!"
