#!/bin/bash

## Setup locale
echo "en_US.UTF-8 UTF-8" >>/etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" >/etc/locale.conf

## Setup time and date
ln -sf /usr/share/zoneinfo/Asia/Manila /etc/localtime
hwclock --systohc
