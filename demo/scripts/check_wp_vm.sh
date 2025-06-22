#!/bin/bash

# FIP ili vanjska IP jumphosta
JUMP_HOST="ubuntu@192.168.10.103"
KEY="/home/kolla/demo1.pem"

# Lista WP VM-ova i njihovih internih IP-eva
declare -A VM_IPS=(
    [wp2-1]="10.30.0.21"
    [wp2-2]="10.30.0.22"
    [wp3-1]="10.40.0.21"
    [wp3-2]="10.40.0.22"
)
SSH_USER="ubuntu"

for vm in "${!VM_IPS[@]}"; do
    echo "===== Provjera $vm (${VM_IPS[$vm]}) ====="
    # Kroz jumphost koristi -J opciju
    SSH="ssh -o StrictHostKeyChecking=no -i $KEY -J $JUMP_HOST $SSH_USER@${VM_IPS[$vm]}"
    # 1. Diskovi
    echo "--- Diskovi:"
    $SSH "lsblk | grep -E 'vdb|vdc|sdb|sdc'" || echo "NEDOSTAJE DISK!"
    # 2. NFS test
    echo "--- NFS provjera:"
    $SSH "ls /mnt/nfs && echo OK || echo NFS FAIL"
    $SSH "echo 'test-nfs-$vm' | sudo tee /mnt/nfs/test_$vm.txt >/dev/null && cat /mnt/nfs/test_$vm.txt" || echo "NFS upis FAIL"
    # 3. MinIO test
    echo "--- MinIO provjera:"
    $SSH "ls /mnt/minio && echo OK || echo MINIO FAIL"
    $SSH "echo 'test-minio-$vm' | sudo tee /mnt/minio/test_$vm.txt >/dev/null && cat /mnt/minio/test_$vm.txt" || echo "MINIO upis FAIL"
    echo
done
