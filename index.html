#!/bin/bash

sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#NTP=/NTP=time.google.com/' /etc/systemd/timesyncd.conf

echo "Restarting timesyncd..."
systemctl restart systemd-timesyncd

echo "Updating mirrorlist using relflector..."
reflector -a 48 -c JP -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist

archinstall --config "https;//install.alvinjay.site/user_configuration.json"
