#!/bin/bash
set -e

PROJECTS=("instruktor-projekt" "student1-projekt" "student2-projekt")
RC_ADMIN="/etc/kolla/admin-openrc.sh"

VM_LIST=(
  "minio-vm|instruktor-projekt"
  "instruktor|instruktor-projekt"
  "lb-instruktor|instruktor-projekt"
  "wp0-1|instruktor-projekt"
  "wp0-2|instruktor-projekt"
  "jumphost1|student1-projekt"
  "lb-student1|student1-projekt"
  "wp1-1|student1-projekt"
  "wp1-2|student1-projekt"
  "jumphost2|student2-projekt"
  "lb-student2|student2-projekt"
  "wp2-1|student2-projekt"
  "wp2-2|student2-projekt"
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

# =========== CLEANUP KRENI ===========

source "$RC_ADMIN"

echo
echo "== [1/7] BRIŠEM VM-ove =="
for vmline in "${VM_LIST[@]}"; do
  IFS='|' read -r VMNAME PRJ <<< "$vmline"
  source /etc/kolla/${PRJ}-openrc.sh
  if openstack server show "$VMNAME" &>/dev/null; then
    echo "----> Brišem VM: $VMNAME ($PRJ)"
    openstack server delete "$VMNAME"
  else
    echo "----> VM ne postoji: $VMNAME"
  fi
done

echo
echo "== [2/7] BRIŠEM volumene =="
for vmline in "${VM_LIST[@]}"; do
  IFS='|' read -r VMNAME PRJ <<< "$vmline"
  source /etc/kolla/${PRJ}-openrc.sh
  for i in 1 2; do
    VOLNAME="${VMNAME}-data-${i}"
    if openstack volume show "$VOLNAME" &>/dev/null; then
      echo "----> Brišem volume: $VOLNAME ($PRJ)"
      openstack volume delete --force "$VOLNAME"
    else
      echo "----> Volume ne postoji: $VOLNAME"
    fi
  done
done

echo
echo "== [3/7] BRIŠEM portove (preostale/orphan) =="
source "$RC_ADMIN"
for NET in "${NETWORKS[@]}"; do
  for PORTID in $(openstack port list --network "$NET" -f value -c ID); do
    echo "----> Brišem port: $PORTID sa mreže $NET"
    openstack port delete "$PORTID"
  done
done

echo
echo "== [4/7] BRIŠEM floating IP-ove =="
source "$RC_ADMIN"
for FIP in $(openstack floating ip list --tag "course=test" -f value -c "Floating IP Address"); do
  echo "----> Brišem floating IP: $FIP"
  openstack floating ip delete "$FIP"
done

echo
echo "== [5/7] BRIŠEM rutere, subnetove i mreže =="
for NET in "${NETWORKS[@]}"; do
  PRJ=$(echo $NET | cut -d'-' -f1-2)
  ROUTERNAME="$NET-router"
  SUBNETNAME="$NET-subnet"
  source /etc/kolla/${PRJ}-openrc.sh

  if openstack router show "$ROUTERNAME" &>/dev/null; then
    if openstack subnet show "$SUBNETNAME" &>/dev/null; then
      echo "----> Uklanjam subnet $SUBNETNAME s rutera $ROUTERNAME"
      openstack router remove subnet "$ROUTERNAME" "$SUBNETNAME" || true
    fi
    echo "----> Brišem ruter: $ROUTERNAME"
    openstack router delete "$ROUTERNAME"
  fi

  if openstack subnet show "$SUBNETNAME" &>/dev/null; then
    echo "----> Brišem subnet: $SUBNETNAME"
    openstack subnet delete "$SUBNETNAME"
  fi

  # FORCE brisanje svih preostalih portova na mreži prije brisanja mreže
  for PORTID in $(openstack port list --network "$NET" -f value -c ID); do
    echo "----> Force brišem port: $PORTID sa mreže $NET"
    openstack port delete "$PORTID"
  done

  if openstack network show "$NET" &>/dev/null; then
    echo "----> Brišem mrežu: $NET"
    openstack network delete "$NET"
  fi
done

echo
echo "== [6/7] BRIŠEM security grupe =="
for PRJ in "${PROJECTS[@]}"; do
  for SG in "${SECURITY_GROUPS[@]}"; do
    source /etc/kolla/${PRJ}-openrc.sh
    if openstack security group show "$SG" &>/dev/null; then
      echo "----> Brišem security group: $SG ($PRJ)"
      openstack security group delete "$SG"
    fi
  done
done

echo
echo "== [7/7] (Opcionalno) BRIŠEM projekte (zaštita) =="
for PRJ in "${PROJECTS[@]}"; do
  # echo "----> Brišem projekt: $PRJ"
  # openstack project delete "$PRJ"
  echo "----> (Zaštita) Projekt $PRJ preskačem – obriši ručno kad budeš siguran!"
done

echo
echo "== CLEANUP GOTOV =="
