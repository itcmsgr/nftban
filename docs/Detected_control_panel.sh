#!/bin/bash

echo "Checking for running control panel..."

if [ -d "/usr/local/directadmin/" ]; then
  echo "DirectAdmin detected."
elif [ -d "/var/cpanel/" ]; then
  echo "cPanel detected."
elif [ -d "/usr/local/psa/" ]; then
  echo "Plesk detected."
else
  echo "No common control panel (DirectAdmin, cPanel, Plesk) detected."
fi
