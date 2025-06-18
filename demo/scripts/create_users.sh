#!/bin/bash
set -e

RC_FILE="${1:-demo-openrc.sh}"
if [[ -f "$(dirname "$0")/$RC_FILE" ]]; then
    source "$(dirname "$0")/$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

CSV_FILE="${2:-users.csv}"
if [[ ! -f "$(dirname "$0")/$CSV_FILE" ]]; then
    echo "Nema CSV datoteke $CSV_FILE!"
    exit 1
fi

PROJECT_NAME="demo"

# Dohvati ID projekta
PROJECT_ID=$(openstack project show $PROJECT_NAME -f value -c id)

# Pronađi role u sustavu
ROLE_ADMIN=$(openstack role list -f value -c ID -c Name | grep ' admin$' | awk '{print $1}')
ROLE_MEMBER=$(openstack role list -f value -c ID -c Name | grep ' member$' | awk '{print $1}')

# Password za sve korisnike (u pravoj okolini radi custom generiranje!)
DEFAULT_PASS="Password123!"

echo "Kreiram korisnike iz $CSV_FILE u projekt $PROJECT_NAME ..."

tail -n +2 "$CSV_FILE" | while IFS=";" read ime prezime rola; do
    USERNAME="${ime,,}.${prezime,,}"  # mala slova i točka kao separator
    echo "Obrađujem: $USERNAME ($rola)"

    # Provjeri postoji li korisnik
    if openstack user show "$USERNAME" &>/dev/null; then
        echo "  - Korisnik $USERNAME već postoji, preskačem kreiranje."
    else
        openstack user create --project "$PROJECT_NAME" --password "$DEFAULT_PASS" "$USERNAME"
        echo "  - Korisnik $USERNAME kreiran."
    fi

    # Dodjela role prema roli iz CSV-a
    case "$rola" in
        instruktor)
            openstack role add --user "$USERNAME" --project "$PROJECT_NAME" "$ROLE_ADMIN"
            echo "  - Dodijeljena rola: admin"
            ;;
        student)
            openstack role add --user "$USERNAME" --project "$PROJECT_NAME" "$ROLE_MEMBER"
            echo "  - Dodijeljena rola: member"
            ;;
        *)
            echo "  - Nepoznata rola '$rola' za korisnika $USERNAME! Skipping."
            ;;
    esac
done

echo "Gotovo!"
