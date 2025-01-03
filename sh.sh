#!/bin/bash

DIRECTORY="/home/pi/raspberry-noaa"

for file in $(find $DIRECTORY -type f)
do
  if [[ $(basename $file) == *.sh || $(basename $file) == *.py ]]; then
    chmod 755 $file
  fi
done
wget -qO - https://raw.githubusercontent.com/tvdsluijs/sh-python-installer/main/python.sh | sudo bash -s 3.11.0

./install.sh
