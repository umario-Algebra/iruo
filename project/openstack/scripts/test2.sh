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

# -- VM DEFINICIJE: VM|PROJEKT|MREŽA|IP|IMAGE|SECGROUP|MINIO_IP|[dalje extra NIC/NET/IP]
VM_LIST=(
  "minio-vm|instruktor-projekt|instruktor-projekt-instruktor-minio-net|10.50.0.11|minio-golden|instruktor-projekt-secgroup|||"
  "instruktor|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.10|ubuntu-jammy|instruktor-projekt-secgroup|10.50.0.100|student1-projekt-student1-net|10.30.0.100|student2-projekt-student2-net|10.40.0.100|instruktor-projekt-instruktor-minio-net|10.50.0.100"
  "lb-instruktor|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.11|lb-golden|instruktor-projekt-secgroup|||"
  "wp0-1|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.21|wp-golden|instruktor-projekt-secgroup|10.50.0.25|||"
  "wp0-2|instruktor-projekt|instruktor-projekt-instruktor-net|10.20.0.22|wp-golden|instruktor-projekt-secgroup|10.50.0.26|||"
  "jumphost1|student1-projekt|student1-projekt-student1-net|10.30.0.10|ubuntu-jammy|student1-projekt-secgroup|||"
  "lb-student1|student1-projekt|student1-projekt-student1-net|10.30.0.11|lb-golden|student1-projekt-secgroup|||"
  "wp1-1|student1-projekt|student1-projekt-student1-net|10.30.0.21|wp-golden|student1-projekt-secgroup|10.50.0.21|||"
  "wp1-2|student1-projekt|student1-projekt-student1-net|10.30.0.22|wp-golden|student1-projekt-secgroup|10.50.0.22|||"
  "jumphost2|student2-projekt|student2-projekt-student2-net|10.40.0.10|ubuntu-jammy|student2-projekt-secgroup|||"
  "lb-student2|student2-projekt|student2-projekt-student2-net|10.40.0.11|lb-golden-test3|student2-projekt-secgroup|||"
  "wp2-1|student2-projekt|student2-projekt-student2-net|10.40.0.21|wp-golden|student2-projekt-secgroup|10.50.0.23|||"
  "wp2-2|student2-projekt|student2-projekt-student2-net|10.40.0.22|wp-golden|student2-projekt-secgroup|10.50.0.24|||"
)

echo
echo "== [1/11] Učitavam korisnike iz $CSV_FILE =="
USERS=()
INSTRUKTOR=""
while IFS=';' read -r ime prezime rola; do
    [[ "$ime" == "ime" ]] && continue
    user="${ime}.${prezime}"
    USERS+=("$user|$rola")
    [[ "$rola" == "instruktor" ]] && INSTRUKTOR="$user"
done < "$CSV_FILE"

echo
echo "== [2/11] Kreiram projekte po naming standardu =="
source "$ADMIN_RC"
for PRJ in "${PROJECTS[@]}"; do
    if ! openstack project show "$PRJ" &>/dev/null; then
        echo "--> Kreiram projekt: $PRJ"
        openstack project create "$PRJ"
    else
        echo "--> Projekt postoji: $PRJ"
    fi
done

echo
echo "== [3/11] Kreiram korisnike i role po naming standardu =="
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

    if ! openstack user show "$user" &>/dev/null; then
        echo "--> Kreiram usera: $user ($rola) u projektu $PRJ"
        openstack user create --project "$PRJ" --password "TestPSW80!" "$user"
    else
        echo "--> User već postoji: $user"
    fi

    # Role dodjela
    if [[ "$rola" == "instruktor" ]]; then
        openstack role add --user "$user" --project "instruktor-projekt" admin
        for stud_prj in student1-projekt student2-projekt; do
            openstack role add --user "$user" --project "$stud_prj" admin
        done
    elif [[ "$rola" == "student" ]]; then
        openstack role add --user "$user" --project "$PRJ" admin
    fi
done

# Admin user kao admin na svemu
echo
echo "== [3b/11] Dodajem admin usera kao admina na sve projekte =="
for PRJ in "${PROJECTS[@]}"; do
    openstack role add --user admin --project "$PRJ" admin
done

echo
echo "== [4/11] Kreiram mreže, subnetove i routere =="
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
    if ! openstack network show "$NETNAME" &>/dev/null; then
        echo "--> Kreiram mrežu: $NETNAME ($PRJ)"
        openstack network create --project "$PRJ" --tag "$TAG" "$NETNAME"
    fi
    if ! openstack subnet show "$SUBNET" &>/dev/null; then
        echo "   -> Kreiram subnet: $SUBNET ($CIDR)"
        openstack subnet create --project "$PRJ" --network "$NETNAME" --subnet-range "$CIDR" --tag "$TAG" "$SUBNET"
    fi
    if ! openstack router show "$ROUTER" &>/dev/null; then
        echo "   -> Kreiram router: $ROUTER"
        openstack router create --project "$PRJ" "$ROUTER"
        openstack router set --external-gateway public "$ROUTER"
    fi
    SUBNET_ID=$(openstack subnet show "$SUBNET" -f value -c id)
    ROUTER_ID=$(openstack router show "$ROUTER" -f value -c id)
    ROUTER_PORT=$(openstack port list --device-owner network:router_interface --device-id $ROUTER_ID --fixed-ip subnet=$SUBNET_ID -f value -c id)
    if [[ -z "$ROUTER_PORT" ]]; then
        echo "   -> Dodajem subnet $SUBNET na router $ROUTER"
        openstack router add subnet "$ROUTER" "$SUBNET"
    fi
done

echo
echo "== [5/11] Kreiram security grupe po naming standardu =="
for PRJ in "${PROJECTS[@]}"; do
    SGNAME="${PRJ}-secgroup"
    SGIDS=( $(openstack security group list --project "$PRJ" -f value -c ID -c Name | awk -v name="$SGNAME" '$2 == name {print $1}') )
    SGCOUNT=${#SGIDS[@]}
    if [ "$SGCOUNT" -eq 0 ]; then
        echo "--> Kreiram security grupu: $SGNAME ($PRJ)"
        SGID=$(openstack security group create --project "$PRJ" "$SGNAME" --description "Default grupa za $PRJ" -f value -c id)
        for retry in {1..10}; do
            sleep 1
            SGIDS=( $(openstack security group list --project "$PRJ" -f value -c ID -c Name | awk -v name="$SGNAME" '$2 == name {print $1}') )
            [ "${#SGIDS[@]}" -eq 1 ] && break
        done
        SGID="${SGIDS[0]}"
        openstack security group rule create --project "$PRJ" --proto icmp "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 22 "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 80 "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 443 "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 9000 "$SGID"
        openstack security group rule create --project "$PRJ" --proto tcp --dst-port 2049 "$SGID"
        openstack security group rule create --project "$PRJ" --proto udp --dst-port 2049 "$SGID"
    elif [ "$SGCOUNT" -eq 1 ]; then
        echo "--> Security grupa već postoji: $SGNAME"
    else
        for i in "${SGIDS[@]:1}"; do
            openstack security group delete "$i"
        done
        echo "--> Ostavljen jedan secgroup: $SGNAME"
    fi
done

echo
echo "== [6/11] Kreiram RC file za svakog korisnika =="
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
    echo "--> Generiran RC: $RC_FILE (user: $user, projekt: $PRJ)"
done

echo
echo "== [7/11] Provjera i upload labkey keypair svakom korisniku =="
for entry in "${USERS[@]}"; do
    IFS='|' read -r user rola <<< "$entry"
    RC_FILE="/etc/kolla/${user}-openrc.sh"
    if [[ -f "$RC_FILE" ]]; then
        source "$RC_FILE"
        if ! openstack keypair show "$KEYPAIR" &>/dev/null; then
            echo "--> Uploadam $KEYPAIR za usera $user"
            openstack keypair create --public-key "$KEYPAIR_PUB" "$KEYPAIR"
        else
            echo "--> Keypair $KEYPAIR već postoji za usera $user"
        fi
    else
        echo "!! Nema RC za $user"
    fi
done

echo
echo "== [9/11] Kreiram 2 volumena po VM-u (1TB svaki) =="
for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ NETNAME IPADDR IMAGE SGROUP MINIO_IP EXTRA1_NET EXTRA1_IP EXTRA2_NET EXTRA2_IP EXTRA3_NET EXTRA3_IP <<< "$vmline"
    RC_FILE="/etc/kolla/${PROJECT_USERS[$PRJ]}-openrc.sh"
    [[ -f "$RC_FILE" ]] && source "$RC_FILE"
    for i in 1 2; do
        VOLNAME="${VMNAME}-data-${i}"
        if ! openstack volume show "$VOLNAME" &>/dev/null; then
            openstack volume create --size 1 "$VOLNAME"
            echo "--> Kreiran volume: $VOLNAME (1TB)"
        fi
    done
done

echo
echo "== [10/11] Kreiram VM-ove (multi-NIC, keypair, security group) =="
echo
echo "== [VM DEPLOY - nova metoda] Kreiram VM-ove s multi-NIC, svi fiksni IP-ovi dodijeljeni pri bootoanju =="

for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ NETNAME IPADDR IMAGE SGROUP MINIO_IP EXTRA1_NET EXTRA1_IP EXTRA2_NET EXTRA2_IP EXTRA3_NET EXTRA3_IP <<< "$vmline"
    RC_FILE="/etc/kolla/${PROJECT_USERS[$PRJ]}-openrc.sh"
    [[ -f "$RC_FILE" ]] && source "$RC_FILE"

    NIC_ARGS=""

    # Glavni interfejs
    if [[ -n "$NETNAME" && -n "$IPADDR" ]]; then
        NETID=$(openstack network show "$NETNAME" -f value -c id)
        NIC_ARGS+=" --nic net-id=$NETID,v4-fixed-ip=$IPADDR"
    fi
    # Minio interface (WP-ovi i instruktor)
    if [[ -n "$MINIO_IP" && "$MINIO_IP" != " " ]]; then
        NETID=$(openstack network show instruktor-projekt-instruktor-minio-net -f value -c id)
        NIC_ARGS+=" --nic net-id=$NETID,v4-fixed-ip=$MINIO_IP"
    fi
    # Extra interfejsi (npr. instruktor ima 3)
    if [[ -n "$EXTRA1_NET" && -n "$EXTRA1_IP" ]]; then
        NETID=$(openstack network show "$EXTRA1_NET" -f value -c id)
        NIC_ARGS+=" --nic net-id=$NETID,v4-fixed-ip=$EXTRA1_IP"
    fi
    if [[ -n "$EXTRA2_NET" && -n "$EXTRA2_IP" ]]; then
        NETID=$(openstack network show "$EXTRA2_NET" -f value -c id)
        NIC_ARGS+=" --nic net-id=$NETID,v4-fixed-ip=$EXTRA2_IP"
    fi
    if [[ -n "$EXTRA3_NET" && -n "$EXTRA3_IP" ]]; then
        NETID=$(openstack network show "$EXTRA3_NET" -f value -c id)
        NIC_ARGS+=" --nic net-id=$NETID,v4-fixed-ip=$EXTRA3_IP"
    fi

    if ! openstack server show "$VMNAME" &>/dev/null; then
        echo "--> Kreiram VM: $VMNAME ($IMAGE, $NIC_ARGS)"
        openstack server create \
            --flavor m1.medium \
            --image "$IMAGE" \
            $NIC_ARGS \
            --key-name "$KEYPAIR" \
            --security-group "$SGROUP" \
            "$VMNAME"
    else
        echo "--> VM već postoji: $VMNAME"
    fi
done

echo
echo "== Čekam da svi VM-ovi budu ACTIVE =="

for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ _ _ _ _ _ _ _ _ _ _ _ <<< "$vmline"
    RC_FILE="/etc/kolla/${PROJECT_USERS[$PRJ]}-openrc.sh"
    [[ -f "$RC_FILE" ]] && source "$RC_FILE"
    for t in {1..60}; do
        STATUS=$(openstack server show "$VMNAME" -f value -c status 2>/dev/null || echo "ERROR")
        if [[ "$STATUS" == "ACTIVE" ]]; then
            echo "----> $VMNAME je ACTIVE"
            break
        elif [[ "$STATUS" == "ERROR" ]]; then
            echo "!!!! $VMNAME nije ACTIVE (status: ERROR), preskačem attach volumena!"
            continue 2
        else
            echo "    ...$VMNAME status: $STATUS, čekam 5s"
            sleep 5
        fi
    done
done

echo "==== SVE VM-ove podignute i svi mrežni adapteri su UP s fiksnim IP-evima ===="

echo
echo "== [11/11] Čekam da svi VM-ovi budu ACTIVE i attacham volumene =="
for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ _ _ _ _ _ _ _ _ _ _ _ <<< "$vmline"
    RC_FILE="/etc/kolla/${PROJECT_USERS[$PRJ]}-openrc.sh"
    [[ -f "$RC_FILE" ]] && source "$RC_FILE"

    # Čekaj ACTIVE
    for t in {1..60}; do
        STATUS=$(openstack server show "$VMNAME" -f value -c status 2>/dev/null || echo "ERROR")
        if [[ "$STATUS" == "ACTIVE" ]]; then
            echo "----> $VMNAME je ACTIVE"
            break
        elif [[ "$STATUS" == "ERROR" ]]; then
            echo "!!!! $VMNAME nije ACTIVE (status: ERROR), preskačem attach volumena!"
            continue 2
        else
            echo "    ...$VMNAME status: $STATUS, čekam 20s"
            sleep 20
        fi
    done
    # Attach volumena
    for i in 1 2; do
        VOLNAME="${VMNAME}-data-${i}"
        if ! openstack server volume list "$VMNAME" -f value -c "Volume ID" | grep -q "$(openstack volume show $VOLNAME -f value -c id)"; then
            openstack server add volume "$VMNAME" "$VOLNAME"
            echo "----> Attacham $VOLNAME na $VMNAME"
        else
            echo "----> Volume $VOLNAME je već attachan na $VMNAME"
        fi
    done
done

echo
echo "==== BAZNA INFRASTRUKTURA I VM-OVI + DISKOVI SU SPREMNI! ===="
