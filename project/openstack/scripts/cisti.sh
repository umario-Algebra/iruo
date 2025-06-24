#!/bin/bash
set -e

CSV_FILE="osobe.csv"
RC_DIR="/etc/kolla"
KEYPAIR_SUFFIX="-key"

declare -A USERS PROJECTS ROLES

echo "== [1/7] Učitavam korisnike iz $CSV_FILE =="
while IFS=';' read -r ime prezime rola; do
    [[ -z "$ime" || -z "$prezime" || -z "$rola" ]] && continue
    USERNAME="${ime}.${prezime}"
    PROJECT="${ime}-${prezime}-projekt"
    USERS["$USERNAME"]="$PROJECT"
    PROJECTS["$PROJECT"]=1
    ROLES["$USERNAME"]="$rola"
done < <(tail -n +2 "$CSV_FILE")

echo
echo "== [2/7] Brišem VM-ove =="
for USERNAME in "${!USERS[@]}"; do
    PROJECT="${USERS[$USERNAME]}"
    RC_FILE="${RC_DIR}/${USERNAME}-openrc.sh"
    if [ -f "$RC_FILE" ]; then source "$RC_FILE"; fi
    for VM in $(openstack server list -f value -c Name); do
        echo "----> Brišem VM: $VM ($PROJECT)"
        openstack server delete "$VM" || true
    done
done

echo
echo "== [3/7] Brišem volumene =="
for USERNAME in "${!USERS[@]}"; do
    PROJECT="${USERS[$USERNAME]}"
    RC_FILE="${RC_DIR}/${USERNAME}-openrc.sh"
    if [ -f "$RC_FILE" ]; then source "$RC_FILE"; fi
    for VOL in $(openstack volume list -f value -c Name); do
        echo "----> Brišem volume: $VOL ($PROJECT)"
        openstack volume delete --force "$VOL" || true
    done
done

echo
echo "== [4/7] Brišem keypair-e i lokalne PEM fajlove =="
for USERNAME in "${!USERS[@]}"; do
    RC_FILE="${RC_DIR}/${USERNAME}-openrc.sh"
    KEYPAIRNAME="${USERNAME}${KEYPAIR_SUFFIX}"
    if [ -f "$RC_FILE" ]; then source "$RC_FILE"; fi
    if openstack keypair show "$KEYPAIRNAME" &>/dev/null; then
        echo "----> Brišem keypair: $KEYPAIRNAME"
        openstack keypair delete "$KEYPAIRNAME"
    fi
    PEM="${RC_DIR}/${KEYPAIRNAME}.pem"
    if [ -f "$PEM" ]; then
        rm -f "$PEM"
        echo "----> Brišem PEM file: $PEM"
    fi
done

echo
echo "== [5/7] Brišem mreže, subnetove, rutere =="
for USERNAME in "${!USERS[@]}"; do
    PROJECT="${USERS[$USERNAME]}"
    RC_FILE="${RC_DIR}/${USERNAME}-openrc.sh"
    if [ -f "$RC_FILE" ]; then source "$RC_FILE"; fi
    NETNAME="${PROJECT}-net"
    SUBNETNAME="${NETNAME}-subnet"
    ROUTERNAME="${NETNAME}-router"

    # Ukloni subnet iz rutera prije brisanja rutera/subneta
    if openstack router show "$ROUTERNAME" &>/dev/null; then
        if openstack subnet show "$SUBNETNAME" &>/dev/null; then
            echo "----> Uklanjam subnet $SUBNETNAME iz rutera $ROUTERNAME"
            openstack router remove subnet "$ROUTERNAME" "$SUBNETNAME" || true
        fi
        echo "----> Brišem ruter: $ROUTERNAME"
        openstack router delete "$ROUTERNAME" || true
    fi

    if openstack subnet show "$SUBNETNAME" &>/dev/null; then
        echo "----> Brišem subnet: $SUBNETNAME"
        openstack subnet delete "$SUBNETNAME" || true
    fi

    # Ukloni sve portove s mreže prije brisanja mreže
    for PORTID in $(openstack port list --network "$NETNAME" -f value -c ID); do
        echo "----> Brišem port: $PORTID sa mreže $NETNAME"
        openstack port delete "$PORTID" || true
    done

    if openstack network show "$NETNAME" &>/dev/null; then
        echo "----> Brišem mrežu: $NETNAME"
        openstack network delete "$NETNAME" || true
    fi
done

echo
echo "== [6/7] Brišem korisnike i projekte =="
for USERNAME in "${!USERS[@]}"; do
    PROJECT="${USERS[$USERNAME]}"
    if openstack user show "$USERNAME" &>/dev/null; then
        echo "----> Brišem korisnika: $USERNAME"
        openstack user delete "$USERNAME" || true
    fi
    if openstack project show "$PROJECT" &>/dev/null; then
        echo "----> Brišem projekt: $PROJECT"
        openstack project delete "$PROJECT" || true
    fi
done

echo
echo "== [7/7] Brišem RC fileove =="
for USERNAME in "${!USERS[@]}"; do
    RC_FILE="${RC_DIR}/${USERNAME}-openrc.sh"
    if [ -f "$RC_FILE" ]; then
        echo "----> Brišem RC file: $RC_FILE"
        rm -f "$RC_FILE"
    fi
done

echo
echo "== CLEANUP ZAVRŠEN =="
