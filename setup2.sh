#!/bin/bash

nc=$(grep -c ^processor /proc/cpuinfo)
TOTAL_MEM=$(cat /proc/meminfo | grep -i 'memtotal' | grep -o '[[:digit:]]*')
if [[ $TOTAL_MEM -gt 8000000 ]]; then
  sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$nc\"/g" /etc/makepkg.conf
  sed -i "s/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -T $nc -z -)/g" /etc/makepkg.conf
fi

# TIMEZONE=Asia/Manila
# KEYMAP=us
#
# sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
# locale-gen
# timedatectl --no-ask-password set-timezone ${TIMEZONE}
# timedatectl --no-ask-password set-ntp 1
# localectl --no-ask-password set-locale LANG="en_US.UTF-8" LC_TIME="en_US.UTF-8"
# ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
# # Set keymaps
# localectl --no-ask-password set-keymap ${KEYMAP}

# Setup locale
echo "en_US.UTF-8 UTF-8" >>/etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" >/etc/locale.conf

# Setup time and date
ln -sf /usr/share/zoneinfo/Asia/Manila /etc/localtime
hwclock --systohc
