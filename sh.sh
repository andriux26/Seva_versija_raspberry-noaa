#!/bin/bash

DIRECTORY="/home/pi/raspberry-noaa"

for file in $(find $DIRECTORY -type f)
do
  if [[ $(basename $file) == *.sh || $(basename $file) == *.py ]]; then
    chmod 755 $file
  fi
done

wget -qO - https://packages.sury.org/php/apt.gpg | sudo gpg --dearmor -o /usr/share/keyrings/php-ondrej.gpg

echo "deb [signed-by=/usr/share/keyrings/php-ondrej.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/php-ondrej.list

sudo apt update
sudo apt install -y php7.2 php7.2-fpm




#wget -qO - https://raw.githubusercontent.com/tvdsluijs/sh-python-installer/main/python.sh | sudo bash -s 3.11.0

./install.sh
