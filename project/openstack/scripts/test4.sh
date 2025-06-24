#!/bin/bash
set -e

ADMIN_RC="/etc/kolla/admin-openrc.sh"
KEYSTONE_URL="http://172.16.20.207:5000/v3"
CSV_FILE="osobe.csv"
PASSWORD="TestPSW80!"
KEYPAIR="labkey"
KEYPAIR_PUB="$HOME/.ssh/labkey.pub"
TAG="course=test"
ROUTER="main-lab-router"
EXT_NET="public"   # promijeni ako ti je drukčije

echo
echo "== [1] Čitam korisnike iz $CSV_FILE =="
declare -A USER_ROLE USER_PROJECT
PROJECTS=("instruktor-projekt" "student1-projekt" "student2-projekt")
USERS=()
INSTRUKTOR=""
while IFS=';' read -r ime prezime rola; do
    [[ "$ime" == "ime" ]] && continue
    username="${ime}.${prezime}"
    USERS+=("$username")
    USER_ROLE["$username"]="$rola"
    case "$rola" in
        instruktor)
            USER_PROJECT["$username"]="instruktor-projekt"
            INSTRUKTOR="$username"
            ;;
        student)
            if [[ "$username" == "pero.peric" ]]; then
                USER_PROJECT["$username"]="student1-projekt"
            elif [[ "$username" == "iva.ivic" ]]; then
                USER_PROJECT["$username"]="student2-projekt"
            fi
            ;;
    esac
done < "$CSV_FILE"

echo "Korisnici: ${USERS[*]}"
echo "Instruktor: $INSTRUKTOR"

source "$ADMIN_RC"

echo
echo "== [2] Kreiram projekte =="
for PRJ in "${PROJECTS[@]}"; do
    if ! openstack project show "$PRJ" &>/dev/null; then
        echo "--> Kreiram projekt: $PRJ"
        openstack project create "$PRJ"
    else
        echo "--> Projekt $PRJ već postoji"
    fi
done

echo
echo "== [3] Kreiram korisnike i role =="
for username in "${USERS[@]}"; do
    rola="${USER_ROLE[$username]}"
    projekt="${USER_PROJECT[$username]}"
    if ! openstack user show "$username" &>/dev/null; then
        echo "--> Kreiram korisnika: $username ($rola, $projekt)"
        openstack user create --password "$PASSWORD" --project "$projekt" "$username"
    else
        echo "--> Korisnik $username već postoji"
    fi
    if [[ "$rola" == "student" ]]; then
        openstack role add --user "$username" --project "$projekt" admin
    fi
done

for PRJ in "${PROJECTS[@]}"; do
    openstack role add --user "$INSTRUKTOR" --project "$PRJ" admin
done

if openstack user show admin &>/dev/null; then
    for PRJ in "${PROJECTS[@]}"; do
        openstack role add --user admin --project "$PRJ" admin
    done
fi

echo
echo "== [4] Generiram RC fajlove za svakog korisnika/projekt =="
for username in "${USERS[@]}"; do
    projekt="${USER_PROJECT[$username]}"
    RC_FILE="/etc/kolla/${projekt}-openrc.sh"
    cat > "$RC_FILE" <<EOF
export OS_AUTH_URL=$KEYSTONE_URL
export OS_PROJECT_NAME="$projekt"
export OS_USERNAME="$username"
export OS_PASSWORD="$PASSWORD"
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_IDENTITY_API_VERSION=3
export OS_REGION_NAME=RegionOne
EOF
    chmod 600 "$RC_FILE"
    echo "--> Generiran RC file za $username ($projekt): $RC_FILE"
done

echo
echo "== [5] Kreiram router $ROUTER =="
if ! openstack router show "$ROUTER" &>/dev/null; then
    openstack router create "$ROUTER" --tag $TAG
    openstack router set --external-gateway "$EXT_NET" "$ROUTER"
    echo "--> Router $ROUTER kreiran i spojen na vanjsku mrežu"
else
    echo "--> Router $ROUTER već postoji"
fi

declare -A NETWORKS=(
    [instruktor-projekt-instruktor-net]="instruktor-projekt;10.20.0.0/24"
    [instruktor-projekt-instruktor-minio-net]="instruktor-projekt;10.50.0.0/24"
    [student1-projekt-student1-net]="student1-projekt;10.30.0.0/24"
    [student2-projekt-student2-net]="student2-projekt;10.40.0.0/24"
)
declare -A SUBNETS=(
    [instruktor-projekt-instruktor-net]="instruktor-projekt-instruktor-net-subnet"
    [instruktor-projekt-instruktor-minio-net]="instruktor-projekt-instruktor-minio-net-subnet"
    [student1-projekt-student1-net]="student1-projekt-student1-net-subnet"
    [student2-projekt-student2-net]="student2-projekt-student2-net-subnet"
)

echo
echo "== [6] Kreiram mreže, subnetove i dodajem ih na router =="
for netname in "${!NETWORKS[@]}"; do
    IFS=';' read -r project cidr <<< "${NETWORKS[$netname]}"
    subnet=${SUBNETS[$netname]}
    RC_FILE="/etc/kolla/${project}-openrc.sh"
    source "$RC_FILE"
    if ! openstack network show "$netname" &>/dev/null; then
        if [[ "$netname" == "instruktor-projekt-instruktor-minio-net" ]]; then
            echo "--> Kreiram SHARED mrežu $netname u projektu $project"
            openstack network create --share --project "$project" --tag $TAG "$netname"
        else
            echo "--> Kreiram privatnu mrežu $netname u projektu $project"
            openstack network create --project "$project" --tag $TAG "$netname"
        fi
    else
        echo "--> Mreža $netname već postoji"
    fi
    if ! openstack subnet show "$subnet" &>/dev/null; then
        echo "--> Kreiram subnet $subnet ($cidr)"
        openstack subnet create --network "$netname" --subnet-range "$cidr" --tag $TAG "$subnet"
    else
        echo "--> Subnet $subnet već postoji"
    fi

    # Spoji subnet na router SAMO AKO NIJE VEĆ SPOJEN
    ROUTER_ID=$(openstack router show "$ROUTER" -f value -c id)
    SUBNET_ID=$(openstack subnet show "$subnet" -f value -c id)
    if ! openstack port list --device-owner network:router_interface --device-id "$ROUTER_ID" --fixed-ip subnet="$SUBNET_ID" -f value -c id | grep -q .; then
        echo "--> Spajam subnet $subnet na router $ROUTER"
        openstack router add subnet "$ROUTER" "$subnet"
    else
        echo "--> Subnet $subnet je već spojen na router $ROUTER"
    fi
done

declare -A SECGROUPS=(
    [instruktor-projekt]="instruktor-projekt-secgroup"
    [student1-projekt]="student1-projekt-secgroup"
    [student2-projekt]="student2-projekt-secgroup"
)

echo
echo "== [7] Kreiram security grupe =="

for project in "${PROJECTS[@]}"; do
    RC_FILE="/etc/kolla/${project}-openrc.sh"
    source "$RC_FILE"
    sg=${SECGROUPS[$project]}
    # Dohvati SVE ID-ove s tim imenom
    SG_IDS=($(openstack security group list --project "$project" -f value -c ID -c Name | awk -v N="$sg" '$2 == N {print $1}'))
    if [[ ${#SG_IDS[@]} -eq 0 ]]; then
        echo "--> Kreiram security grupu $sg u $project"
        SGID=$(openstack security group create --description "Default secgroup for $project" --tag $TAG "$sg" -f value -c id)
        openstack security group rule create --proto icmp "$SGID"
        openstack security group rule create --proto tcp --dst-port 22 "$SGID"
        openstack security group rule create --proto tcp --dst-port 80 "$SGID"
        openstack security group rule create --proto tcp --dst-port 443 "$SGID"
        openstack security group rule create --proto tcp --dst-port 9000 "$SGID"
        openstack security group rule create --proto tcp --dst-port 2049 "$SGID"
        openstack security group rule create --proto udp --dst-port 2049 "$SGID"
    else
        echo "--> Security grupa $sg već postoji (${#SG_IDS[@]})"
    fi
done

echo
echo "== [8] Uploadam keypair u svaki projekt =="
for project in "${PROJECTS[@]}"; do
    RC_FILE="/etc/kolla/${project}-openrc.sh"
    source "$RC_FILE"
    if ! openstack keypair show "$KEYPAIR" &>/dev/null; then
        echo "--> Uploadam keypair $KEYPAIR u projekt $project"
        openstack keypair create --public-key "$KEYPAIR_PUB" "$KEYPAIR"
    else
        echo "--> Keypair $KEYPAIR već postoji u projektu $project"
    fi
done

declare -A VMINFO=(
    [jumphost-instruktor]="instruktor-projekt;instruktor-projekt-instruktor-net;10.20.0.10;ubuntu-jammy;instruktor-projekt-secgroup"
    [jumphost-student1]="student1-projekt;student1-projekt-student1-net;10.30.0.10;ubuntu-jammy;student1-projekt-secgroup"
    [jumphost-student2]="student2-projekt;student2-projekt-student2-net;10.40.0.10;ubuntu-jammy;student2-projekt-secgroup"
    [minio-vm]="instruktor-projekt;instruktor-projekt-instruktor-minio-net;10.50.0.11;minio-golden;instruktor-projekt-secgroup"
)

echo
echo "== [9] Deployam VM-ove =="

for VM in "${!VMINFO[@]}"; do
    IFS=';' read -r PROJECT NETNAME IPADDR IMAGE SECGROUP <<< "${VMINFO[$VM]}"
    RC_FILE="/etc/kolla/${PROJECT}-openrc.sh"
    source "$RC_FILE"

    # DEBUG linija – vidiš odmah vrijednosti svih polja:
    echo "DEBUG: VM='$VM' PROJECT='$PROJECT' NETNAME='$NETNAME' IPADDR='$IPADDR' IMAGE='$IMAGE' SECGROUP='$SECGROUP'"

    if [[ -z "$VM" || -z "$PROJECT" || -z "$NETNAME" || -z "$IPADDR" || -z "$IMAGE" || -z "$SECGROUP" ]]; then
        echo "!!! Preskačem VM jer fali podatak (nešto je prazno)!"
        continue
    fi

    if openstack server show "$VM" &>/dev/null; then
        echo "--> VM $VM već postoji"
        continue
    fi

    NET_ID=$(openstack network show "$NETNAME" -f value -c id)
    SG_ID=$(openstack security group list --project "$PROJECT" -f value -c ID -c Name | awk -v N="$SECGROUP" '$2 == N {print $1}' | head -n1)

    if [[ -z "$NET_ID" ]]; then
        echo "!!! Ne postoji mreža $NETNAME za projekt $PROJECT – preskačem VM $VM"
        continue
    fi
    if [[ -z "$SG_ID" ]]; then
        echo "!!! Ne postoji security group $SECGROUP za projekt $PROJECT – preskačem VM $VM"
        continue
    fi

    echo "--> Kreiram VM $VM u projektu $PROJECT, mreža $NETNAME, IP $IPADDR, image $IMAGE"
    openstack server create \
        --flavor m1.medium \
        --image "$IMAGE" \
        --nic net-id="$NET_ID",v4-fixed-ip="$IPADDR" \
        --key-name "$KEYPAIR" \
        --security-group "$SG_ID" \
        --tag $TAG \
        "$VM"
done

echo
echo "== [10] Dodjela floating IP-a jumphostovima =="

for VM in "${!VMINFO[@]}"; do
    if [[ "$VM" == jumphost-* ]]; then
        IFS=';' read -r PROJECT NETNAME IPADDR IMAGE SECGROUP <<< "${VMINFO[$VM]}"
        RC_FILE="/etc/kolla/${PROJECT}-openrc.sh"
        source "$RC_FILE"
        echo "--> Provjeravam VM $VM za floating IP"

        # Dohvati port ID prvog interfacea (pretpostavljaš 1 NIC po VM-u ovdje!)
        SERVER_ID=$(openstack server show "$VM" -f value -c id)
        PORT_ID=$(openstack port list --server "$SERVER_ID" -f value -c ID | head -n1)

        # Provjeri ima li VM već floating IP
        EXISTING_FIP=$(openstack floating ip list --port "$PORT_ID" -f value -c "Floating IP Address")
        if [[ -n "$EXISTING_FIP" ]]; then
            echo "----> VM $VM već ima floating IP: $EXISTING_FIP"
            continue
        fi

        # Kreiraj novi floating IP
        FIP=$(openstack floating ip create --description "$VM" "$EXT_NET" -f value -c floating_ip_address)
        echo "----> Dodjeljujem floating IP $FIP VM-u $VM"
        openstack server add floating ip "$VM" "$FIP"
    fi
done
echo
echo "== [11] Deploy preostalih VM-ova po projektima (multi-NIC za Minio) =="

# Definiraj sve VM-ove kao asocijativni niz: ime="projekt;mreza1;ip1;image;secgroup;[minio_net];[minio_ip]"
declare -A VM_EXTRA=(
    # INSTRUKTOR
    [lb-instruktor]="instruktor-projekt;instruktor-projekt-instruktor-net;10.20.0.11;lb-golden;instruktor-projekt-secgroup;;"
    [wp0-1]="instruktor-projekt;instruktor-projekt-instruktor-net;10.20.0.21;wp-golden;instruktor-projekt-secgroup;instruktor-projekt-instruktor-minio-net;10.50.0.25"
    [wp0-2]="instruktor-projekt;instruktor-projekt-instruktor-net;10.20.0.22;wp-golden;instruktor-projekt-secgroup;instruktor-projekt-instruktor-minio-net;10.50.0.26"
    # STUDENT1
    [lb-student1]="student1-projekt;student1-projekt-student1-net;10.30.0.11;lb-golden;student1-projekt-secgroup;;"
    [wp1-1]="student1-projekt;student1-projekt-student1-net;10.30.0.21;wp-golden;student1-projekt-secgroup;instruktor-projekt-instruktor-minio-net;10.50.0.21"
    [wp1-2]="student1-projekt;student1-projekt-student1-net;10.30.0.22;wp-golden;student1-projekt-secgroup;instruktor-projekt-instruktor-minio-net;10.50.0.22"
    # STUDENT2
    [lb-student2]="student2-projekt;student2-projekt-student2-net;10.40.0.11;lb-golden-test3;student2-projekt-secgroup;;"
    [wp2-1]="student2-projekt;student2-projekt-student2-net;10.40.0.21;wp-golden;student2-projekt-secgroup;instruktor-projekt-instruktor-minio-net;10.50.0.23"
    [wp2-2]="student2-projekt;student2-projekt-student2-net;10.40.0.22;wp-golden;student2-projekt-secgroup;instruktor-projekt-instruktor-minio-net;10.50.0.24"
)

for VM in "${!VM_EXTRA[@]}"; do
    IFS=';' read -r PROJECT NETNAME IPADDR IMAGE SECGROUP MINIONET MINIOIP <<< "${VM_EXTRA[$VM]}"
    RC_FILE="/etc/kolla/${PROJECT}-openrc.sh"
    source "$RC_FILE"

    echo "DEBUG: VM='$VM' PROJECT='$PROJECT' NETNAME='$NETNAME' IPADDR='$IPADDR' IMAGE='$IMAGE' SECGROUP='$SECGROUP' MINIONET='$MINIONET' MINIOIP='$MINIOIP'"

    if openstack server show "$VM" &>/dev/null; then
        echo "--> VM $VM već postoji"
        continue
    fi

    # Prvi NIC (primarna mreža)
    NET_ID=$(openstack network show "$NETNAME" -f value -c id)
    SG_ID=$(openstack security group list --project "$PROJECT" -f value -c ID -c Name | awk -v N="$SECGROUP" '$2 == N {print $1}' | head -n1)
    NICS="--nic net-id=${NET_ID},v4-fixed-ip=${IPADDR}"

    # Ako treba još jedan NIC na minio-net
    if [[ -n "$MINIONET" && -n "$MINIOIP" ]]; then
        # Minio net je uvijek u projektu "instruktor-projekt"
        MINIO_NET_ID=$(openstack network show "$MINIONET" -f value -c id)
        NICS+=" --nic net-id=${MINIO_NET_ID},v4-fixed-ip=${MINIOIP}"
    fi

    if [[ -z "$NET_ID" || -z "$SG_ID" ]]; then
        echo "!!! Nedostaje mreža ili security group za $VM, preskačem."
        continue
    fi

    echo "--> Kreiram VM $VM u projektu $PROJECT, image $IMAGE, NICS: $NICS"
    openstack server create \
        --flavor m1.medium \
        --image "$IMAGE" \
        $NICS \
        --key-name "$KEYPAIR" \
        --security-group "$SG_ID" \
        --tag $TAG \
        "$VM"
done

echo
echo "== [12] Provjera da su svi VM-ovi ACTIVE, zatim kreiram i attacham volumene =="

# Kombiniraj sve VM-ove (jumphostovi + ostali)
ALL_VMS=()
for VM in "${!VMINFO[@]}"; do ALL_VMS+=("$VM"); done
for VM in "${!VM_EXTRA[@]}"; do ALL_VMS+=("$VM"); done

declare -A ACTIVE_VMS=()
for VM in "${ALL_VMS[@]}"; do
    # Očitaj projekt (iz VMINFO ili VM_EXTRA)
    ENTRY="${VMINFO[$VM]:-${VM_EXTRA[$VM]}}"
    IFS=';' read -r PROJECT _ <<< "$ENTRY"
    RC_FILE="/etc/kolla/${PROJECT}-openrc.sh"
    source "$RC_FILE"

    echo "--> Provjeravam VM $VM u projektu $PROJECT"

    if ! openstack server show "$VM" &>/dev/null; then
        echo "!!! VM $VM ne postoji, preskačem."
        continue
    fi

    # Čekaj dok VM ne bude ACTIVE (max 120s)
    for t in {1..24}; do
        STATUS=$(openstack server show "$VM" -f value -c status)
        if [[ "$STATUS" == "ACTIVE" ]]; then
            echo "----> VM $VM je ACTIVE"
            ACTIVE_VMS["$VM"]="$PROJECT"
            break
        elif [[ "$STATUS" == "ERROR" ]]; then
            echo "!!!! VM $VM je u ERROR stanju, preskačem attach volumena."
            break
        else
            echo "----> VM $VM još nije ACTIVE (status: $STATUS), čekam..."
            sleep 10
        fi
    done
done

echo
echo "== [13] Kreiram i attacham 2x1GB volumene za svaki ACTIVE VM =="

for VM in "${!ACTIVE_VMS[@]}"; do
    PROJECT="${ACTIVE_VMS[$VM]}"
    RC_FILE="/etc/kolla/${PROJECT}-openrc.sh"
    source "$RC_FILE"

    for i in 1 2; do
        VOLNAME="${VM}-data-${i}"
        # Kreiraj volume ako ne postoji
        if ! openstack volume show "$VOLNAME" &>/dev/null; then
            echo "--> Kreiram volume $VOLNAME (1GB) za VM $VM"
            openstack volume create --size 1 "$VOLNAME"
#            openstack volume set --tag $TAG "$VOLNAME"
        else
            echo "--> Volume $VOLNAME već postoji"
        fi

        VID=$(openstack volume show "$VOLNAME" -f value -c id)
        # Attachaj samo ako već nije attach-an
        if ! openstack server volume list "$VM" -f value -c "Volume ID" | grep -q "$VID"; then
            echo "--> Attacham volume $VOLNAME ($VID) na VM $VM"
            openstack server add volume "$VM" "$VOLNAME"
        else
            echo "--> Volume $VOLNAME ($VID) je već attach-an na VM $VM"
        fi
    done
done
echo
echo "== [14] Prebacujem sve studente iz $CSV_FILE sa admin na member rolu u njihovim projektima =="

while IFS=';' read -r ime prezime rola; do
    [[ "$ime" == "ime" ]] && continue
    [[ "$rola" != "student" ]] && continue

    username="${ime}.${prezime}"
    projekt="${username/\./}"-projekt   # npr. pero.peric -> pero.peric-projekt

    # Ako imaš specifične nazive projekata (student1-projekt...), možeš dodati mapiranje ovdje:
    if [[ "$username" == "pero.peric" ]]; then
        projekt="student1-projekt"
    elif [[ "$username" == "iva.ivic" ]]; then
        projekt="student2-projekt"
    fi

    echo "--> Za $username ($projekt): makni admin, dodaj member"
    openstack role remove --user "$username" --project "$projekt" admin 2>/dev/null && echo "----> Uklonjen admin"
    openstack role add --user "$username" --project "$projekt" member && echo "----> Dodan member"
done < "$CSV_FILE"

echo
echo "== [15] Kreiram grupe 'studenti' i 'instruktori', te dodajem korisnike =="

# Kreiraj grupe ako ne postoje
for grupa in studenti instruktori; do
    if ! openstack group show "$grupa" &>/dev/null; then
        openstack group create "$grupa"
        echo "--> Grupa $grupa je kreirana"
    else
        echo "--> Grupa $grupa već postoji"
    fi
done

# Dodaj korisnike u odgovarajuće grupe
while IFS=';' read -r ime prezime rola; do
    [[ "$ime" == "ime" ]] && continue
    username="${ime}.${prezime}"

    if [[ "$rola" == "student" ]]; then
        openstack group add user studenti "$username" && echo "----> $username dodan u grupu studenti"
    elif [[ "$rola" == "instruktor" ]]; then
        openstack group add user instruktori "$username" && echo "----> $username dodan u grupu instruktori"
    fi
done < "$CSV_FILE"


echo
echo "==== INFRASTRUKTURA I VM-OVI SU SPREMNI! ===="


echo
echo
echo "== [16] Prikaz svih resursa s tagom 'course=test' =="

source "$ADMIN_RC"

echo "--> SVI SECURITY GROUP-e S TAGOM:"
openstack security group list --tags course=test

echo
echo "--> SVE MREŽE S TAGOM:"
openstack network list --tag course=test

echo
echo "--> SVE VM-ove (po projektima) S TAGOM:"

for prj in instruktor-projekt student1-projekt student2-projekt; do
    RC_FILE="/etc/kolla/${prj}-openrc.sh"
    source "$RC_FILE"
    echo
    echo ">>> VM-ovi u projektu $prj"
    openstack server list --tag course=test
done


echo
echo "====HVALA NA PAŽNJI===="
echo
echo
