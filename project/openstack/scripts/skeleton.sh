#!/bin/bash
set -e

EXT_NET="public"
KEYPAIR="labkey"
FLAVOR="m1.medium"
TAG="course=test"
CSV_FILE="osobe.csv"
PASSWORD="TestPSW80!"

declare -a PROJECTS=("instruktor-projekt" "student1-projekt" "student2-projekt")

declare -A USER2PROJECT=(
  ["pero.peric"]="student1-projekt"
  ["iva.ivic"]="student2-projekt"
  ["mario.maric"]="instruktor-projekt"
)

declare -A NETWORKS=(
  [instruktor-projekt-instruktor-net]="10.20.0.0/24"
  [instruktor-projekt-instruktor-minio-net]="10.50.0.0/24"
  [student1-projekt-student1-net]="10.30.0.0/24"
  [student2-projekt-student2-net]="10.40.0.0/24"
)

echo
echo "== [1/6] KREIRANJE PROJEKATA =="
for PRJ in "${PROJECTS[@]}"; do
    echo "--> Provjeravam projekt: $PRJ"
    if ! openstack project show "$PRJ" &>/dev/null; then
        echo "----> Kreiram projekt: $PRJ"
        openstack project create "$PRJ"
    else
        echo "----> Projekt već postoji: $PRJ"
    fi
done

echo
echo "== [2/6] KREIRANJE GRUPA =="
if ! openstack group show studenti &>/dev/null; then
    openstack group create studenti --description "Svi studenti"
fi
if ! openstack group show instruktori &>/dev/null; then
    openstack group create instruktori --description "Svi instruktori"
fi

echo
echo "== [3/6] KREIRANJE KORISNIKA, ROLA I GRUPA IZ CSV-a =="
tail -n +2 "$CSV_FILE" | while IFS=';' read -r ime prezime rola; do
    USERNAME="${ime}.${prezime}"
    EMAIL="${USERNAME}@cloudlearn.local"
    PRJ="${USER2PROJECT[$USERNAME]}"
    echo "--> Provjeravam korisnika $USERNAME ($rola) u projektu $PRJ"
    if ! openstack user show "$USERNAME" &>/dev/null; then
        echo "----> Kreiram usera $USERNAME"
        openstack user create --project "$PRJ" --password "$PASSWORD" --email "$EMAIL" "$USERNAME"
    else
        echo "----> Korisnik $USERNAME već postoji"
    fi
    echo "----> Dodajem admin rolu u projekt $PRJ korisniku $USERNAME"
    openstack role add --project "$PRJ" --user "$USERNAME" admin
    if [[ "$rola" == "instruktor" ]]; then
        echo "----> Dodajem korisnika $USERNAME u grupu instruktori"
        openstack group add user instruktori "$USERNAME"
        # Mario (instruktor) je admin na svim projektima!
        for PRJX in "${PROJECTS[@]}"; do
            openstack role add --project "$PRJX" --user "$USERNAME" admin
        done
    else
        echo "----> Dodajem korisnika $USERNAME u grupu studenti"
        openstack group add user studenti "$USERNAME"
    fi
done

echo
echo "== [4/6] DODJELA ADMINA NA SVE PROJEKTE (KORISNIK admin) =="
for PRJ in "${PROJECTS[@]}"; do
    if ! openstack role assignment list --user admin --project "$PRJ" --role admin -f value | grep -q .; then
        echo "----> Dodajem admin rolu za admin na projekt $PRJ"
        openstack role add --user admin --project "$PRJ" admin
    else
        echo "----> Admin već ima admin rolu na projektu $PRJ"
    fi
done

echo
echo "== [5/6] KREIRANJE MREŽA, SUBNETOVA I ROUTERA =="
for K in "${!NETWORKS[@]}"; do
    PRJ=$(echo $K | cut -d'-' -f1-2)
    NET=$(echo $K | cut -d'-' -f3-)
    NETNAME="$PRJ-$NET"
    SUBNETNAME="$NETNAME-subnet"
    ROUTERNAME="$NETNAME-router"
    CIDR="${NETWORKS[$K]}"

    echo "--> Provjeravam mrežu: $NETNAME ($CIDR) u projektu $PRJ"
    if ! openstack network show "$NETNAME" &>/dev/null; then
        echo "----> Kreiram mrežu: $NETNAME"
        openstack network create --project "$PRJ" --tag "$TAG" "$NETNAME"
    else
        echo "----> Mreža već postoji: $NETNAME"
    fi

    echo "    -> Provjeravam subnet: $SUBNETNAME"
    if ! openstack subnet show "$SUBNETNAME" &>/dev/null; then
        echo "    ---> Kreiram subnet: $SUBNETNAME"
        openstack subnet create --project "$PRJ" --network "$NETNAME" --subnet-range "$CIDR" --tag "$TAG" "$SUBNETNAME"
    else
        echo "    ---> Subnet već postoji: $SUBNETNAME"
    fi

    echo "    -> Provjeravam router: $ROUTERNAME"
    if ! openstack router show "$ROUTERNAME" &>/dev/null; then
        echo "    ---> Kreiram router: $ROUTERNAME"
        openstack router create --project "$PRJ" "$ROUTERNAME"
        openstack router set --external-gateway "$EXT_NET" "$ROUTERNAME"
    else
        echo "    ---> Router već postoji: $ROUTERNAME"
    fi

    # Robustna provjera veze subnet-router (provjerava preko subnet ID-a)
    echo "    -> Provjeravam vezu subnet-router: $SUBNETNAME <-> $ROUTERNAME"
    SUBNET_ID=$(openstack subnet show "$SUBNETNAME" -f value -c id)
    ROUTER_ID=$(openstack router show "$ROUTERNAME" -f value -c id)
    ROUTER_PORT=$(openstack port list --device-owner network:router_interface --device-id $ROUTER_ID --fixed-ip subnet=$SUBNET_ID -f value -c id)

    if [[ -z "$ROUTER_PORT" ]]; then
        echo "    ---> Dodajem subnet $SUBNETNAME na router $ROUTERNAME"
        openstack router add subnet "$ROUTERNAME" "$SUBNETNAME"
    else
        echo "    ---> Subnet $SUBNETNAME je već spojen na router $ROUTERNAME"
    fi
done

echo
echo "== [6/6] GOTOVO =="
echo "Svi projekti, korisnici, grupe, role, mreže i routeri su spremni."
