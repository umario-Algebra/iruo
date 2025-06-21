#!/bin/bash
set -e

source /etc/kolla/demo-openrc.sh

KEYPAIR="demo-key"
IMAGE="ubuntu-jammy"
FLAVOR="m1.medium"
DEFAULT_SG="13f8719f-d69a-4ff6-9afd-a39a70d01ca1"
VOLUME_SIZE=2

# VM -> mreža
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
)

echo "== 1. Kreiranje VM-ova (primarni NIC) =="
for vm in "${!vms[@]}"; do
  net="${vms[$vm]}"
  if ! openstack server show "$vm" &>/dev/null; then
    echo "Kreiram VM: $vm na mreži: $net"
    openstack server create \
      --flavor "$FLAVOR" \
      --image "$IMAGE" \
      --nic net-id=$(openstack network show "$net" -f value -c id) \
      --key-name "$KEYPAIR" \
      --security-group "$DEFAULT_SG" \
      "$vm"
  else
    echo "VM $vm već postoji, preskačem."
  fi
done

echo "== 2. Čekanje da svi VM-ovi postanu ACTIVE =="
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

echo "== 3. Dodavanje sekundarnog NIC-a za WP VM-ove (minio net) =="
for vm in demo-vm-test2.stud-wp1 demo-vm-test2.stud-wp2 demo-vm-test3.stud-wp1 demo-vm-test3.stud-wp2; do
  # Provjeri postoji li već NIC na minio mreži
  if ! openstack server show "$vm" -f json | grep -q demo-net-minio; then
    echo "Dodajem sekundarni NIC (minio net) na $vm"
    netid=$(openstack network show demo-net-minio -f value -c id)
    openstack server add network "$vm" "$netid"
  else
    echo "$vm već ima NIC na minio mreži, preskačem."
  fi
done

echo "== 4. Dodavanje dodatnih diskova na WP VM-ove =="
for vm in demo-vm-test2.stud-wp1 demo-vm-test2.stud-wp2 demo-vm-test3.stud-wp1 demo-vm-test3.stud-wp2; do
  vol="${vm}-2"
  if ! openstack volume show "$vol" &>/dev/null; then
    echo "Kreiram dodatni disk $vol"
    openstack volume create --size $VOLUME_SIZE "$vol"
  fi
  # Attach disk ako nije već attachan
  if ! openstack server volume list "$vm" | grep -q "$vol"; then
    echo "Attacham dodatni disk $vol na $vm"
    openstack server add volume "$vm" "$vol" || echo "Volume $vol je već attachan na $vm, preskačem."
  else
    echo "$vm već ima attachan disk $vol, preskačem."
  fi
done

echo "== 5. Dodavanje FIKSNIH floating IP-a (192.168.10.101-104) na MinIO, instruktora i jump hostove =="

declare -A floating_ips
floating_ips=(
  [demo-vm-minio]=192.168.10.101
  [demo-vm-test1.instr]=192.168.10.102
  [demo-vm-test2.stud-jumphost]=192.168.10.103
  [demo-vm-test3.stud-jumphost]=192.168.10.104
)

for vm in "${!floating_ips[@]}"; do
  FIP=${floating_ips[$vm]}
  # Provjeri je li floating IP već vezan za VM
  already=$(openstack server show "$vm" -f json | grep "$FIP" || true)
  if [ -z "$already" ]; then
    # Provjeri postoji li floating IP resource, ako ne - kreiraj ga
    if ! openstack floating ip show "$FIP" &>/dev/null; then
      openstack floating ip create --floating-ip-address "$FIP" public
    fi
    # Nađi privatni IP na glavnoj mreži
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

echo "== Gotovo! Sve mašine, diskovi, NIC-evi i fiksni floating IP-ovi su spremni. =="
