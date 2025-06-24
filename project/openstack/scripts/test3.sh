#!/bin/bash
set -e

ADMIN_RC="/etc/kolla/admin-openrc.sh"
CSV_FILE="osobe.csv"
KEYPAIR="labkey"
KEYPAIR_PUB="$HOME/.ssh/labkey.pub"
TAG="course=test"

PROJECTS=( instruktor-projekt student1-projekt student2-projekt )
declare -A PROJECT_USERS=( [instruktor-projekt]="mario.maric" [student1-projekt]="pero.peric" [student2-projekt]="iva.ivic" )
declare -A NETWORK_CIDRS=(
  [instruktor-projekt-instruktor-net]="10.20.0.0/24"
  [instruktor-projekt-instruktor-minio-net]="10.50.0.0/24"
  [student1-projekt-student1-net]="10.30.0.0/24"
  [student2-projekt-student2-net]="10.40.0.0/24"
)
SECURITY_GROUPS=( instruktor-projekt-secgroup student1-projekt-secgroup student2-projekt-secgroup )

# ---- VM DEFINICIJE: ime|projekt|mreža|ip|image|secgroup|minioip|extra1net|extra1ip|extra2net|extra2ip|extra3net|extra3ip
VM_LIST=(
  "minio-vm|instruktor-projekt|instruktor-projekt-instruktor-minio-net|10.50.0.11|minio-golden|instruktor-projekt-secgroup||||||"
  "instruktor|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.10|ubuntu-jammy|instruktor-projekt-secgroup|10.50.0.100|student1-projekt-student1-net|10.30.0.100|student2-projekt-student2-net|10.40.0.100|instruktor-projekt-instruktor-minio-net|10.50.0.100"
  "lb-instruktor|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.11|lb-golden|instruktor-projekt-secgroup||||||"
  "wp0-1|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.21|wp-golden|instruktor-projekt-secgroup|10.50.0.25|||||"
  "wp0-2|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.22|wp-golden|instruktor-projekt-secgroup|10.50.0.26|||||"
  "jumphost1|student1-projekt|student1-projekt-student1-net|10.30.0.10|ubuntu-jammy|student1-projekt-secgroup||||||"
  "lb-student1|student1-projekt|student1-projekt-student1-net|10.30.0.11|lb-golden|student1-projekt-secgroup||||||"
  "wp1-1|student1-projekt|student1-projekt-student1-net|10.30.0.21|wp-golden|student1-projekt-secgroup|10.50.0.21|||||"
  "wp1-2|student1-projekt|student1-projekt-student1-net|10.30.0.22|wp-golden|student1-projekt-secgroup|10.50.0.22|||||"
  "jumphost2|student2-projekt|student2-projekt-student2-net|10.40.0.10|ubuntu-jammy|student2-projekt-secgroup||||||"
  "lb-student2|student2-projekt|student2-projekt-student2-net|10.40.0.11|lb-golden-test3|student2-projekt-secgroup||||||"
  "wp2-1|student2-projekt|student2-projekt-student2-net|10.40.0.21|wp-golden|student2-projekt-secgroup|10.50.0.23|||||"
  "wp2-2|student2-projekt|student2-projekt-student2-net|10.40.0.22|wp-golden|student2-projekt-secgroup|10.50.0.24|||||"
)
 
echo
echo "== [1/10] Učitavam korisnike iz $CSV_FILE =="
USERS=()
INSTRUKTOR=""
while IFS=';' read -r ime prezime rola; do
    [[ "$ime" == "ime" ]] && continue
    user="${ime}.${prezime}"
    USERS+=("$user|$rola")
    [[ "$rola" == "instruktor" ]] && INSTRUKTOR="$user"
done < "$CSV_FILE"

echo
echo "== [2/10] Kreiram projekte =="
source "$ADMIN_RC"
for PRJ in "${PROJECTS[@]}"; do
    openstack project show "$PRJ" &>/dev/null || openstack project create "$PRJ"
done

echo
echo "== [3/10] Kreiram korisnike i role =="
for entry in "${USERS[@]}"; do
    IFS='|' read -r user rola <<< "$entry"
    PRJ=""
    if [[ "$rola" == "instruktor" ]]; then
        PRJ="instruktor-projekt"
    elif [[ "$rola" == "student" && "$user" == "pero.peric" ]]; then
        PRJ="student1-projekt"
    elif [[ "$rola" == "student" && "$user" == "iva.ivic" ]]; then
        PRJ="student2-projekt"
    fi
    openstack user show "$user" &>/dev/null || openstack user create --project "$PRJ" --password "TestPSW80!" "$user"
    if [[ "$rola" == "instruktor" ]]; then
        openstack role add --user "$user" --project "instruktor-projekt" admin
        for stud_prj in student1-projekt student2-projekt; do
            openstack role add --user "$user" --project "$stud_prj" admin
        done
    elif [[ "$rola" == "student" ]]; then
        openstack role add --user "$user" --project "$PRJ" member
    fi
done
for PRJ in "${PROJECTS[@]}"; do
    openstack role add --user admin --project "$PRJ" admin
done

echo
echo "== [4/10] Kreiram mreže, subnetove i routere =="
for NETNAME in "${!NETWORK_CIDRS[@]}"; do
    PRJ=""
    case "$NETNAME" in
        instruktor-projekt-*) PRJ="instruktor-projekt" ;;
        student1-projekt-*) PRJ="student1-projekt" ;;
        student2-projekt-*) PRJ="student2-projekt" ;;
    esac
    SUBNET="${NETNAME}-subnet"
    ROUTER="${NETNAME}-router"
    CIDR="${NETWORK_CIDRS[$NETNAME]}"
    openstack network show "$NETNAME" &>/dev/null || openstack network create --project "$PRJ" --tag "$TAG" "$NETNAME"
    openstack subnet show "$SUBNET" &>/dev/null || openstack subnet create --project "$PRJ" --network "$NETNAME" --subnet-range "$CIDR" --tag "$TAG" "$SUBNET"
    openstack router show "$ROUTER" &>/dev/null || { openstack router create --project "$PRJ" "$ROUTER"; openstack router set --external-gateway public "$ROUTER"; }
    SUBNET_ID=$(openstack subnet show "$SUBNET" -f value -c id)
    ROUTER_ID=$(openstack router show "$ROUTER" -f value -c id)
    ROUTER_PORT=$(openstack port list --device-owner network:router_interface --device-id $ROUTER_ID --fixed-ip subnet=$SUBNET_ID -f value -c id)
    [[ -z "$ROUTER_PORT" ]] && openstack router add subnet "$ROUTER" "$SUBNET"
done

echo
echo "== [5/10] Kreiram security grupe =="
declare -A SECGRP_IDS

for PRJ in "${PROJECTS[@]}"; do
    SGNAME="${PRJ}-secgroup"
    SGID=""
    # Pronađi sve SG s tim imenom u projektu
    SGIDS=( $(openstack security group list --project "$PRJ" -f value -c ID -c Name | awk -v n="$SGNAME" '$2 == n {print $1}') )
    if [[ ${#SGIDS[@]} -eq 0 ]]; then
        echo "--> Kreiram security grupu: $SGNAME ($PRJ)"
        SGID=$(openstack security group create --project "$PRJ" "$SGNAME" --description "Default grupa za $PRJ" -f value -c id)
        # Dodaj pravila
        openstack security group rule create --project "$PRJ" --proto icmp "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 22 "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 80 "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 443 "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 9000 "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 2049 "$SGID"
        openstack security group rule create --project "$PRJ" --proto udp --dst-port 2049 "$SGID"
    elif [[ ${#SGIDS[@]} -eq 1 ]]; then
        SGID="${SGIDS[0]}"
        echo "--> Security grupa već postoji: $SGNAME ($SGID)"
    else
        echo "!! Više security grupa s imenom $SGNAME postoji u projektu $PRJ !!"
        # Ostavljaš prvu, brišeš ostale:
        for i in "${SGIDS[@]:1}"; do
            echo "----> Brišem dupli security group $i"
            openstack security group delete "$i"
        done
        SGID="${SGIDS[0]}"
        echo "----> Security grupa $SGNAME ostavljena (ID: $SGID)"
    fi
    SECGRP_IDS["$PRJ"]="$SGID"
done

echo
echo "== [6/10] Kreiram RC file za svakog korisnika =="
for entry in "${USERS[@]}"; do
    IFS='|' read -r user rola <<< "$entry"
    PRJ=""
    [[ "$rola" == "instruktor" ]] && PRJ="instruktor-projekt"
    [[ "$rola" == "student" && "$user" == "pero.peric" ]] && PRJ="student1-projekt"
    [[ "$rola" == "student" && "$user" == "iva.ivic" ]] && PRJ="student2-projekt"
    RC_FILE="/etc/kolla/${user}-openrc.sh"
    cat > "$RC_FILE" <<EOF
export OS_AUTH_URL=$(openstack endpoint list --service identity --interface public -f value -c URL | head -n1)
export OS_PROJECT_NAME="$PRJ"
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USERNAME="$user"
export OS_USER_DOMAIN_NAME=Default
export OS_PASSWORD="TestPSW80!"
export OS_IDENTITY_API_VERSION=3
export OS_REGION_NAME=RegionOne
EOF
    chmod 600 "$RC_FILE"
done

echo
echo "== [7/10] Provjera i upload labkey keypair svakom korisniku =="
for entry in "${USERS[@]}"; do
    IFS='|' read -r user rola <<< "$entry"
    RC_FILE="/etc/kolla/${user}-openrc.sh"
    [[ -f "$RC_FILE" ]] && source "$RC_FILE"
    if ! openstack keypair show "$KEYPAIR" &>/dev/null; then
        openstack keypair create --public-key "$KEYPAIR_PUB" "$KEYPAIR"
    fi
done

echo
echo "== [8/10] Kreiram volumene za svaku VM (2x1TB) =="
for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ _ _ _ _ _ _ _ _ _ _ _ <<< "$vmline"
    RC_FILE="/etc/kolla/${PROJECT_USERS[$PRJ]}-openrc.sh"
    [[ -f "$RC_FILE" ]] && source "$RC_FILE"
    for i in 1 2; do
        VOLNAME="${VMNAME}-data-${i}"
        openstack volume show "$VOLNAME" &>/dev/null || openstack volume create --size 1 "$VOLNAME"
    done
done

echo
echo "== [9/10] Kreiram VM-ove (multi-NIC, SVE po ID-u) =="

for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ NETNAME IPADDR IMAGE SGROUP MINIO_IP EXTRA1_NET EXTRA1_IP EXTRA2_NET EXTRA2_IP EXTRA3_NET EXTRA3_IP <<< "$vmline"

    # Dohvati ID primarne mreže
    NET_ID=""
    if [[ -n "$NETNAME" ]]; then
        NET_ID=$(openstack network list --project "$PRJ" -f value -c ID -c Name | awk -v N="$NETNAME" '$2 == N {print $1}')
        if [[ -z "$NET_ID" ]]; then
            echo "!! Ne postoji mreža $NETNAME za $PRJ"
            continue
        fi
    fi

    # Dohvati ID security grupe
    SG_ID=""
    if [[ -n "$SGROUP" ]]; then
        SG_ID=$(openstack security group list --project "$PRJ" -f value -c ID -c Name | awk -v N="$SGROUP" '$2 == N {print $1}')
        if [[ -z "$SG_ID" ]]; then
            echo "!! Ne postoji secgroup $SGROUP za $PRJ"
            continue
        fi
    fi

    NICS="--nic net-id=${NET_ID},v4-fixed-ip=${IPADDR}"

    # Minio net dodaj kao dodatni NIC ako postoji
    if [[ -n "$MINIO_IP" && "$MINIO_IP" != " " ]]; then
        MINIO_NET_ID=$(openstack network list --project "instruktor-projekt" -f value -c ID -c Name | awk '$2 == "instruktor-projekt-instruktor-minio-net" {print $1}')
        if [[ -n "$MINIO_NET_ID" ]]; then
            NICS+=" --nic net-id=${MINIO_NET_ID},v4-fixed-ip=${MINIO_IP}"
        fi
    fi
    # EXTRA1
    if [[ -n "$EXTRA1_NET" && -n "$EXTRA1_IP" ]]; then
        EXTRA1_NET_ID=$(openstack network list --project "$PRJ" -f value -c ID -c Name | awk -v N="$EXTRA1_NET" '$2 == N {print $1}')
        if [[ -n "$EXTRA1_NET_ID" ]]; then
            NICS+=" --nic net-id=${EXTRA1_NET_ID},v4-fixed-ip=${EXTRA1_IP}"
        fi
    fi
    # EXTRA2
    if [[ -n "$EXTRA2_NET" && -n "$EXTRA2_IP" ]]; then
        EXTRA2_NET_ID=$(openstack network list --project "$PRJ" -f value -c ID -c Name | awk -v N="$EXTRA2_NET" '$2 == N {print $1}')
        if [[ -n "$EXTRA2_NET_ID" ]]; then
            NICS+=" --nic net-id=${EXTRA2_NET_ID},v4-fixed-ip=${EXTRA2_IP}"
        fi
    fi
    # EXTRA3
    if [[ -n "$EXTRA3_NET" && -n "$EXTRA3_IP" ]]; then
        EXTRA3_NET_ID=$(openstack network list --project "$PRJ" -f value -c ID -c Name | awk -v N="$EXTRA3_NET" '$2 == N {print $1}')
        if [[ -n "$EXTRA3_NET_ID" ]]; then
            NICS+=" --nic net-id=${EXTRA3_NET_ID},v4-fixed-ip=${EXTRA3_IP}"
        fi
    fi

    RC_FILE="/etc/kolla/${PROJECT_USERS[$PRJ]}-openrc.sh"
    [[ -f "$RC_FILE" ]] && source "$RC_FILE"

    echo "--> Provjeravam VM: $VMNAME ($PRJ)"
    if ! openstack server show "$VMNAME" &>/dev/null; then
        echo "----> Kreiram VM: $VMNAME (image=$IMAGE, $NICS, secgroup=$SG_ID)"
        openstack server create \
            --flavor m1.medium \
            --image "$IMAGE" \
            $NICS \
            --key-name "$KEYPAIR" \
            --security-group "$SG_ID" \
            "$VMNAME"
    else
        echo "----> VM postoji: $VMNAME"
    fi
done

echo
echo "== [10/10] Čekam da svi VM-ovi budu ACTIVE i attacham volumene =="
for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ _ _ _ _ _ _ _ _ _ _ _ <<< "$vmline"
    RC_FILE="/etc/kolla/${PROJECT_USERS[$PRJ]}-openrc.sh"
    [[ -f "$RC_FILE" ]] && source "$RC_FILE"
    # Čekaj ACTIVE
    for t in {1..60}; do
        STATUS=$(openstack server show "$VMNAME" -f value -c status 2>/dev/null || echo "ERROR")
        if [[ "$STATUS" == "ACTIVE" ]]; then
            break
        elif [[ "$STATUS" == "ERROR" ]]; then
            echo "!!!! $VMNAME nije ACTIVE (status: ERROR), preskačem attach volumena!"
            continue 2
        else
            sleep 5
        fi
    done
    # Attach volumena
    for i in 1 2; do
        VOLNAME="${VMNAME}-data-${i}"
        VID=$(openstack volume show $VOLNAME -f value -c id)
        [[ -z "$VID" ]] && continue
        if ! openstack server volume list "$VMNAME" -f value -c "Volume ID" | grep -q "$VID"; then
            openstack server add volume "$VMNAME" "$VOLNAME"
        fi
    done
done

echo
echo "==== INFRASTRUKTURA I VM-OVI SU SPREMNI! ===="

