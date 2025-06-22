#!/bin/bash
set -e

RC_FILE="/etc/kolla/demo-openrc.sh"
if [[ -f "$RC_FILE" ]]; then
    source "$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

echo "== CLEANUP KRENI =="

PROJEKTI=(instruktor student1 student2)
MREZE=(instruktor-net student1-net student2-net minio-net)
ROUTERI=(instruktor-net-router student1-net-router student2-net-router minio-net-router)
SECGRPS=(instruktor-secgroup student-secgroup-student1 student-secgroup-student2)
FLOATIPS=(192.168.10.122 192.168.10.123 192.168.10.124)

echo "== 1. Brišem VM-ove =="
for vm in instruktor minio \
    student1-jumphost student1-lb student1-wp1 student1-wp2 \
    student2-jumphost student2-lb student2-wp1 student2-wp2; do
    if openstack server show $vm &>/dev/null; then
        echo "Brišem VM: $vm"
        openstack server delete $vm || true
    fi
done

echo "== 2. Brišem volumene =="
for vm in student1-wp1 student1-wp2 student2-wp1 student2-wp2; do
    for i in 1 2; do
        vol="${vm}-data-$i"
        if openstack volume show "$vol" &>/dev/null; then
            echo "Brišem volume: $vol"
            openstack volume delete "$vol" || true
        fi
    done
done

echo "== 3. Brišem floating IP-e =="
for fip in "${FLOATIPS[@]}"; do
    if openstack floating ip show "$fip" &>/dev/null; then
        echo "Brišem FIP: $fip"
        openstack floating ip delete "$fip" || true
    fi
done

echo "== 4. Brišem portove (ručno, preostali orphan portovi) =="
for net in "${MREZE[@]}"; do
    openstack port list --network "$net" -f value -c ID | while read portid; do
        echo "  Brišem port: $portid"
        openstack port delete "$portid" || true
    done
done

echo "== 5. Brišem rutere =="
for router in "${ROUTERI[@]}"; do
    if openstack router show "$router" &>/dev/null; then
        echo "Brišem router: $router"
        # Skini sve subnetove sa routera
        openstack router show "$router" -f json | jq -r '.interfaces_info[].subnet_id' | while read sid; do
            echo "  Skidam subnet $sid s routera $router"
            openstack router remove subnet "$router" "$sid" || true
        done
        openstack router unset --external-gateway "$router" || true
        openstack router delete "$router" || true
    fi
done

echo "== 6. Brišem subnetove i mreže =="
for net in "${MREZE[@]}"; do
    subnet="${net}-subnet"
    if openstack subnet show "$subnet" &>/dev/null; then
        echo "Brišem subnet: $subnet"
        openstack subnet delete "$subnet" || true
    fi
    if openstack network show "$net" &>/dev/null; then
        echo "Brišem mrežu: $net"
        openstack network delete "$net" || true
    fi
done

echo "== 7. Brišem security grupe =="
for sg in "${SECGRPS[@]}"; do
    if openstack security group show "$sg" &>/dev/null; then
        echo "Brišem security group: $sg"
        openstack security group delete "$sg" || true
    fi
done

echo "== 8. Brišem korisnike =="
if [[ -f "osobe.csv" ]]; then
    tail -n +2 "osobe.csv" | while IFS=';' read -r ime prezime rola; do
        USERNAME="${ime}.${prezime}"
        if openstack user show "$USERNAME" &>/dev/null; then
            echo "Brišem korisnika: $USERNAME"
            openstack user delete "$USERNAME" || true
        fi
    done
fi

echo "== 9. Brišem grupe =="
for g in studenti instruktori; do
    if openstack group show "$g" &>/dev/null; then
        echo "Brišem grupu: $g"
        openstack group delete "$g" || true
    fi
done

echo "== 10. Brišem projekte =="
for p in "${PROJEKTI[@]}"; do
    if openstack project show "$p" &>/dev/null; then
        echo "Brišem projekt: $p"
        openstack project delete "$p" || true
    fi
done

echo "== CLEANUP ZAVRŠEN =="
