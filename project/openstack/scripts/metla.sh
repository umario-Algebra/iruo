#!/bin/bash
set -e

ADMIN_RC="/etc/kolla/admin-openrc.sh"
KEYPAIR="labkey"

# --- Definiraj projekte, mreže i security grupe kao u glavnoj skripti ---
PROJECTS=(
  instruktor-projekt
  student1-projekt
  student2-projekt
)

NETWORKS=(
  instruktor-projekt-instruktor-net
  instruktor-projekt-instruktor-minio-net
  student1-projekt-student1-net
  student2-projekt-student2-net
)

SECURITY_GROUPS=(
  instruktor-projekt-secgroup
  student1-projekt-secgroup
  student2-projekt-secgroup
)

# --- Lista korisnika iz CSV ---
CSV_FILE="osobe.csv"
USERS=()
while IFS=';' read -r ime prezime rola; do
    [[ "$ime" == "ime" ]] && continue # skip header
    USERS+=("${ime}.${prezime}")
done < "$CSV_FILE"

source "$ADMIN_RC"

echo
echo "== [1/8] Brisanje VM-ova i diskova =="
for PRJ in "${PROJECTS[@]}"; do
    echo "--> Projekt: $PRJ"
    # Briši sve VM-ove
    for VM in $(openstack --os-project-name "$PRJ" server list -f value -c Name); do
        echo "   -> Brišem VM: $VM"
        openstack --os-project-name "$PRJ" server delete "$VM" || true
    done
    # Briši volumene
    for VOL in $(openstack --os-project-name "$PRJ" volume list -f value -c Name); do
        echo "   -> Brišem volume: $VOL"
        openstack --os-project-name "$PRJ" volume delete "$VOL" || true
    done
done

echo
echo "== [2/8] Brisanje portova (koji nisu auto-brisani) =="
for PRJ in "${PROJECTS[@]}"; do
    for PORT in $(openstack --os-project-name "$PRJ" port list -f value -c ID); do
        echo "   -> Brišem port: $PORT"
        openstack --os-project-name "$PRJ" port delete "$PORT" || true
    done
done

echo
echo "== [3/8] Brisanje routera (i odspajanje subnetova) =="
for NETNAME in "${NETWORKS[@]}"; do
    PRJ=""
    case "$NETNAME" in
        instruktor-projekt-*) PRJ="instruktor-projekt" ;;
        student1-projekt-*) PRJ="student1-projekt" ;;
        student2-projekt-*) PRJ="student2-projekt" ;;
    esac
    ROUTER="${NETNAME}-router"
    SUBNET="${NETNAME}-subnet"
    if openstack router show "$ROUTER" &>/dev/null; then
        echo "   -> Odspajam subnet $SUBNET s routera $ROUTER"
        if openstack subnet show "$SUBNET" &>/dev/null; then
            openstack router remove subnet "$ROUTER" "$SUBNET" || true
        fi
        echo "   -> Brišem router: $ROUTER"
        openstack router delete "$ROUTER" || true
    fi
done

echo
echo "== [4/8] Brisanje subnetova =="
for NETNAME in "${NETWORKS[@]}"; do
    SUBNET="${NETNAME}-subnet"
    if openstack subnet show "$SUBNET" &>/dev/null; then
        echo "   -> Brišem subnet: $SUBNET"
        openstack subnet delete "$SUBNET" || true
    fi
done

echo
echo "== [5/8] Brisanje mreža =="
for NETNAME in "${NETWORKS[@]}"; do
    if openstack network show "$NETNAME" &>/dev/null; then
        echo "   -> Brišem mrežu: $NETNAME"
        openstack network delete "$NETNAME" || true
    fi
done

echo
echo "== [6/8] Brisanje security grupa =="
for PRJ in "${PROJECTS[@]}"; do
    SGNAME="${PRJ}-secgroup"
    SGIDS=( $(openstack security group list --project "$PRJ" -f value -c ID -c Name | awk -v name="$SGNAME" '$2 == name {print $1}') )
    for SGID in "${SGIDS[@]}"; do
        echo "   -> Brišem security grupu: $SGNAME (ID: $SGID)"
        openstack security group delete "$SGID" || true
    done
done

echo
echo "== [7/8] Brisanje keypair-a iz svih projekata =="
for PRJ in "${PROJECTS[@]}"; do
    if openstack keypair show --project "$PRJ" "$KEYPAIR" &>/dev/null; then
        echo "   -> Brišem keypair: $KEYPAIR iz $PRJ"
        openstack keypair delete --project "$PRJ" "$KEYPAIR" || true
    fi
done

echo
echo "== [8/8] Brisanje korisnika i projekata =="
for user in "${USERS[@]}"; do
    if openstack user show "$user" &>/dev/null; then
        echo "   -> Brišem usera: $user"
        openstack user delete "$user" || true
    fi
done
for PRJ in "${PROJECTS[@]}"; do
    if openstack project show "$PRJ" &>/dev/null; then
        echo "   -> Brišem projekt: $PRJ"
        openstack project delete "$PRJ" || true
    fi
    # Briši RC file ako postoji
    RC="/etc/kolla/${PRJ}-openrc.sh"
    if [[ -f "$RC" ]]; then
        echo "   -> Brišem RC file: $RC"
        rm -f "$RC"
    fi
done

echo
echo "== SVE OBRISANO prema naming konvenciji =="
