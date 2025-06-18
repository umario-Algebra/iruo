#!/bin/bash
set -e

# Učitaj OpenStack credentials
RC_FILE="${1:-demo-openrc.sh}"
if [[ -f "$(dirname "$0")/$RC_FILE" ]]; then
    source "$(dirname "$0")/$RC_FILE"
else
    echo "Nema $RC_FILE! Kopiraj svoj OpenStack rc file u scripts folder."
    exit 1
fi

PROJECT_NAME="demo"

# Dohvati project_id
project_id=$(openstack project list -f value -c ID -c Name | grep " $PROJECT_NAME$" | awk '{print $1}')

if [ -z "$project_id" ]; then
    echo "Projekt $PROJECT_NAME ne postoji, nema što brisati."
    exit 0
fi

echo "Brišem sve resurse iz projekta $PROJECT_NAME..."

# Briši sve instance (VM-ove)
for server in $(openstack server list --project $project_id -f value -c ID); do
    echo "Brišem VM $server..."
    openstack server delete "$server"
done

# Pričekaj da se svi serveri obrišu
while openstack server list --project $project_id -f value -c ID | grep .; do
    echo "Čekam na brisanje VM-ova..."
    sleep 5
done

# Briši volume
for volume in $(openstack volume list --project $project_id -f value -c ID); do
    echo "Brišem volume $volume..."
    openstack volume delete "$volume"
done

# Briši floating IP adrese
for fip in $(openstack floating ip list --project $project_id -f value -c ID); do
    echo "Brišem floating IP $fip..."
    openstack floating ip delete "$fip"
done

# Briši routere
for router in $(openstack router list --project $project_id -f value -c ID); do
    # Odspoji sve interfejse
    for subnet in $(openstack router show $router -f json | jq -r '.interfaces_info[]?.subnet_id'); do
        echo "Uklanjam subnet $subnet iz routera $router..."
        openstack router remove subnet $router $subnet
    done
    echo "Brišem router $router..."
    openstack router delete "$router"
done

# Briši mreže
for net in $(openstack network list --project $project_id -f value -c ID); do
    echo "Brišem mrežu $net..."
    openstack network delete "$net"
done

# Briši security grupe (osim default)
for secgroup in $(openstack security group list --project $project_id -f value -c ID -c Name | grep -v ' default$' | awk '{print $1}'); do
    echo "Brišem security group $secgroup..."
    openstack security group delete "$secgroup"
done

# Briši korisnike vezane uz projekt (po potrebi - možeš dodatno proširiti!)
# for user in $(openstack user list --project $project_id -f value -c ID); do
#     echo "Brišem korisnika $user..."
#     openstack user delete "$user"
# done

# I na kraju - briši projekt
echo "Brišem projekt $PROJECT_NAME..."
openstack project delete "$PROJECT_NAME"

echo "Svi resursi iz projekta $PROJECT_NAME su obrisani!"
