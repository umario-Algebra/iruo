#!/bin/bash

CSV_FILE="$1"

tail -n +2 "$CSV_FILE" | while IFS=';' read -r ime prezime rola; do
  USERNAME="${ime}.${prezime}"
  EMAIL="${USERNAME}@cloudlearn.local"
  PASSWORD="TestPSW80!"

  if ! openstack user show "$USERNAME" &>/dev/null; then
    openstack user create --project demo --password "$PASSWORD" --email "$EMAIL" "$USERNAME"
  fi

  if [[ "$rola" == "instruktor" ]]; then
    openstack role add --project demo --user "$USERNAME" admin
  else
    openstack role add --project demo --user "$USERNAME" member
  fi
done
