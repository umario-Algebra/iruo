#!/bin/bash
set -e

ADMIN_RC="/etc/kolla/admin-openrc.sh"
CSV_FILE="osobe.csv"
KEYPAIR="labkey"
KEYPAIR_PUB="$HOME/.ssh/labkey.pub"
TAG="course=test"

PROJECTS=(
  instruktor-projekt
  student1-projekt
  student2-projekt
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

echo
echo "== [1/7] Učitavam korisnike iz $CSV_FILE =="
USERS=()
INSTRUKTOR=""
STUDENT_USERS=()
while IFS=';' read -r ime prezime rola; do
    [[ "$ime" == "ime" ]] && continue
    user="${ime}.${prezime}"
    USERS+=("$user|$rola")
    if [[ "$rola" == "instruktor" ]]; then
        INSTRUKTOR="$user"
    elif [[ "$rola" == "student" ]]; then
        STUDENT_USERS+=("$user")
    fi
done < "$CSV_FILE"

echo
echo "== [2/7] Kreiram projekte po namingu =="
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
echo "== [3/7] Kreiram korisnike i dodjeljujem role =="
for entry in "${USERS[@]}"; do
    IFS='|' read -r user rola <<< "$entry"
    PRJ=""
    case "$rola" in
        instruktor) PRJ="instruktor-projekt" ;;
        student)
            if [[ "$user" == "pero.peric" ]]; then
                PRJ="student1-projekt"
            elif [[ "$user" == "iva.ivic" ]]; then
                PRJ="student2-projekt"
            fi
            ;;
    esac
    # Kreiraj user
    if ! openstack user show "$user" &>/dev/null; then
        echo "--> Kreiram usera: $user ($rola) u projektu $PRJ"
        openstack user create --project "$PRJ" --password "TestPSW80!" "$user"
    else
        echo "--> User već postoji: $user"
    fi
    # Dodjela role
    if [[ "$rola" == "instruktor" ]]; then
        # Instruktor je admin na svom projektu
        if ! openstack role assignment list --user "$user" --project "instruktor-projekt" --role admin -f value | grep -q .; then
            openstack role add --user "$user" --project "instruktor-projekt" admin
        fi
        # Instruktor je admin na studentskim projektima
        for stud_prj in student1-projekt student2-projekt; do
            if ! openstack role assignment list --user "$user" --project "$stud_prj" --role admin -f value | grep -q .; then
                echo "   -> Dodajem $user kao admin na $stud_prj"
                openstack role add --user "$user" --project "$stud_prj" admin
            fi
        done
    else
        # Student je admin na svom projektu
        if ! openstack role assignment list --user "$user" --project "$PRJ" --role admin -f value | grep -q .; then
            openstack role add --user "$user" --project "$PRJ" admin
        fi
    fi
done

# Admin korisnik je admin na svim projektima
echo
echo "== [3b/7] Dodajem admin usera kao admina na sve projekte =="
for PRJ in "${PROJECTS[@]}"; do
    if ! openstack role assignment list --user admin --project "$PRJ" --role admin -f value | grep -q .; then
        echo "--> Dodajem admin kao admin u $PRJ"
        openstack role add --user admin --project "$PRJ" admin
    else
        echo "--> Admin je već admin na $PRJ"
    fi
done

echo
echo "== [4/7] Kreiram mreže/subnete/routere po namingu =="
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
    # Mreža
    if ! openstack network show "$NETNAME" &>/dev/null; then
        echo "--> Kreiram mrežu: $NETNAME ($PRJ)"
        openstack network create --project "$PRJ" --tag "$TAG" "$NETNAME"
    else
        echo "--> Mreža postoji: $NETNAME"
    fi
    # Subnet
    if ! openstack subnet show "$SUBNET" &>/dev/null; then
        echo "   -> Kreiram subnet: $SUBNET ($CIDR)"
        openstack subnet create --project "$PRJ" --network "$NETNAME" --subnet-range "$CIDR" --tag "$TAG" "$SUBNET"
    else
        echo "   -> Subnet postoji: $SUBNET"
    fi
    # Router
    if ! openstack router show "$ROUTER" &>/dev/null; then
        echo "   -> Kreiram router: $ROUTER"
        openstack router create --project "$PRJ" "$ROUTER"
        openstack router set --external-gateway public "$ROUTER"
    else
        echo "   -> Router postoji: $ROUTER"
    fi
    # Spajanje subnet-a na router (provjera)
    SUBNET_ID=$(openstack subnet show "$SUBNET" -f value -c id)
    ROUTER_ID=$(openstack router show "$ROUTER" -f value -c id)
    ROUTER_PORT=$(openstack port list --device-owner network:router_interface --device-id $ROUTER_ID --fixed-ip subnet=$SUBNET_ID -f value -c id)
    if [[ -z "$ROUTER_PORT" ]]; then
        echo "   -> Dodajem subnet $SUBNET na router $ROUTER"
        openstack router add subnet "$ROUTER" "$SUBNET"
    else
        echo "   -> Subnet $SUBNET je već spojen na router $ROUTER"
    fi
done

echo
echo "== [5/7] Kreiram security grupe po namingu =="
for PRJ in "${PROJECTS[@]}"; do
    SGNAME="${PRJ}-secgroup"
    # Traži po imenu i projektu (može biti više s istim imenom)
    SGIDS=( $(openstack security group list --project "$PRJ" -f value -c ID -c Name | awk -v name="$SGNAME" '$2 == name {print $1}') )
    SGCOUNT=${#SGIDS[@]}
    if [ "$SGCOUNT" -eq 0 ]; then
        echo "--> Kreiram security grupu: $SGNAME ($PRJ)"
        SGID=$(openstack security group create --project "$PRJ" "$SGNAME" --description "Default grupa za $PRJ" -f value -c id)
        # Pričekaj da backend izlista samo 1 grupu s tim imenom
        for retry in {1..10}; do
            sleep 1
            SGIDS=( $(openstack security group list --project "$PRJ" -f value -c ID -c Name | awk -v name="$SGNAME" '$2 == name {print $1}') )
            [ "${#SGIDS[@]}" -eq 1 ] && break
        done
        SGID="${SGIDS[0]}"
        # Pravila uvijek po ID-u, ne po imenu
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
        echo "!! Više security grupa s imenom $SGNAME postoji u projektu $PRJ !!"
        # Ostavi prvu, briši ostale
        for i in "${SGIDS[@]:1}"; do
            echo "----> Brišem dupli security group $i"
            openstack security group delete "$i"
        done
        echo "----> Security grupa $SGNAME ostavljena (ID: ${SGIDS[0]})"
    fi
done
echo "== [7/7] Kreiram RC file za svakog korisnika =="

for entry in "${USERS[@]}"; do
    IFS='|' read -r user rola <<< "$entry"
    # Detektiraj projekt po roli i imenu
    PRJ=""
    if [[ "$rola" == "instruktor" ]]; then
        PRJ="instruktor-projekt"
    elif [[ "$rola" == "student" ]]; then
        if [[ "$user" == "pero.peric" ]]; then
            PRJ="student1-projekt"
        elif [[ "$user" == "iva.ivic" ]]; then
            PRJ="student2-projekt"
        fi
    fi

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

echo "== [8/8] Provjera i upload labkey keypair svakom korisniku =="
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

# Na kraju možeš opet vratiti admin kontekst
source "$ADMIN_RC"

echo
echo "== BAZNA INFRASTRUKTURA JE SPREMNA PO DOGOVORENOM NAMINGU =="
echo "Sve po Naming dokumentu, idući korak: VM-ovi, portovi i diskovi!"
