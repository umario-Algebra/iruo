#!/bin/bash
set -e

EXT_NET="public"
TAG="course=test"
CSV_FILE="osobe.csv"
DEFAULT_PASSWORD="TestPSW80!"
KEYPAIR="labkey"
KEYPAIR_PUB="${HOME}/.ssh/labkey.pub"
RC_DIR="/etc/kolla"
FLAVOR="m1.medium"
VOLUME_SIZE=1024 # 1TB
ADMIN_USER="admin"
ADMIN_RC="/etc/kolla/admin-openrc.sh"

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

NETWORKS=(
  instruktor-projekt-instruktor-net
  instruktor-projekt-instruktor-minio-net
  student1-projekt-student1-net
  student2-projekt-student2-net
)
declare -A NETWORK_CIDRS=(
  [instruktor-projekt-instruktor-net]="10.20.0.0/24"
  [instruktor-projekt-instruktor-minio-net]="10.50.0.0/24"
  [student1-projekt-student1-net]="10.30.0.0/24"
  [student2-projekt-student2-net]="10.40.0.0/24"
)

SECURITY_GROUPS=(
  instruktor-projekt-secgroup
  student1-projekt-secgroup
  student2-projekt-secgroup
)

# 1. Parsiraj korisnike, role i projekte iz CSV-a
declare -A USERS ROLES PROJECTS
echo "== [1/10] Učitavam korisnike iz $CSV_FILE =="
while IFS=';' read -r ime prezime rola; do
    [[ -z "$ime" || -z "$prezime" || -z "$rola" ]] && continue
    USERNAME="${ime}.${prezime}"
    PROJECT="${ime}-${prezime}-projekt"
    USERS["$USERNAME"]="$PROJECT"
    PROJECTS["$PROJECT"]=1
    ROLES["$USERNAME"]="$rola"
done < <(tail -n +2 "$CSV_FILE")
echo "--> Pronađeno korisnika: ${#USERS[@]}"

# 2. Kreiraj projekte
echo "== [2/10] Kreiram projekte =="
for PROJECT in "${!PROJECTS[@]}"; do
    if ! openstack project show "$PROJECT" &>/dev/null; then
        openstack project create "$PROJECT"
        echo "----> Kreiran projekt: $PROJECT"
    else
        echo "----> Projekt već postoji: $PROJECT"
    fi
done

# 3. Kreiraj korisnike i role
echo "== [3/10] Kreiram korisnike i dodjeljujem role =="
INSTRUKTOR=""
for USERNAME in "${!USERS[@]}"; do
    PROJECT="${USERS[$USERNAME]}"
    ROLA="${ROLES[$USERNAME]}"
    if ! openstack user show "$USERNAME" &>/dev/null; then
        openstack user create --project "$PROJECT" --password "$DEFAULT_PASSWORD" "$USERNAME"
        echo "----> Kreiran korisnik: $USERNAME ($ROLA)"
    fi
    openstack role add --user "$USERNAME" --project "$PROJECT" admin
    echo "----> $USERNAME je admin na projektu $PROJECT"
    if [[ "$ROLA" == "instruktor" ]]; then
        INSTRUKTOR="$USERNAME"
    fi
done

# Admin user je admin na svim projektima
echo "== [4/10] Dodajem admin user kao admina na sve projekte =="
for PROJECT in "${!PROJECTS[@]}"; do
    openstack role add --user "$ADMIN_USER" --project "$PROJECT" admin
    echo "----> admin je sada admin na $PROJECT"
done
# Instruktor je admin na svim projektima
if [[ -n "$INSTRUKTOR" ]]; then
    for PROJECT in "${!PROJECTS[@]}"; do
        openstack role add --user "$INSTRUKTOR" --project "$PROJECT" admin
        echo "----> Instruktor $INSTRUKTOR je admin na projektu $PROJECT"
    done
fi

# 5. Kreiraj mreže/subnete/routere
echo "== [5/10] Kreiram mreže/subnete/routere =="
for NETNAME in "${NETWORKS[@]}"; do
    PROJECT="${NETNAME%%-*}-projekt"
    CIDR="${NETWORK_CIDRS[$NETNAME]}"
    SUBNETNAME="${NETNAME}-subnet"
    ROUTERNAME="${NETNAME}-router"
    if ! openstack network show "$NETNAME" &>/dev/null; then
        openstack network create --project "$PROJECT" --tag "$TAG" "$NETNAME"
        echo "----> Kreirana mreža: $NETNAME ($PROJECT)"
    fi
    if ! openstack subnet show "$SUBNETNAME" &>/dev/null; then
        openstack subnet create --network "$NETNAME" --project "$PROJECT" --subnet-range "$CIDR" --tag "$TAG" "$SUBNETNAME"
        echo "----> Kreiran subnet: $SUBNETNAME ($CIDR)"
    fi
    if ! openstack router show "$ROUTERNAME" &>/dev/null; then
        openstack router create --project "$PROJECT" "$ROUTERNAME"
        openstack router set --external-gateway "$EXT_NET" "$ROUTERNAME"
        echo "----> Kreiran router: $ROUTERNAME"
    fi
    # Attach subnet to router (if not already attached)
    SUBNET_ID=$(openstack subnet show "$SUBNETNAME" -f value -c id)
    ROUTER_ID=$(openstack router show "$ROUTERNAME" -f value -c id)
    ROUTER_PORT=$(openstack port list --device-owner network:router_interface --device-id $ROUTER_ID --fixed-ip subnet=$SUBNET_ID -f value -c id)
    if [[ -z "$ROUTER_PORT" ]]; then
        openstack router add subnet "$ROUTERNAME" "$SUBNETNAME"
        echo "----> Subnet $SUBNETNAME spojen na router $ROUTERNAME"
    fi
done

# 6. Kreiraj security grupe
echo "== [6/10] Kreiram security grupe =="
for SG in "${SECURITY_GROUPS[@]}"; do
    PROJECT="${SG%%-*}-projekt"
    SGIDS=( $(openstack security group list --project "$PROJECT" -f value -c ID -c Name | awk -v name="$SG" '$2 == name {print $1}') )
    SGCOUNT=${#SGIDS[@]}
    if [ "$SGCOUNT" -eq 0 ]; then
        openstack security group create --project "$PROJECT" "$SG" --description "Default grupa za $PROJECT"
        openstack security group rule create --project "$PROJECT" --proto icmp "$SG"
        openstack security group rule create --project "$PROJECT" --proto tcp --dst-port 22 "$SG"
        openstack security group rule create --project "$PROJECT" --proto tcp --dst-port 80 "$SG"
        openstack security group rule create --project "$PROJECT" --proto tcp --dst-port 443 "$SG"
        openstack security group rule create --project "$PROJECT" --proto tcp --dst-port 9000 "$SG"
        openstack security group rule create --project "$PROJECT" --proto tcp --dst-port 2049 "$SG"
        openstack security group rule create --project "$PROJECT" --proto udp --dst-port 2049 "$SG"
        echo "----> Kreirana security grupa: $SG"
    elif [ "$SGCOUNT" -eq 1 ]; then
        echo "----> Security grupa već postoji: $SG"
    else
        echo "!! Više security grupa s imenom $SG postoji u projektu $PROJECT !!"
        for i in "${SGIDS[@]:1}"; do
            openstack security group delete "$i"
        done
        echo "----> Security grupa $SG ostavljena (ID: ${SGIDS[0]})"
    fi
done

# 7. Uploadaj labkey u svaki projekt (ako ne postoji)
echo "== [7/10] Provjera i upload labkey keypair u svaki projekt =="
if [ ! -f "$KEYPAIR_PUB" ]; then
    echo "ERROR: Nema $KEYPAIR_PUB – generiraj labkey prije deploya!"
    exit 1
fi
source "$ADMIN_RC"
for PROJECT in "${!PROJECTS[@]}"; do
    if openstack keypair list --project "$PROJECT" -f value -c Name | grep -Fxq "$KEYPAIR"; then
        echo "----> labkey već postoji u projektu $PROJECT"
    else
        echo "----> Uploadam labkey u projekt $PROJECT"
        openstack keypair create --project "$PROJECT" --public-key "$KEYPAIR_PUB" "$KEYPAIR"
    fi
done

# 8. Kreiraj portove i volumene za svaki VM
echo "== [8/10] Kreiranje portova i volumena (kao ADMIN) =="
declare -A PRIMARY_PORT_IDS MINIO_PORT_IDS EXTRA_PORT_IDS
for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ NETNAME IPADDR IMAGE SGROUP MINIO_IP EXTRA1_NET EXTRA1_IP EXTRA2_NET EXTRA2_IP EXTRA3_NET EXTRA3_IP <<< "$vmline"
    # Kreiraj port
    PORTNAME="${VMNAME}-primarni-port"
    if ! openstack port show "$PORTNAME" &>/dev/null; then
        echo "----> Kreiram port: $PORTNAME ($IPADDR/$NETNAME)"
        PRIMARY_PORT_IDS["$VMNAME"]=$(openstack port create --network "$NETNAME" --fixed-ip subnet="${NETNAME}-subnet,ip-address=$IPADDR" "$PORTNAME" -f value -c id)
    else
        echo "----> Port već postoji: $PORTNAME"
        PRIMARY_PORT_IDS["$VMNAME"]=$(openstack port show "$PORTNAME" -f value -c id)
    fi
    # Minio port ako treba
    if [[ -n "$MINIO_IP" && "$MINIO_IP" != " " ]]; then
        MINIO_PORTNAME="${VMNAME}-minio-port"
        if ! openstack port show "$MINIO_PORTNAME" &>/dev/null; then
            echo "----> Kreiram minio port: $MINIO_PORTNAME ($MINIO_IP/instruktor-projekt-instruktor-minio-net)"
            MINIO_PORT_IDS["$VMNAME"]=$(openstack port create --network instruktor-projekt-instruktor-minio-net --fixed-ip subnet=instruktor-projekt-instruktor-minio-net-subnet,ip-address=$MINIO_IP "$MINIO_PORTNAME" -f value -c id)
        else
            MINIO_PORT_IDS["$VMNAME"]=$(openstack port show "$MINIO_PORTNAME" -f value -c id)
        fi
    fi
    # Extra portovi (multi-NIC instruktora)
    for i in 1 2 3; do
        eval "NET=\$EXTRA${i}_NET"
        eval "IP=\$EXTRA${i}_IP"
        if [[ -n "$NET" && -n "$IP" ]]; then
            PNAME="${VMNAME}-extra-${i}-port"
            if ! openstack port show "$PNAME" &>/dev/null; then
                echo "----> Kreiram extra port: $PNAME ($IP/$NET)"
                EXTRA_PORT_IDS["$VMNAME-$i"]=$(openstack port create --network "$NET" --fixed-ip subnet="${NET}-subnet,ip-address=$IP" "$PNAME" -f value -c id)
            else
                EXTRA_PORT_IDS["$VMNAME-$i"]=$(openstack port show "$PNAME" -f value -c id)
            fi
        fi
    done
    # Kreiraj 2 volumena po VM-u
    for i in 1 2; do
        VOLNAME="${VMNAME}-data-${i}"
        if ! openstack volume show "$VOLNAME" &>/dev/null; then
            echo "----> Kreiram volume: $VOLNAME (${VOLUME_SIZE}GB) u projektu $PRJ"
            openstack volume create --size $VOLUME_SIZE --project "$PRJ" "$VOLNAME"
        else
            echo "----> Volume već postoji: $VOLNAME"
        fi
    done
done

# 9. Kreiraj VM-ove s pripadajućim portovima i diskovima
echo "== [9/10] VM-OVI + ATTACH VOLUMENA =="
for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ NETNAME IPADDR IMAGE SGROUP MINIO_IP EXTRA1_NET EXTRA1_IP EXTRA2_NET EXTRA2_IP EXTRA3_NET EXTRA3_IP <<< "$vmline"
    PRIMARY_PORT="${PRIMARY_PORT_IDS[$VMNAME]}"
    EXTRANICS=""
    if [[ -n "$MINIO_IP" && "$MINIO_IP" != " " ]]; then
        MINIO_PORT="${MINIO_PORT_IDS[$VMNAME]}"
        EXTRANICS+=" --nic port-id=${MINIO_PORT}"
    fi
    for i in 1 2 3; do
        eval "NET=\$EXTRA${i}_NET"
        eval "IP=\$EXTRA${i}_IP"
        if [[ -n "$NET" && -n "$IP" ]]; then
            EXTRANICS+=" --nic port-id=${EXTRA_PORT_IDS["$VMNAME-$i"]}"
        fi
    done

    echo "--> Provjeravam VM: $VMNAME u projektu $PRJ"
    source "$ADMIN_RC"
    openstack --os-project-name "$PRJ" server show "$VMNAME" &>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "----> Kreiram VM: $VMNAME (image=$IMAGE, IP=$IPADDR, secgroup=$SGROUP)"
        openstack --os-project-name "$PRJ" server create \
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

# 10. Attach diskova tek kad je VM ACTIVE
echo "== [10/10] Attach volumena na VM-ove (čekanje na ACTIVE) =="
for vmline in "${VM_LIST[@]}"; do
    IFS='|' read -r VMNAME PRJ NETNAME IPADDR IMAGE SGROUP MINIO_IP EXTRA1_NET EXTRA1_IP EXTRA2_NET EXTRA2_IP EXTRA3_NET EXTRA3_IP <<< "$vmline"
    source "$ADMIN_RC"
    VMSTATUS=$(openstack --os-project-name "$PRJ" server show "$VMNAME" -f value -c status)
    echo -n "----> Čekam da VM $VMNAME postane ACTIVE..."
    for i in {1..60}; do
        VMSTATUS=$(openstack --os-project-name "$PRJ" server show "$VMNAME" -f value -c status)
        if [[ "$VMSTATUS" == "ACTIVE" ]]; then
            echo " $VMNAME je ACTIVE!"
            break
        elif [[ "$VMSTATUS" == "ERROR" ]]; then
            echo " $VMNAME je ERROR, preskačem attach volumena!"
            continue 2
        else
            sleep 5
            echo -n "."
        fi
    done
    # Attach volumena
    for i in 1 2; do
        VOLNAME="${VMNAME}-data-${i}"
        ATTACHED=$(openstack --os-project-name "$PRJ" server volume list "$VMNAME" -f value -c "Volume ID" | grep "$VOLNAME" || true)
        if [[ -z "$ATTACHED" ]]; then
            echo "----> Attacham $VOLNAME na $VMNAME"
            openstack --os-project-name "$PRJ" server add volume "$VMNAME" "$VOLNAME"
        else
            echo "----> Volume $VOLNAME je već attachan na $VMNAME"
        fi
    done
done

echo "== GOTOVO: Svi resursi su kreirani! =="

