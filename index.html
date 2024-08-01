#!/bin/bash

sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /etc/pacman.conf
sed -i 's/^#NTP=/NTP=time.google.com/' /etc/systemd/timesyncd.conf

systemctl restart systemd-timesyncd

reflector -a 48 -c JP -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist

archinstall
