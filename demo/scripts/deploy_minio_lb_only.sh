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
TAG="course=test"
KEYPAIR="demo-key"
IMAGE="ubuntu-jammy"
FLAVOR="m1.medium"
DEFAULT_SG="13f8719f-d69a-4ff6-9afd-a39a70d01ca1" # OVDJE je ručno upisan ID!
VOLUME_SIZE=2

# ========== 1. KREIRANJE MREŽA, ROUTERA, SUBNETA ==========

echo
echo "== 1. Kreiranje mreža, subnet-a i routera =="

declare -A networks
networks=(
  [demo-net-test1]="10.20.0.0/24"
  [demo-net-test2]="10.30.0.0/24"
  [demo-net-test3]="10.40.0.0/24"
  [demo-net-minio]="10.50.0.0/24"
)

router_has_subnet() {
    local ROUTER=$1
    local SUBNET=$2
    openstack router show "$ROUTER" -f json | grep -q "$(openstack subnet show $SUBNET -f value -c id)"
}

for net in "${!networks[@]}"; do
    subnet="${net}-subnet"
    router="demo-router-${net#demo-net-}"
    cidr="${networks[$net]}"

    echo "--- Obrada mreže $net ---"

    if ! openstack network show $net &>/dev/null; then
        echo "Kreiram mrežu: $net"
        openstack network create --tag $TAG $net
    else
        echo "Mreža $net već postoji, preskačem."
    fi

    if ! openstack subnet show $subnet &>/dev/null; then
        echo "Kreiram subnet: $subnet"
        openstack subnet create --network $net --subnet-range $cidr --tag $TAG $subnet
    else
        echo "Subnet $subnet već postoji, preskačem."
    fi

    if ! openstack router show $router &>/dev/null; then
        echo "Kreiram router: $router"
        openstack router create $router
    else
        echo "Router $router već postoji, preskačem."
    fi

    if ! router_has_subnet $router $subnet; then
        echo "Dodajem subnet $subnet na router $router"
        openstack router add subnet $router $subnet
    else
        echo "Subnet $subnet je već na routeru $router, preskačem."
    fi

    if [[ "$(openstack router show $router -f value -c external_gateway_info)" != *$EXT_NET* ]]; then
        echo "Spajam router $router na vanjsku mrežu $EXT_NET"
        openstack router set $router --external-gateway $EXT_NET
    else
        echo "Router $router je već spojen na $EXT_NET, preskačem."
    fi
done

echo "Sve mreže, subneti i routeri su spremni!"

# ========== 2. VM DEPLOYMENT: samo MinIO i LB VM-ovi s fiksnim IP-evima ==========

echo
echo "== 2. Deploy MinIO i LB VM-ova s fiksnim IP-evima =="

declare -A fixed_ips
fixed_ips=(
    [demo-vm-minio]="10.50.0.11"
    [lb-test2]="10.30.0.11"
    [lb-test3]="10.40.0.11"
)

declare -A vms
vms=(
    [demo-vm-minio]="demo-net-minio"
    [lb-test2]="demo-net-test2"
    [lb-test3]="demo-net-test3"
)

for vm in "${!vms[@]}"; do
    net="${vms[$vm]}"
    ip="${fixed_ips[$vm]}"
    if ! openstack server show "$vm" &>/dev/null; then
        echo "Kreiram VM: $vm na mreži: $net s IP: $ip"
        openstack server create \
            --flavor "$FLAVOR" \
            --image "$IMAGE" \
            --nic net-id=$(openstack network show "$net" -f value -c id),v4-fixed-ip="$ip" \
            --key-name "$KEYPAIR" \
            --security-group "$DEFAULT_SG" \
            "$vm"
    else
        echo "VM $vm već postoji, preskačem."
    fi
done

echo
echo "== 3. Dodavanje floating IP-a na MinIO VM =="

MINIO_FIP="192.168.10.101"
MINIO_VM="demo-vm-minio"

already=$(openstack server show "$MINIO_VM" -f json | grep "$MINIO_FIP" || true)
if [ -z "$already" ]; then
    if ! openstack floating ip show "$MINIO_FIP" &>/dev/null; then
        openstack floating ip create --floating-ip-address "$MINIO_FIP" public
    fi
    PRIV_IP="10.50.0.11"
    echo "Dodajem floating IP $MINIO_FIP na $MINIO_VM ($PRIV_IP)"
    openstack server add floating ip --fixed-ip-address "$PRIV_IP" "$MINIO_VM" "$MINIO_FIP"
else
    echo "$MINIO_VM već ima floating IP $MINIO_FIP, preskačem."
fi

echo
echo "== Gotovo! MinIO VM i dva LB VM-a su spremni s fiksnim IP adresama. =="
