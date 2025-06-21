#!/bin/bash
set -e

RC_FILE="/etc/kolla/demo-openrc.sh"
if [[ -f "$RC_FILE" ]]; then
    source "$RC_FILE"
else
    echo "Nema $RC_FILE!"
    exit 1
fi

# VM-ovi
for VM in demo-vm-minio lb-test2 lb-test3; do
    if openstack server show "$VM" &>/dev/null; then
        echo "Brišem VM: $VM"
        openstack server delete "$VM"
    else
        echo "VM $VM ne postoji."
    fi
done

# Čekaj da se VM-ovi obrišu
sleep 5

# Floating IP
MINIO_FIP="192.168.10.101"
if openstack floating ip show "$MINIO_FIP" &>/dev/null; then
    echo "Brišem floating IP: $MINIO_FIP"
    openstack floating ip delete "$MINIO_FIP"
fi

# Routeri i subneti
for net in demo-net-test1 demo-net-test2 demo-net-test3 demo-net-minio; do
    subnet="${net}-subnet"
    router="demo-router-${net#demo-net-}"

    # Skini subnet s routera (ako postoji)
    if openstack router show "$router" &>/dev/null && openstack subnet show "$subnet" &>/dev/null; then
        echo "Uklanjam subnet $subnet s routera $router"
        openstack router remove subnet "$router" "$subnet" || true
    fi
done

# Briši routere
for net in demo-net-test1 demo-net-test2 demo-net-test3 demo-net-minio; do
    router="demo-router-${net#demo-net-}"
    if openstack router show "$router" &>/dev/null; then
        echo "Brišem router: $router"
        openstack router delete "$router"
    fi
done

# Briši subnet-e
for net in demo-net-test1 demo-net-test2 demo-net-test3 demo-net-minio; do
    subnet="${net}-subnet"
    if openstack subnet show "$subnet" &>/dev/null; then
        echo "Brišem subnet: $subnet"
        openstack subnet delete "$subnet"
    fi
done

# Briši mreže
for net in demo-net-test1 demo-net-test2 demo-net-test3 demo-net-minio; do
    if openstack network show "$net" &>/dev/null; then
        echo "Brišem mrežu: $net"
        openstack network delete "$net"
    fi
done

# Obriši keypair AKO želiš (ODKOMENTIRAJ AKO TREBA)
# if openstack keypair show demo-key &>/dev/null; then
#     echo "Brišem keypair demo-key"
#     openstack keypair delete demo-key
# fi

echo "== SVE OBRISANO! =="

