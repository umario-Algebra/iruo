#!/bin/bash
set -e

# Projekt u kojem želiš kreirati volume
PROJECT="instruktor-projekt"
VOLUME1="minio-vm-data-1"
VOLUME2="minio-vm-data-2"
SIZE=1  # 1GB testno

# Učitaj RC file za projekt
source /etc/kolla/${PROJECT}-openrc.sh

echo "Kreiram volume $VOLUME1 u projektu $PROJECT"
if ! openstack volume show "$VOLUME1" &>/dev/null; then
    openstack volume create --size $SIZE "$VOLUME1"
else
    echo "$VOLUME1 već postoji"
fi

echo "Kreiram volume $VOLUME2 u projektu $PROJECT"
if ! openstack volume show "$VOLUME2" &>/dev/null; then
    openstack volume create --size $SIZE "$VOLUME2"
else
    echo "$VOLUME2 već postoji"
fi

echo "Gotovo!"
