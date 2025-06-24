#!/bin/bash
set -e

EXT_NET="public"
KEYPAIR="labkey"
FLAVOR="m1.medium"
DISK_SIZE=1024 # 1TB po disku

RC_ADMIN="/etc/kolla/admin-openrc.sh"
RC_INSTRUKTOR="/etc/kolla/instruktor-projekt-openrc.sh"
RC_STUDENT1="/etc/kolla/student1-projekt-openrc.sh"
RC_STUDENT2="/etc/kolla/student2-projekt-openrc.sh"

# VM Definicije: name|project|primary_network|primary_ip|image|secgroup|[minio_ip]|[extra_net]|[extra_ip]...
VM_LIST=(
"minio-vm|instruktor-projekt|instruktor-projekt-instruktor-minio-net|10.50.0.11|minio-golden|instruktor-projekt-secgroup"
"instruktor|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.10|ubuntu-jammy|instruktor-projekt-secgroup| |student1-projekt-student1-net|10.30.0.100|student2-projekt-student2-net|10.40.0.100|instruktor-projekt-instruktor-minio-net|10.50.0.100"
"lb-instruktor|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.11|lb-golden|instruktor-projekt-secgroup"
"wp0-1|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.21|wp-golden|instruktor-projekt-secgroup|10.50.0.25"
"wp0-2|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.22|wp-golden|instruktor-projekt-secgroup|10.50.0.26"
"jumphost1|student1-projekt|student1-projekt-student1-net|10.30.0.10|ubuntu-jammy|student1-projekt-secgroup"
"lb-student1|student1-projekt|student1-projekt-student1-net|10.30.0.11|lb-golden|student1-projekt-secgroup"
"wp1-1|student1-projekt|student1-projekt-student1-net|10.30.0.21|wp-golden|student1-projekt-secgroup|10.50.0.21"
"wp1-2|student1-projekt|student1-projekt-student1-net|10.30.0.22|wp-golden|student1-projekt-secgroup|10.50.0.22"
"jumphost2|student2-projekt|student2-projekt-student2-net|10.40.0.10|ubuntu-jammy|student2-projekt-secgroup"
"lb-student2|student2-projekt|student2-projekt-student2-net|10.40.0.11|lb-golden-test3|student2-projekt-secgroup"
"wp2-1|student2-projekt|student2-projekt-student2-net|10.40.0.21|wp-golden|student2-projekt-secgroup|10.50.0.23"
"wp2-2|student2-projekt|student2-projekt-student2-net|10.40.0.22|wp-golden|student2-projekt-secgroup|10.50.0.24"
)

declare -A PRIMARY_PORT_IDS
declare -A MINIO_PORT_IDS
declare -A EXTRA_PORT_IDS

# -- Funkcija za RC switch po projektu --
switch_rc() {
    case "$1" in
        instruktor-projekt) source "$RC_INSTRUKTOR" ;;
        student1-projekt) source "$RC_STUDENT1" ;;
        student2-projekt) source "$RC_STUDENT2" ;;
        *) source "$RC_ADMIN" ;;
    esac
}

echo
echo
echo "== [1/4] KREIRANJE PORTOVA I VOLUMENA (kao ADMIN) =="

source "$RC_ADMIN"

for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ _ <<< "$vmline"
    # ... (tvoja logika za portove)

    # DODAVANJE DISKOVA – ISPRAVNO!
    for i in 1 2; do
        VOLNAME="${VMNAME}-data-${i}"
        echo "----> Provjeravam volume: $VOLNAME (projekt: $PRJ)"
        if ! openstack volume show "$VOLNAME" &>/dev/null; then
            echo "----> Kreiram volume: $VOLNAME (1TB) u projektu $PRJ"
            openstack volume create --project "$PRJ" --size $DISK_SIZE "$VOLNAME"
        else
            echo "----> Volume već postoji: $VOLNAME"
        fi
    done
done

echo
echo "== [2/4] KREIRANJE VM-ova (multi-NIC, svaki pod svojim RC file-om) =="

for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ NETNAME IPADDR IMAGE SGROUP MINIO_IP EXTRA1_NET EXTRA1_IP EXTRA2_NET EXTRA2_IP EXTRA3_NET EXTRA3_IP <<< "$vmline"
    PRIMARY_PORT="${PRIMARY_PORT_IDS[$VMNAME]}"
    EXTRANICS=""
    if [[ -n "$MINIO_IP" && "$MINIO_IP" != " " ]]; then
        MINIO_PORT="${MINIO_PORT_IDS[$VMNAME]}"
        EXTRANICS+=" --nic port-id=${MINIO_PORT}"
    fi
    if [[ -n "$EXTRA1_NET" && -n "$EXTRA1_IP" ]]; then
        EXTRANICS+=" --nic port-id=${EXTRA_PORT_IDS["$VMNAME-1"]}"
    fi
    if [[ -n "$EXTRA2_NET" && -n "$EXTRA2_IP" ]]; then
        EXTRANICS+=" --nic port-id=${EXTRA_PORT_IDS["$VMNAME-2"]}"
    fi
    if [[ -n "$EXTRA3_NET" && -n "$EXTRA3_IP" ]]; then
        EXTRANICS+=" --nic port-id=${EXTRA_PORT_IDS["$VMNAME-3"]}"
    fi

    echo "--> Provjeravam VM: $VMNAME u projektu $PRJ"
    switch_rc "$PRJ"
    if ! openstack server show "$VMNAME" &>/dev/null; then
        echo "----> Kreiram VM: $VMNAME (image=$IMAGE, IP=$IPADDR, secgroup=$SGROUP)"
        openstack server create \
            --flavor "$FLAVOR" \
            --image "$IMAGE" \
            --nic port-id="$PRIMARY_PORT" \
            $EXTRANICS \
            --key-name "$KEYPAIR" \
            --security-group "$SGROUP" \
            "$VMNAME"
    else
        echo "----> VM već postoji: $VMNAME"
    fi
done

# Vrati se na admin nakon VM kreiranja
source "$RC_ADMIN"

echo
echo "== [3/4] ČEKANJE NA VM-ove =="
for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ _ <<< "$vmline"
    switch_rc "$PRJ"
    while true; do
        status=$(openstack server show "$VMNAME" -f value -c status)
        if [[ "$status" == "ACTIVE" ]]; then
            echo "$VMNAME je ACTIVE"
            break
        else
            echo "Čekam na $VMNAME (status: $status)..."
            sleep 5
        fi
    done
done

source "$RC_ADMIN"

echo
echo
echo "== [4/4] ATTACHANJE VOLUMENA NA VM =="
for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ _ <<< "$vmline"
    for i in 1 2; do
        VOLNAME="${VMNAME}-data-${i}"
        switch_rc "$PRJ"
        ATTACHED=$(openstack server volume list "$VMNAME" | grep "$VOLNAME" | grep "in-use" || true)
        if [[ -z "$ATTACHED" ]]; then
            echo "----> Attacham $VOLNAME na $VMNAME"
            openstack server add volume "$VMNAME" "$VOLNAME"
        else
            echo "----> Volume $VOLNAME je već attachan na $VMNAME"
        fi
    done
done
source "$RC_ADMIN"

source "$RC_ADMIN"
echo
echo "== VM deployment, portovi i diskovi završeni! =="
