#!/bin/bash
set -e

# Učitaj OpenStack credentials
if [[ -f "$(dirname "$0")/demo-openrc.sh" ]]; then
    source "$(dirname "$0")/demo-openrc.sh"
else
    echo "Nema demo-openrc.sh! Kopiraj svoj OpenStack rc file u scripts folder."
    exit 1
fi

PROJECT_NAME="demo"

# Provjeri postoji li projekt
project_id=$(openstack project list -f value -c ID -c Name | grep " $PROJECT_NAME$" | awk '{print $1}')

if [ -z "$project_id" ]; then
    echo "Projekt $PROJECT_NAME ne postoji. Kreiram..."
    openstack project create "$PROJECT_NAME" --description "Demo projekt za IROU"
    echo "Projekt $PROJECT_NAME kreiran."
else
    echo "Projekt $PROJECT_NAME već postoji (ID: $project_id)."
fi

# Dodaj sebe kao admina u projekt (pretpostavljam da si već ulogiran user)
USER_ID=$(openstack user show $OS_USERNAME -f value -c id)
ROLE_ID=$(openstack role list -f value -c ID -c Name | grep " admin$" | awk '{print $1}')
project_id=$(openstack project show "$PROJECT_NAME" -f value -c id)

# Provjeri imaš li već admin rolu
if openstack role assignment list --user "$USER_ID" --project "$project_id" --role "$ROLE_ID" | grep "$USER_ID" > /dev/null; then
    echo "Već imaš admin prava na projektu $PROJECT_NAME."
else
    echo "Dodajem admin prava..."
    openstack role add --user "$USER_ID" --project "$project_id" "$ROLE_ID"
    echo "Admin prava dodana."
fi

echo "Gotovo."
