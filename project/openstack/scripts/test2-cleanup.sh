#!/bin/bash
set -e

ADMIN_RC="/etc/kolla/admin-openrc.sh"
KEYPAIR="labkey"

PROJECTS=(
  instruktor-projekt
  student1-projekt
  student2-projekt
)
USERS=(mario.maric pero.peric iva.ivic)

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

VM_LIST=(
  minio-vm instruktur lb-instruktor wp0-1 wp0-2
  jumphost1 lb-student1 wp1-1 wp1-2
  jumphost2 lb-student2 wp2-1 wp2-2
)

echo
echo "== [C1] Sourcing admin openrc =="
source "$ADMIN_RC"

# Step 1: Ukloni VM-ove
echo
echo "== [C2] Brišem VM-ove =="
for PRJ in "${PROJECTS[@]}"; do
    source "$ADMIN_RC"
    for USER in "${USERS[@]}"; do
        RC_FILE="/etc/kolla/${USER}-openrc.sh"
        [[ -f "$RC_FILE" ]] && source "$RC_FILE"
        for VM in $(openstack server list --project "$PRJ" -f value -c Name); do
            echo "----> Brišem VM: $VM ($PRJ)"
            openstack server delete "$VM" || true
        done
    done
done

# Step 2: Attachane volumene detachaj i obriši diskove
echo
echo "== [C3] Brišem volumene =="
for PRJ in "${PROJECTS[@]}"; do
    for USER in "${USERS[@]}"; do
        RC_FILE="/etc/kolla/${USER}-openrc.sh"
        [[ -f "$RC_FILE" ]] && source "$RC_FILE"
        for VOL in $(openstack volume list --project "$PRJ" -f value -c Name); do
            STATUS=$(openstack volume show "$VOL" -f value -c status)
            if [[ "$STATUS" == "in-use" ]]; then
                echo "----> Detacham volume $VOL"
                SERVER_ID=$(openstack volume show "$VOL" -f value -c attachments | grep -oP "'server_id': u?'?\K[^']+" | head -n1)
                [[ -n "$SERVER_ID" ]] && openstack server remove volume "$SERVER_ID" "$VOL" || true
                sleep 2
            fi
            echo "----> Brišem volume: $VOL"
            openstack volume delete "$VOL" || true
        done
    done
done

# Step 3: Briši portove (ručno)
echo
echo "== [C4] Brišem portove =="
for PRJ in "${PROJECTS[@]}"; do
    PORTS=$(openstack port list --project "$PRJ" -f value -c ID)
    for PID in $PORTS; do
        echo "----> Brišem port: $PID ($PRJ)"
        openstack port delete "$PID" || true
    done
done

# Step 4: Briši floating IP-ove (ako ih imaš)
echo
echo "== [C5] Brišem floating IP-ove =="
for PRJ in "${PROJECTS[@]}"; do
    FIPS=$(openstack floating ip list --project "$PRJ" -f value -c ID)
    for FID in $FIPS; do
        echo "----> Brišem FIP: $FID ($PRJ)"
        openstack floating ip delete "$FID" || true
    done
done

# Step 5: Briši rutere
echo
echo "== [C6] Brišem rutere =="
for NET in "${NETWORKS[@]}"; do
    for RT in $(openstack router list -f value -c Name | grep "$NET-router" || true); do
        echo "----> Uklanjam subnetove s routera: $RT"
        SUBNETS=$(openstack router show "$RT" -f json | grep subnet_id | awk -F"'" '{print $4}')
        for S in $SUBNETS; do
            openstack router remove subnet "$RT" "$S" || true
        done
        echo "----> Brišem router: $RT"
        openstack router delete "$RT" || true
    done
done

# Step 6: Briši subnetove i mreže
echo
echo "== [C7] Brišem subnetove i mreže =="
for NET in "${NETWORKS[@]}"; do
    SUBNET="${NET}-subnet"
    if openstack subnet show "$SUBNET" &>/dev/null; then
        echo "----> Brišem subnet: $SUBNET"
        openstack subnet delete "$SUBNET" || true
    fi
    if openstack network show "$NET" &>/dev/null; then
        echo "----> Brišem mrežu: $NET"
        openstack network delete "$NET" || true
    fi
done

# Step 7: Briši security grupe
echo
echo "== [C8] Brišem security grupe =="
for PRJ in "${PROJECTS[@]}"; do
    SGNAME="${PRJ}-secgroup"
    SGIDS=( $(openstack security group list --project "$PRJ" -f value -c ID -c Name | awk -v name="$SGNAME" '$2 == name {print $1}') )
    for SGID in "${SGIDS[@]}"; do
        echo "----> Brišem secgroup: $SGID ($SGNAME, $PRJ)"
        openstack security group delete "$SGID" || true
    done
done

# Step 8: Briši keypair u svakom projektu
echo
echo "== [C9] Brišem keypair labkey =="
for USER in "${USERS[@]}"; do
    RC_FILE="/etc/kolla/${USER}-openrc.sh"
    [[ -f "$RC_FILE" ]] && source "$RC_FILE"
    if openstack keypair show "$KEYPAIR" &>/dev/null; then
        echo "----> Brišem keypair $KEYPAIR ($USER)"
        openstack keypair delete "$KEYPAIR" || true
    fi
done

# Step 9: Briši korisnike i projekte
echo
echo "== [C10] Brišem korisnike i projekte =="
for USER in "${USERS[@]}"; do
    if openstack user show "$USER" &>/dev/null; then
        echo "----> Brišem user: $USER"
        openstack user delete "$USER" || true
    fi
done
for PRJ in "${PROJECTS[@]}"; do
    if openstack project show "$PRJ" &>/dev/null; then
        echo "----> Brišem projekt: $PRJ"
        openstack project delete "$PRJ" || true
    fi
done

echo
echo "== CLEANUP GOTOV! Sve resurse je skripta pokušala obrisati. =="

