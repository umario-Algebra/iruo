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
CSV_FILE="demo-users.csv" # ili putanja do tvoje csv datoteke

# Fixni IP-ovi za WP i LB VM-ove
WP2_1_IP="10.30.0.21"
WP2_2_IP="10.30.0.22"
LB2_IP="10.30.0.11"
WP3_1_IP="10.40.0.21"
WP3_2_IP="10.40.0.22"
LB3_IP="10.40.0.11"

KEYPAIR="demo-key"
FLAVOR="m1.medium"
DEFAULT_SG="13f8719f-d69a-4ff6-9afd-a39a70d01ca1"
VOLUME_SIZE=2

# Mape: VM → mreža
declare -A vms
vms=(
  [demo-vm-minio]="demo-net-minio"
  [demo-vm-test1.instr]="demo-net-test1"
  [demo-vm-test2.stud-jumphost]="demo-net-test2"
  [demo-vm-test2.stud-wp1]="demo-net-test2"
  [demo-vm-test2.stud-wp2]="demo-net-test2"
  [demo-vm-test3.stud-jumphost]="demo-net-test3"
  [demo-vm-test3.stud-wp1]="demo-net-test3"
  [demo-vm-test3.stud-wp2]="demo-net-test3"
  [lb-test2]="demo-net-test2"
  [lb-test3]="demo-net-test3"
)

# Mape: VM → custom image (ili default ubuntu-jammy)
declare -A vm_images
vm_images=(
  [demo-vm-minio]="minio-golden-image"
  [lb-test2]="haproxy-lb-base-test2"
  [lb-test3]="haproxy-lb-base-test3"
  [demo-vm-test1.instr]="ubuntu-jammy"
  [demo-vm-test2.stud-jumphost]="ubuntu-jammy"
  [demo-vm-test2.stud-wp1]="ubuntu-jammy"
  [demo-vm-test2.stud-wp2]="ubuntu-jammy"
  [demo-vm-test3.stud-jumphost]="ubuntu-jammy"
  [demo-vm-test3.stud-wp1]="ubuntu-jammy"
  [demo-vm-test3.stud-wp2]="ubuntu-jammy"
)

# Mape: VM → fiksni IP (za one koji trebaju)
declare -A fixed_ips
fixed_ips=(
  [demo-vm-test2.stud-wp1]=$WP2_1_IP
  [demo-vm-test2.stud-wp2]=$WP2_2_IP
  [lb-test2]=$LB2_IP
  [demo-vm-test3.stud-wp1]=$WP3_1_IP
  [demo-vm-test3.stud-wp2]=$WP3_2_IP
  [lb-test3]=$LB3_IP
  [demo-vm-minio]="10.50.0.11"
)

# ========== 0. KREIRANJE KORISNIKA ==========

echo "== 0. Kreiranje korisnika iz CSV-a =="

if [[ ! -f "$CSV_FILE" ]]; then
    echo "CSV datoteka $CSV_FILE ne postoji!"
    exit 2
fi

tail -n +2 "$CSV_FILE" | while IFS=';' read -r ime prezime rola; do
  USERNAME="${ime}.${prezime}"
  EMAIL="${USERNAME}@cloudlearn.local"
  PASSWORD="TestPSW80!"

  if ! openstack user show "$USERNAME" &>/dev/null; then
    echo "Kreiram korisnika $USERNAME..."
    openstack user create --project demo --password "$PASSWORD" --email "$EMAIL" "$USERNAME"
  else
    echo "Korisnik $USERNAME već postoji, preskačem."
  fi

  if [[ "$rola" == "instruktor" ]]; then
    openstack role add --project demo --user "$USERNAME" admin
    echo "Dodijeljena admin rola korisniku $USERNAME."
  else
    openstack role add --project demo --user "$USERNAME" member
    echo "Dodijeljena member rola korisniku $USERNAME."
  fi
done

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

echo "== 2.1 Kreiranje VM-ova (primarni NIC) =="

for vm in "${!vms[@]}"; do
  net="${vms[$vm]}"
  netid=$(openstack network show "$net" -f value -c id)
  image="${vm_images[$vm]}"
  if ! openstack server show "$vm" &>/dev/null; then
    if [[ -n "${fixed_ips[$vm]}" ]]; then
      ip=${fixed_ips[$vm]}
      echo "Kreiram VM: $vm na mreži: $net (fixni IP: $ip, image: $image)"
      openstack server create \
        --flavor "$FLAVOR" \
        --image "$image" \
        --nic net-id=$netid,v4-fixed-ip=$ip \
        --key-name "$KEYPAIR" \
        --security-group "$DEFAULT_SG" \
        "$vm"
    else
      echo "Kreiram VM: $vm na mreži: $net (image: $image)"
      openstack server create \
        --flavor "$FLAVOR" \
        --image "$image" \
        --nic net-id=$netid \
        --key-name "$KEYPAIR" \
        --security-group "$DEFAULT_SG" \
        "$vm"
    fi
  else
    echo "VM $vm već postoji, preskačem."
  fi
done

echo "== 2.2 Čekanje da svi VM-ovi postanu ACTIVE =="
for vm in "${!vms[@]}"; do
  while true; do
    status=$(openstack server show "$vm" -f value -c status)
    if [[ "$status" == "ACTIVE" ]]; then
      echo "$vm je ACTIVE"
      break
    else
      echo "Čekam na $vm (status: $status)..."
      sleep 5
    fi
  done
done

echo "== 2.3 Dodavanje sekundarnog NIC-a za WP VM-ove (minio net) =="
for vm in demo-vm-test2.stud-wp1 demo-vm-test2.stud-wp2 demo-vm-test3.stud-wp1 demo-vm-test3.stud-wp2; do
  if ! openstack server show "$vm" -f json | grep -q demo-net-minio; then
    echo "Dodajem sekundarni NIC (minio net) na $vm"
    netid=$(openstack network show demo-net-minio -f value -c id)
    openstack server add network "$vm" "$netid"
  else
    echo "$vm već ima NIC na minio mreži, preskačem."
  fi
done

echo "== 2.4 Dodavanje dodatnih diskova na WP VM-ove =="
for vm in demo-vm-test2.stud-wp1 demo-vm-test2.stud-wp2 demo-vm-test3.stud-wp1 demo-vm-test3.stud-wp2; do
  vol="${vm}-2"
  if ! openstack volume show "$vol" &>/dev/null; then
    echo "Kreiram dodatni disk $vol"
    openstack volume create --size $VOLUME_SIZE "$vol"
  fi
  if ! openstack server volume list "$vm" | grep -q "$vol"; then
    echo "Attacham dodatni disk $vol na $vm"
    openstack server add volume "$vm" "$vol" || echo "Volume $vol je već attachan na $vm, preskačem."
  else
    echo "$vm već ima attachan disk $vol, preskačem."
  fi
done

echo "== 2.5 Dodavanje FIKSNIH floating IP-a (192.168.10.101-104) na MinIO, instruktora i jump hostove =="

declare -A floating_ips
floating_ips=(
  [demo-vm-minio]=192.168.10.101
  [demo-vm-test1.instr]=192.168.10.102
  [demo-vm-test2.stud-jumphost]=192.168.10.103
  [demo-vm-test3.stud-jumphost]=192.168.10.104
)

for vm in "${!floating_ips[@]}"; do
  FIP=${floating_ips[$vm]}
  already=$(openstack server show "$vm" -f json | grep "$FIP" || true)
  if [ -z "$already" ]; then
    if ! openstack floating ip show "$FIP" &>/dev/null; then
      openstack floating ip create --floating-ip-address "$FIP" public
    fi
    net="${vms[$vm]}"
    PRIV_IP=$(openstack server show "$vm" -f json | jq -r ".addresses[\"$net\"]" | grep -oP '10\.\d+\.\d+\.\d+')
    if [ -n "$PRIV_IP" ]; then
      echo "Dodajem floating IP $FIP na $vm ($PRIV_IP)"
      openstack server add floating ip --fixed-ip-address "$PRIV_IP" "$vm" "$FIP"
    else
      echo "Nisam našao privatni IP za $vm na mreži $net, preskačem floating IP."
    fi
  else
    echo "$vm već ima floating IP $FIP, preskačem."
  fi
done

echo
echo "== Gotovo! Svi korisnici, mreže, routeri, VM-ovi, diskovi, NIC-evi i floating IP-ovi su spremni. =="
echo
echo "================== REZIME KREIRANIH VM-ova ====================="
printf "%-25s %-22s %-28s %-30s %-10s %s\n" "VM ime" "Image" "IP adrese" "Mreže" "Br. diskova" "Imena diskova"
echo "------------------------------------------------------------------------------------------------------------------------------------"

for vm in "${!vms[@]}"; do
    IMAGE=$(openstack server show "$vm" -f value -c image)
    NETS=$(openstack server show "$vm" -f json | jq -r '.addresses | to_entries | map("\(.key)") | join(", ")')
    IPS=$(openstack server show "$vm" -f json | jq -r '.addresses | to_entries | map(.value | map(.addr) | join(", ")) | join("; ")')
    # Dohvati imena diskova
    VOLS=$(openstack server volume list "$vm" -f value -c Name | xargs | tr ' ' ',')
    VOLNUM=$(openstack server volume list "$vm" -f value | wc -l)
    [[ -z "$VOLS" ]] && VOLS="-"
    printf "%-25s %-22s %-28s %-30s %-10s %s\n" "$vm" "$IMAGE" "$IPS" "$NETS" "$VOLNUM" "$VOLS"
done
echo "================================================================"
