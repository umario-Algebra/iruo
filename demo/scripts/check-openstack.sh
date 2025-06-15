#!/bin/bash

echo "Provjera OpenStack okruženja..."

# Provjera da openstack CLI postoji
if ! command -v openstack &> /dev/null; then
    echo "Greška: 'openstack' CLI nije pronađen."
    exit 1
fi

# Provjera autentikacije
echo "Testiranje autentikacije..."
if ! openstack token issue &> /dev/null; then
    echo "Greška: Neuspješna autentikacija. Provjeri RC datoteku ili environment varijable."
    exit 2
fi

echo "Autentikacija uspješna."

# Lista dostupnih projekata
echo "Popis dostupnih projekata:"
openstack project list

# Lista dostupnih servisa
echo "Popis aktivnih servisa:"
openstack service list

echo "OpenStack CLI funkcionalan."
