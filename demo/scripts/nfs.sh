#!/bin/bash
set -e

RC_FILE="/etc/kolla/demo-openrc.sh"
if [[ -f "$RC_FILE" ]]; then
    source "$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

NFS_VM="demo-vm-nfs"
NFS_NET="demo-net-minio"
NFS_IP="10.50.0.21"
KEYPAIR="demo-key"
IMAGE="ubuntu-jammy"
FLAVOR="m1.medium"
DEFAULT_SG="13f8719f-d69a-4ff6-9afd-a39a70d01ca1"

# 1. Deploy NFS server VM ako već ne postoji
if ! openstack server show "$NFS_VM" &>/dev/null; then
    netid=$(openstack network show "$NFS_NET" -f value -c id)
    echo "Kreiram NFS server: $NFS_VM na mreži $NFS_NET ($NFS_IP)"
    openstack server create \
        --flavor "$FLAVOR" \
        --image "$IMAGE" \
        --nic net-id=$netid,v4-fixed-ip=$NFS_IP \
        --key-name "$KEYPAIR" \
        --security-group "$DEFAULT_SG" \
        "$NFS_VM"
else
    echo "VM $NFS_VM već postoji, preskačem."
fi

# 2. Pričekaj da VM bude ACTIVE
while true; do
    status=$(openstack server show "$NFS_VM" -f value -c status)
    [[ "$status" == "ACTIVE" ]] && break
    echo "Čekam na $NFS_VM (status: $status)..."
    sleep 5
done

# 3. Instalacija i konfiguracija NFS servera na VM-u
echo "--- Instaliram i podešavam NFS na $NFS_VM ($NFS_IP) ---"
ssh -o StrictHostKeyChecking=no -i ~/.ssh/demo-key ubuntu@$NFS_IP bash <<EOF
sudo apt-get update
sudo apt-get install -y nfs-kernel-server
sudo mkdir -p /srv/share
sudo chown nobody:nogroup /srv/share
echo "/srv/share 10.0.0.0/8(rw,sync,no_subtree_check,no_root_squash)" | sudo tee /etc/exports
sudo systemctl restart nfs-kernel-server
EOF

# 4. Mountanje NFS-a na svim WP VM-ovima
WP_VMS=(demo-vm-test2.stud-wp1 demo-vm-test2.stud-wp2 demo-vm-test3.stud-wp1 demo-vm-test3.stud-wp2)
for vm in "${WP_VMS[@]}"; do
    priv_ip=$(openstack server show "$vm" -f json | jq -r ".addresses[] | select(test(\"10\\.30|10\\.40\"))" | grep -oP '10\.\d+\.\d+\.\d+')
    [[ -z "$priv_ip" ]] && continue
    echo "--- Mountam NFS share na $vm ($priv_ip) ---"
    ssh -o StrictHostKeyChecking=no -i ~/.ssh/demo-key ubuntu@$priv_ip bash <<EOS
sudo apt-get update
sudo apt-get install -y nfs-common
sudo mkdir -p /mnt/share
echo "$NFS_IP:/srv/share /mnt/share nfs defaults 0 0" | sudo tee -a /etc/fstab
sudo mount -a
EOS
done

echo
echo "== NFS server i mount na WP VM-ovima postavljen! =="
echo "NFS server: $NFS_VM ($NFS_IP:/srv/share)"
echo "WP VM-ovi sada imaju /mnt/share (shared storage)."
