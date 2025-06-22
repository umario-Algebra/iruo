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
CSV_FILE="demo-users.csv"
KEYPAIR="labkey"
FLAVOR="m1.medium"
DEFAULT_SG="d1e98563-c312-4f20-840b-3c156f3568af"
VOLUME_SIZE=1

# VM → primarna mreža
declare -A vms=(
  [minio-vm]="demo-net-minio"
  [lb-test2]="demo-net-test2"
  [lb-test3]="demo-net-test3"
  [wp2-1]="demo-net-test2"
  [wp2-2]="demo-net-test2"
  [wp3-1]="demo-net-test3"
  [wp3-2]="demo-net-test3"
  [jumphost2]="demo-net-test2"
  [jumphost3]="demo-net-test3"
  [instruktor]="demo-net-test1"
)
declare -A vm_images=(
  [minio-vm]="minio-golden"
  [lb-test2]="lb-golden"
  [lb-test3]="lb-golden-test3"
  [wp2-1]="wp-golden"
  [wp2-2]="wp-golden"
  [wp3-1]="wp-golden"
  [wp3-2]="wp-golden"
  [jumphost2]="ubuntu-jammy"
  [jumphost3]="ubuntu-jammy"
  [instruktor]="ubuntu-jammy"
)
declare -A fixed_ips=(
  [wp2-1]="10.30.0.21"
  [wp2-2]="10.30.0.22"
  [lb-test2]="10.30.0.11"
  [wp3-1]="10.40.0.21"
  [wp3-2]="10.40.0.22"
  [lb-test3]="10.40.0.11"
  [minio-vm]="10.50.0.11"
  [jumphost2]="10.30.0.10"
  [jumphost3]="10.40.0.10"
  [instruktor]="10.20.0.10"
)

declare -A minio_ips=(
  [wp2-1]="10.50.0.21"
  [wp2-2]="10.50.0.22"
  [wp3-1]="10.50.0.23"
  [wp3-2]="10.50.0.24"
)
declare -A instruktor_ips=(
  [demo-net-test2]="10.30.0.100"
  [demo-net-test3]="10.40.0.100"
  [demo-net-minio]="10.50.0.100"
)

declare -A secgroups=(
  [minio-vm]="instruktor-secgroup"
  [lb-test2]="student-secgroup"
  [lb-test3]="student-secgroup"
  [wp2-1]="student-secgroup"
  [wp2-2]="student-secgroup"
  [wp3-1]="student-secgroup"
  [wp3-2]="student-secgroup"
  [jumphost2]="student-secgroup"
  [jumphost3]="student-secgroup"
  [instruktor]="instruktor-secgroup"
)

# ========== 0. KREIRANJE SECURITY GRUPA, GRUPA I KORISNIKA ==========

echo "== 0. Kreiranje security grupa =="
if ! openstack security group show student-secgroup &>/dev/null; then
  openstack security group create student-secgroup --description "Default grupa za studente"
  openstack security group rule create --proto icmp student-secgroup
  openstack security group rule create --proto tcp --dst-port 22 student-secgroup
  openstack security group rule create --proto tcp --dst-port 80 student-secgroup
  openstack security group rule create --proto tcp --dst-port 443 student-secgroup
  openstack security group rule create --proto tcp --dst-port 9000 student-secgroup
  openstack security group rule create --proto tcp --dst-port 2049 student-secgroup
  openstack security group rule create --proto udp --dst-port 2049 student-secgroup
fi
if ! openstack security group show instruktor-secgroup &>/dev/null; then
  openstack security group create instruktor-secgroup --description "Default grupa za instruktore"
  openstack security group rule create --proto icmp instruktor-secgroup
  openstack security group rule create --proto tcp --dst-port 22 instruktor-secgroup
  openstack security group rule create --proto tcp --dst-port 80 instruktor-secgroup
  openstack security group rule create --proto tcp --dst-port 443 instruktor-secgroup
  openstack security group rule create --proto tcp --dst-port 9000 instruktor-secgroup
  openstack security group rule create --proto tcp --dst-port 2049 instruktor-secgroup
  openstack security group rule create --proto udp --dst-port 2049 instruktor-secgroup
fi

echo "== 0.1 Kreiranje grupa u OpenStacku =="
if ! openstack group show studenti &>/dev/null; then
  openstack group create studenti --description "Svi studenti"
fi
if ! openstack group show instruktori &>/dev/null; then
  openstack group create instruktori --description "Svi instruktori"
fi

echo "== 0.2 Kreiranje korisnika iz CSV-a =="
if [[ ! -f "$CSV_FILE" ]]; then
    echo "CSV datoteka $CSV_FILE ne postoji!"
    exit 2
fi
tail -n +2 "$CSV_FILE" | while IFS=';' read -r ime prezime rola; do
  USERNAME="${ime}.${prezime}"
  EMAIL="${USERNAME}@cloudlearn.local"
  PASSWORD="TestPSW80!"
  if ! openstack user show "$USERNAME" &>/dev/null; then
    openstack user create --project demo --password "$PASSWORD" --email "$EMAIL" "$USERNAME"
  fi
  if [[ "$rola" == "instruktor" ]]; then
    openstack role add --project demo --user "$USERNAME" admin
    openstack group add user instruktori "$USERNAME"
  else
    openstack role add --project demo --user "$USERNAME" member
    openstack group add user studenti "$USERNAME"
  fi
done

echo
echo "== 1. Kreiranje mreža, subnet-a i routera =="

declare -A networks=(
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
    if ! openstack network show $net &>/dev/null; then
        openstack network create --tag $TAG $net
    fi
    if ! openstack subnet show $subnet &>/dev/null; then
        openstack subnet create --network $net --subnet-range $cidr --tag $TAG $subnet
    fi
    if ! openstack router show $router &>/dev/null; then
        openstack router create $router
    fi
    if ! router_has_subnet $router $subnet; then
        openstack router add subnet $router $subnet
    fi
    if [[ "$(openstack router show $router -f value -c external_gateway_info)" != *$EXT_NET* ]]; then
        openstack router set $router --external-gateway $EXT_NET
    fi
done

echo "Sve mreže, subneti i routeri su spremni!"

# ========== 2. KREIRANJE SVIH PORTOVA PRIJE VM BOOTA ==========

declare -A ports_primarni
for vm in "${!vms[@]}"; do
    net="${vms[$vm]}"
    subnet="${net}-subnet"
    ip="${fixed_ips[$vm]}"
    portname="${vm}-primarni-port"
    if ! openstack port show "$portname" &>/dev/null; then
        echo "Kreiram primarni port $portname ($ip/$net)"
        ports_primarni[$vm]=$(openstack port create --network "$net" --fixed-ip subnet=$subnet,ip-address=$ip "$portname" -f value -c id)
    else
        ports_primarni[$vm]=$(openstack port show "$portname" -f value -c id)
    fi
done

declare -A ports_wp_minio
for vm in wp2-1 wp2-2 wp3-1 wp3-2; do
    ip="${minio_ips[$vm]}"
    portname="${vm}-minio-port"
    if ! openstack port show "$portname" &>/dev/null; then
        echo "Kreiram minio port $portname ($ip)"
        ports_wp_minio[$vm]=$(openstack port create --network demo-net-minio --fixed-ip subnet=demo-net-minio-subnet,ip-address=$ip "$portname" -f value -c id)
    else
        ports_wp_minio[$vm]=$(openstack port show "$portname" -f value -c id)
    fi
done

declare -A ports_instruktor_extra
for net in "${!instruktor_ips[@]}"; do
    ip="${instruktor_ips[$net]}"
    portname="instruktor-${net}-port"
    subnet="${net}-subnet"
    if ! openstack port show "$portname" &>/dev/null; then
        echo "Kreiram instruktor port $portname ($ip/$net)"
        ports_instruktor_extra[$net]=$(openstack port create --network "$net" --fixed-ip subnet=$subnet,ip-address=$ip "$portname" -f value -c id)
    else
        ports_instruktor_extra[$net]=$(openstack port show "$portname" -f value -c id)
    fi
done

# ========== 3. KREIRANJE VM-ova SVI PORTOVI ODMAH ==========

echo "== Kreiram VM-ove s portovima =="

for vm in "${!vms[@]}"; do
    image="${vm_images[$vm]}"
    net="${vms[$vm]}"
    secgroup="${secgroups[$vm]}"
    primary_port_id="${ports_primarni[$vm]}"
    extra_nics=""
    if [[ "$vm" == "instruktor" ]]; then
        for netname in "${!instruktor_ips[@]}"; do
            extra_nics+=" --nic port-id=${ports_instruktor_extra[$netname]}"
        done
    fi
    if [[ "$vm" =~ ^wp ]]; then
        extra_nics+=" --nic port-id=${ports_wp_minio[$vm]}"
    fi
    if ! openstack server show "$vm" &>/dev/null; then
        echo "Kreiram VM: $vm ($image) ..."
        openstack server create \
            --flavor "$FLAVOR" \
            --image "$image" \
            --nic port-id=$primary_port_id \
            $extra_nics \
            --key-name "$KEYPAIR" \
            --security-group "$secgroup" \
            "$vm"
    else
        echo "$vm već postoji, preskačem."
    fi
done

echo "== 4. Čekanje da svi VM-ovi postanu ACTIVE =="
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

# 5. Dodavanje 2 dodatna diska samo na WP VM-ove
echo "== 5. Dodavanje 2 dodatna diska samo na WP VM-ove =="
for vm in wp2-1 wp2-2 wp3-1 wp3-2; do
  for i in 1 2; do
    vol="${vm}-data-$i"
    if ! openstack volume show "$vol" &>/dev/null; then
      echo "Kreiram volume: $vol"
      openstack volume create --size $VOLUME_SIZE "$vol"
    fi
    if ! openstack server volume list "$vm" | grep -q "$vol"; then
      echo "Attacham volume: $vol na $vm"
      openstack server add volume "$vm" "$vol" || echo "Volume $vol je već attachan na $vm, preskačem."
    fi
  done
done

# 6. Dodavanje FIP samo na jump hostove i instruktora
echo "== 6. Dodavanje FIP samo na jump hostove i instruktora =="
declare -A floating_ips=(
  [jumphost2]=192.168.10.123
  [jumphost3]=192.168.10.124
  [instruktor]=192.168.10.122
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
      openstack server add floating ip --fixed-ip-address "$PRIV_IP" "$vm" "$FIP"
    fi
  fi
done

# ========== MOCK IZVJEŠTAJ ==========

echo
echo "== Gotovo! Svi korisnici, mreže, routeri, VM-ovi, diskovi, NIC-evi i floating IP-ovi su spremni. =="
echo
printf "%-12s %-14s %-40s %-40s %-20s\n" "VM ime" "Image" "Primarni IP (mreža)" "Sek. IP-ovi (minio/test2/test3)" "Diskovi"
echo "------------------------------------------------------------------------------------------------------------------------------------"

for vm in minio-vm lb-test2 lb-test3 wp2-1 wp2-2 wp3-1 wp3-2 jumphost2 jumphost3 instruktor; do
    img="${vm_images[$vm]}"
    prim_net="${vms[$vm]}"
    prim_ip="${fixed_ips[$vm]}"
    sekundarni=""
    if [[ "$vm" =~ ^wp ]]; then
        sekundarni="${minio_ips[$vm]} (minio)"
    elif [[ "$vm" == "instruktor" ]]; then
        sekundarni="${instruktor_ips[demo-net-test2]} (test2), ${instruktor_ips[demo-net-test3]} (test3), ${instruktor_ips[demo-net-minio]} (minio)"
    fi
    disks="-"
    if [[ "$vm" =~ ^wp ]]; then
        disks="${vm}-data-1, ${vm}-data-2"
    fi
    printf "%-12s %-14s %-22s %-40s %-20s\n" "$vm" "$img" "$prim_ip ($prim_net)" "$sekundarni" "$disks"
done
echo "------------------------------------------------------------------------------------------------------------------------------------"

