#!/bin/bash
set -e

RC_FILE="/etc/kolla/demo-openrc.sh"
if [[ -f "$RC_FILE" ]]; then
    source "$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

# ========== 1. LB za test2 ==========

LB_NAME="lb-test2"
LB_NET="demo-net-test2"
LB_SUBNET="demo-net-test2-subnet"
LB_VMS=(demo-vm-test2.stud-wp1 demo-vm-test2.stud-wp2)

echo "== Kreiram Load Balancer za test2 =="

if ! openstack loadbalancer show "$LB_NAME" &>/dev/null; then
  echo "Kreiram load balancer $LB_NAME..."
  openstack loadbalancer create --name "$LB_NAME" --vip-subnet-id "$LB_SUBNET"
else
  echo "Load balancer $LB_NAME već postoji, preskačem."
fi

while true; do
  STATUS=$(openstack loadbalancer show "$LB_NAME" -f value -c provisioning_status)
  [ "$STATUS" == "ACTIVE" ] && break
  echo "Čekam da load balancer $LB_NAME postane ACTIVE..."
  sleep 5
done

if ! openstack loadbalancer listener show "${LB_NAME}-listener" &>/dev/null; then
  echo "Kreiram listener..."
  openstack loadbalancer listener create --name "${LB_NAME}-listener" --protocol HTTP --protocol-port 80 --loadbalancer "$LB_NAME"
else
  echo "Listener već postoji, preskačem."
fi

if ! openstack loadbalancer pool show "${LB_NAME}-pool" &>/dev/null; then
  echo "Kreiram pool..."
  openstack loadbalancer pool create --name "${LB_NAME}-pool" --protocol HTTP --lb-algorithm ROUND_ROBIN --listener "${LB_NAME}-listener"
else
  echo "Pool već postoji, preskačem."
fi

if ! openstack loadbalancer healthmonitor show "${LB_NAME}-hm" &>/dev/null; then
  echo "Kreiram health monitor..."
  openstack loadbalancer healthmonitor create --name "${LB_NAME}-hm" --pool "${LB_NAME}-pool" --type HTTP --delay 5 --timeout 3 --max-retries 2 --url-path "/"
else
  echo "Health monitor već postoji, preskačem."
fi

for VM in "${LB_VMS[@]}"; do
  IP=$(openstack server show "$VM" -f json | jq -r '.addresses["'"$LB_NET"'"]' | grep -oP '10\.30\.\d+\.\d+')
  if ! openstack loadbalancer member list "${LB_NAME}-pool" -f value -c address | grep -q "$IP"; then
    echo "Dodajem $VM ($IP) kao član pool-a..."
    openstack loadbalancer member create --subnet "$LB_SUBNET" --address "$IP" --protocol-port 80 "${LB_NAME}-pool"
  else
    echo "$VM ($IP) je već član pool-a, preskačem."
  fi
done

echo "Load balancer $LB_NAME je spreman!"
echo "VIP adresa: $(openstack loadbalancer show $LB_NAME -f value -c vip_address)"

# ========== 2. LB za test3 ==========

LB_NAME="lb-test3"
LB_NET="demo-net-test3"
LB_SUBNET="demo-net-test3-subnet"
LB_VMS=(demo-vm-test3.stud-wp1 demo-vm-test3.stud-wp2)

echo "== Kreiram Load Balancer za test3 =="

if ! openstack loadbalancer show "$LB_NAME" &>/dev/null; then
  echo "Kreiram load balancer $LB_NAME..."
  openstack loadbalancer create --name "$LB_NAME" --vip-subnet-id "$LB_SUBNET"
else
  echo "Load balancer $LB_NAME već postoji, preskačem."
fi

while true; do
  STATUS=$(openstack loadbalancer show "$LB_NAME" -f value -c provisioning_status)
  [ "$STATUS" == "ACTIVE" ] && break
  echo "Čekam da load balancer $LB_NAME postane ACTIVE..."
  sleep 5
done

if ! openstack loadbalancer listener show "${LB_NAME}-listener" &>/dev/null; then
  echo "Kreiram listener..."
  openstack loadbalancer listener create --name "${LB_NAME}-listener" --protocol HTTP --protocol-port 80 --loadbalancer "$LB_NAME"
else
  echo "Listener već postoji, preskačem."
fi

if ! openstack loadbalancer pool show "${LB_NAME}-pool" &>/dev/null; then
  echo "Kreiram pool..."
  openstack loadbalancer pool create --name "${LB_NAME}-pool" --protocol HTTP --lb-algorithm ROUND_ROBIN --listener "${LB_NAME}-listener"
else
  echo "Pool već postoji, preskačem."
fi

if ! openstack loadbalancer healthmonitor show "${LB_NAME}-hm" &>/dev/null; then
  echo "Kreiram health monitor..."
  openstack loadbalancer healthmonitor create --name "${LB_NAME}-hm" --pool "${LB_NAME}-pool" --type HTTP --delay 5 --timeout 3 --max-retries 2 --url-path "/"
else
  echo "Health monitor već postoji, preskačem."
fi

for VM in "${LB_VMS[@]}"; do
  IP=$(openstack server show "$VM" -f json | jq -r '.addresses["'"$LB_NET"'"]' | grep -oP '10\.40\.\d+\.\d+')
  if ! openstack loadbalancer member list "${LB_NAME}-pool" -f value -c address | grep -q "$IP"; then
    echo "Dodajem $VM ($IP) kao član pool-a..."
    openstack loadbalancer member create --subnet "$LB_SUBNET" --address "$IP" --protocol-port 80 "${LB_NAME}-pool"
  else
    echo "$VM ($IP) je već član pool-a, preskačem."
  fi
done

echo "Load balancer $LB_NAME je spreman!"
echo "VIP adresa: $(openstack loadbalancer show $LB_NAME -f value -c vip_address)"
