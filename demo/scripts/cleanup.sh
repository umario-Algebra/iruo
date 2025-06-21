#!/bin/bash
set -e

RC_FILE="/etc/kolla/demo-openrc.sh"
if [[ -f "$RC_FILE" ]]; then
    source "$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

CSV_FILE="demo-users.csv" # ili putanja do tvoje csv datoteke

echo "== 1. Brišem floating IP-ove =="
floating_ips=(192.168.10.101 192.168.10.102 192.168.10.103 192.168.10.104)
for fip in "${floating_ips[@]}"; do
    if openstack floating ip show "$fip" &>/dev/null; then
        echo "Brišem floating IP: $fip"
        openstack floating ip delete "$fip"
    fi
done

echo "== 2. Brišem VM-ove =="
vms=(
    demo-vm-minio
    demo-vm-test1.instr
    demo-vm-test2.stud-jumphost
    demo-vm-test2.stud-wp1
    demo-vm-test2.stud-wp2
    demo-vm-test3.stud-jumphost
    demo-vm-test3.stud-wp1
    demo-vm-test3.stud-wp2
    lb-test2
    lb-test3
)
for vm in "${vms[@]}"; do
    if openstack server show "$vm" &>/dev/null; then
        echo "Brišem VM: $vm"
        openstack server delete "$vm"
    fi
done

echo "== 3. Brišem dodatne diskove (volumes) =="
for vm in demo-vm-test2.stud-wp1 demo-vm-test2.stud-wp2 demo-vm-test3.stud-wp1 demo-vm-test3.stud-wp2; do
    vol="${vm}-2"
    if openstack volume show "$vol" &>/dev/null; then
        echo "Brišem disk: $vol"
        openstack volume delete "$vol"
    fi
done

echo "== 4. Brišem rutere i interfejse =="
routers=(
    demo-router-test1
    demo-router-test2
    demo-router-test3
    demo-router-minio
)
for router in "${routers[@]}"; do
    if openstack router show "$router" &>/dev/null; then
        echo "Mičem subnete s routera $router"
        for net in demo-net-test1 demo-net-test2 demo-net-test3 demo-net-minio; do
            subnet="${net}-subnet"
            if openstack subnet show "$subnet" &>/dev/null; then
                openstack router remove subnet "$router" "$subnet" || true
            fi
        done
        echo "Brišem router: $router"
        openstack router delete "$router"
    fi
done

echo "== 5. Brišem subnete =="
subnets=(
    demo-net-test1-subnet
    demo-net-test2-subnet
    demo-net-test3-subnet
    demo-net-minio-subnet
)
for subnet in "${subnets[@]}"; do
    if openstack subnet show "$subnet" &>/dev/null; then
        echo "Brišem subnet: $subnet"
        openstack subnet delete "$subnet" || true
    fi
done

echo "== 6. Brišem mreže =="
networks=(
    demo-net-test1
    demo-net-test2
    demo-net-test3
    demo-net-minio
)
for net in "${networks[@]}"; do
    if openstack network show "$net" &>/dev/null; then
        echo "Brišem mrežu: $net"
        openstack network delete "$net" || true
    fi
done

echo "== 7. Brišem korisnike iz CSV-a =="
if [[ -f "$CSV_FILE" ]]; then
    tail -n +2 "$CSV_FILE" | while IFS=';' read -r ime prezime rola; do
        USERNAME="${ime}.${prezime}"
        if openstack user show "$USERNAME" &>/dev/null; then
            echo "Brišem korisnika: $USERNAME"
            openstack user delete "$USERNAME"
        fi
    done
else
    echo "CSV datoteka $CSV_FILE ne postoji! Preskačem korisnike."
fi

echo "== Clean up gotovo! Sve resurse iz deploy skripte smo maknuli =="
