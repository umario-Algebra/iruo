#!/bin/bash
set -e

RC_FILE="/etc/kolla/demo-openrc.sh"
if [[ -f "$RC_FILE" ]]; then
    source "$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

echo "== 1. Brišem VM-ove =="

vms=(minio-vm lb-test2 lb-test3 wp2-1 wp2-2 wp3-1 wp3-2 jumphost2 jumphost3 instruktor)
for vm in "${vms[@]}"; do
  if openstack server show "$vm" &>/dev/null; then
    echo "Brišem VM: $vm"
    openstack server delete "$vm"
  fi
done

# Pričekaj da VM-ovi nestanu
for vm in "${vms[@]}"; do
  while openstack server show "$vm" &>/dev/null; do
    echo "Čekam da se VM $vm obriše..."
    sleep 5
  done
done

echo "== 2. Brišem volumene =="

for vm in wp2-1 wp2-2 wp3-1 wp3-2; do
  for i in 1 2; do
    vol="${vm}-data-$i"
    if openstack volume show "$vol" &>/dev/null; then
      echo "Brišem volume: $vol"
      openstack volume delete "$vol"
    fi
  done
done

echo "== 3. Brišem portove (primarne i dodatne) =="

# Primarni portovi
for vm in "${vms[@]}"; do
  portname="${vm}-primarni-port"
  if openstack port show "$portname" &>/dev/null; then
    echo "Brišem port: $portname"
    openstack port delete "$portname"
  fi
done

# WP minio portovi
for vm in wp2-1 wp2-2 wp3-1 wp3-2; do
  portname="${vm}-minio-port"
  if openstack port show "$portname" &>/dev/null; then
    echo "Brišem port: $portname"
    openstack port delete "$portname"
  fi
done

# Instruktor dodatni portovi
for net in demo-net-test2 demo-net-test3 demo-net-minio; do
  portname="instruktor-${net}-port"
  if openstack port show "$portname" &>/dev/null; then
    echo "Brišem port: $portname"
    openstack port delete "$portname"
  fi
done

echo "== 4. Brišem floating IP adrese =="

for ip in 192.168.10.123 192.168.10.124 192.168.10.122; do
  if openstack floating ip show "$ip" &>/dev/null; then
    echo "Brišem floating IP: $ip"
    openstack floating ip delete "$ip"
  fi
done

echo "== 5. Brišem security grupe =="

for sg in student-secgroup instruktor-secgroup; do
  if openstack security group show "$sg" &>/dev/null; then
    echo "Brišem security group: $sg"
    openstack security group delete "$sg"
  fi
done

echo "== 6. Brišem korisnike iz CSV-a =="

CSV_FILE="demo-users.csv"
if [[ -f "$CSV_FILE" ]]; then
  tail -n +2 "$CSV_FILE" | while IFS=';' read -r ime prezime rola; do
    USERNAME="${ime}.${prezime}"
    if openstack user show "$USERNAME" &>/dev/null; then
      echo "Brišem korisnika $USERNAME"
      openstack user delete "$USERNAME"
    fi
  done
fi

echo "== 7. Brišem grupe =="

for group in studenti instruktori; do
  if openstack group show "$group" &>/dev/null; then
    echo "Brišem grupu: $group"
    openstack group delete "$group"
  fi
done

echo "== 8. Brišem routere =="

for router in demo-router-test1 demo-router-test2 demo-router-test3 demo-router-minio; do
  if openstack router show "$router" &>/dev/null; then
    # Makni sve subnetove s routera
    subnets=$(openstack router show "$router" -f json | jq -r '.interfaces_info[]?.subnet_id')
    for subnet_id in $subnets; do
      echo "Maknem subnet $subnet_id sa routera $router"
      openstack router remove subnet "$router" "$subnet_id" || true
    done
    echo "Brišem router: $router"
    openstack router delete "$router"
  fi
done

echo "== 9. Brišem subnetove =="

for net in demo-net-test1 demo-net-test2 demo-net-test3 demo-net-minio; do
  subnet="${net}-subnet"
  if openstack subnet show "$subnet" &>/dev/null; then
    echo "Brišem subnet: $subnet"
    openstack subnet delete "$subnet"
  fi
done

echo "== 10. Brišem mreže =="

for net in demo-net-test1 demo-net-test2 demo-net-test3 demo-net-minio; do
  if openstack network show "$net" &>/dev/null; then
    echo "Brišem mrežu: $net"
    openstack network delete "$net"
  fi
done

echo "== Cleanup završio! =="
