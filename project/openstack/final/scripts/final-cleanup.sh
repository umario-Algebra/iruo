#!/bin/bash
set -e

ADMIN_RC="/etc/kolla/admin-openrc.sh"
CSV_FILE="osobe.csv"
KEYPAIR="labkey"
TAG="course=test"
ROUTER="main-lab-router"
EXT_NET="public"

declare -a PROJECTS=("instruktor-projekt" "student1-projekt" "student2-projekt")
declare -a NETWORKS=("instruktor-projekt-instruktor-net" "instruktor-projekt-instruktor-minio-net" "student1-projekt-student1-net" "student2-projekt-student2-net")
declare -a SUBNETS=("instruktor-projekt-instruktor-net-subnet" "instruktor-projekt-instruktor-minio-net-subnet" "student1-projekt-student1-net-subnet" "student2-projekt-student2-net-subnet")
declare -a SECGROUPS=("instruktor-projekt-secgroup" "student1-projekt-secgroup" "student2-projekt-secgroup")

# Priprema korisnika iz CSV
USERS=()
while IFS=';' read -r ime prezime rola; do
    [[ "$ime" == "ime" ]] && continue
    USERS+=("${ime}.${prezime}")
done < "$CSV_FILE"

source "$ADMIN_RC"

echo
echo "== [Cleanup] Brišem VM-ove =="
for project in "${PROJECTS[@]}"; do
    RC_FILE="/etc/kolla/${project}-openrc.sh"
    source "$RC_FILE"
    for VM in $(openstack server list --tag $TAG -f value -c Name); do
        echo "--> Brišem VM $VM u projektu $project"
        openstack server delete "$VM" || true
    done
done

echo
echo "== [Cleanup] Brišem volumene (dodatne diskove) =="
for project in "${PROJECTS[@]}"; do
    RC_FILE="/etc/kolla/${project}-openrc.sh"
    source "$RC_FILE"
    for VOL in $(openstack volume list -f value -c Name | grep -- '-data-[12]$' || true); do
        echo "--> Brišem volume $VOL u projektu $project"
        openstack volume delete "$VOL" || true
    done
done

echo
echo "== [Cleanup] Brišem floating IP adrese =="
for project in "${PROJECTS[@]}"; do
    RC_FILE="/etc/kolla/${project}-openrc.sh"
    source "$RC_FILE"
    for FIP in $(openstack floating ip list -f value -c ID); do
        echo "--> Brišem floating IP $FIP u projektu $project"
        openstack floating ip delete "$FIP" || true
    done
done

echo
echo "== [Cleanup] Brišem keypair $KEYPAIR =="
for project in "${PROJECTS[@]}"; do
    RC_FILE="/etc/kolla/${project}-openrc.sh"
    source "$RC_FILE"
    if openstack keypair show "$KEYPAIR" &>/dev/null; then
        echo "--> Brišem keypair $KEYPAIR u projektu $project"
        openstack keypair delete "$KEYPAIR"
    fi
done

echo
echo "== [Cleanup] Brišem security grupe =="
for project in "${PROJECTS[@]}"; do
    RC_FILE="/etc/kolla/${project}-openrc.sh"
    source "$RC_FILE"
    for SG in $(openstack security group list --project "$project" -f value -c ID -c Name | awk '$2 ~ /secgroup/ {print $1}'); do
        echo "--> Brišem security group $SG u projektu $project"
        openstack security group delete "$SG" || true
    done
done

echo
echo "== [Cleanup] Uklanjam subnetove s routera i brišem router =="
for subnet in "${SUBNETS[@]}"; do
    if openstack subnet show "$subnet" &>/dev/null; then
        echo "--> Uklanjam subnet $subnet s routera $ROUTER"
        openstack router remove subnet "$ROUTER" "$subnet" || true
    fi
done
if openstack router show "$ROUTER" &>/dev/null; then
    echo "--> Brišem router $ROUTER"
    openstack router delete "$ROUTER" || true
fi

echo
echo "== [Cleanup] Brišem mreže i subnetove =="
for net in "${NETWORKS[@]}"; do
    if openstack network show "$net" &>/dev/null; then
        echo "--> Brišem mrežu $net"
        openstack network delete "$net" || true
    fi
done

echo
echo "== [Cleanup] Brišem projekte =="
for prj in "${PROJECTS[@]}"; do
    if openstack project show "$prj" &>/dev/null; then
        echo "--> Brišem projekt $prj"
        openstack project delete "$prj" || true
    fi
done

echo
echo "== [Cleanup] Brišem korisnike =="
for username in "${USERS[@]}"; do
    if openstack user show "$username" &>/dev/null; then
        echo "--> Brišem korisnika $username"
        openstack user delete "$username" || true
    fi
done

echo
echo "== [Cleanup] Brišem grupe =="
for grupa in studenti instruktori; do
    if openstack group show "$grupa" &>/dev/null; then
        echo "--> Brišem grupu $grupa"
        openstack group delete "$grupa" || true
    fi
done

echo
echo "== [Cleanup] Gotovo! Svi lab resursi su obrisani."
