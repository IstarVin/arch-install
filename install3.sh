set -e

# Ensure /mnt is unmounted
if lsblk | grep "/mnt$" >/dev/null 2>&1; then
    umount -q -A --recursive /mnt
fi

# Print available disks
lsblk -n --output TYPE,KNAME,SIZE | awk '$1=="disk"{print $2"|"$3}'

# Enter necessary infos
read -r -p "Enter disk name: " disk
read -r -p "Enter username: " username
read -r -p "Enter Full Name: " fullname

while :; do
    read -s -r -p "Enter user password: " password
    echo
    read -s -r -p "Enter user password again: " password2
    echo
    [[ $password != "$password2" ]] || break
    echo "error try again"
done

while :; do
    echo
    read -s -r -p "Enter root password: " rootPassword
    echo
    read -s -r -p "Enter root password: " rootPassword2
    echo
    [[ $rootPassword != "$rootPassword2" ]] || break
    echo "error try again"
done

while :; do
    echo
    read -s -r -p "Enter luks password: " luksPassword
    echo
    read -s -r -p "Enter luks password: " luksPassword2
    echo
    [[ $luksPassword != "$luksPassword2" ]] || break
    echo "error try again"
done

clear

## Setup pacman config
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf

## Configure Mirrors
echo "Updating mirrors using reflector"
reflector -a 48 -c JP -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist

## Setup pacman
pacman-key --init
pacman-key --populate

pacman -Sy archlinux-keyring debugedit --noconfirm

## Add CachyOS Repo
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
pacman -U --noconfirm 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst' \
    'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst' \
    'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-v3-mirrorlist-18-1-any.pkg.tar.zst' \
    'https://mirror.cachyos.org/repo/x86_64/cachyos/pacman-6.1.0-7-x86_64.pkg.tar.zst'

sed -i '/# after the header, and they will be used before the default mirrors./a\
\
#CachyOS Repos\
[cachyos-core-v3]\
Include = /etc/pacman.d/cachyos-v3-mirrorlist\
[cachyos-extra-v3]\
Include = /etc/pacman.d/cachyos-v3-mirrorlist\
[cachyos-v3]\
Include = /etc/pacman.d/cachyos-v3-mirrorlist\
[cachyos]\
Include = /etc/pacman.d/cachyos-mirrorlist' /etc/pacman.conf

pacman -Sy

## Setup disk
device=/dev/${disk}
wipefs --all "${device}"
sgdisk --clear "${device}" --new 1::-512MiB "${device}" --new 2::0 --typecode 2:ef00 "${device}"
sgdisk --change-name=1:primary --change-name=2:ESP "${device}"
part_root=${device}1
part_boot=${device}2
mkfs.vfat -n "EFI" -F 32 "${part_boot}"

## Setuo LUKS
echo -n "${luksPassword}" | cryptsetup luksFormat "${part_root}"
echo -n "${luksPassword}" | cryptsetup luksOpen "${part_root}" root
part_root_install=/dev/mapper/root

mkfs.btrfs -fL btrfs ${part_root_install}
mount ${part_root_install} /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

umount /mnt
mount -o noatime,nodiratime,compress=zstd,subvol=@ ${part_root_install} /mnt
mkdir /mnt/{var,home,.snapshots,boot}
mount -o noatime,nodiratime,compress=zstd,subvol=@var ${part_root_install} /mnt/var
mount -o noatime,nodiratime,compress=zstd,subvol=@home ${part_root_install} /mnt/home
mount -o noatime,nodiratime,compress=zstd,subvol=@snapshots ${part_root_install} /mnt/.snapshots

mount "$part_boot" /mnt/boot

pacstrap /mnt btrfs-progs
# mount ${part_boot} /mnt/boot --mkdir

# Determine intel or amd
ucode=""
if lscpu | grep "Model name:" | grep AMD >/dev/null 2>&1; then
    ucode="amd-ucode"
elif lscpu | grep "Model name:" | grep Intel >/dev/null 2>&1; then
    ucode="intel-ucode"
else
    echo "Unkown CPU"
    exit 1
fi

## Install Arch
pacstrap /mnt iptables-nft mkinitcpio
pacstrap /mnt base linux-cachyos linux-cachyos-headers linux-firmware $ucode base-devel
pacstrap /mnt cachyos-v3-mirrorlist cachyos-mirrorlist
pacstrap /mnt git vim sudo grub efibootmgr networkmanager

## Setup fstab
genfstab -U /mnt >>/mnt/etc/fstab

## Copy post install to new root
cp /etc/pacman.conf /mnt/etc/pacman.conf -f

## Setup users and password
useradd -m -R /mnt "$username"
usermod -R /mnt -c "$fullname" "$username"
echo -n "${username}:${password}" | chpasswd -R /mnt
echo -n "root:${rootPassword}" | chpasswd -R /mnt
echo "${username} ALL=(ALL) ALL" >/mnt/etc/sudoers.d/00_"${username}"

# Setup Systemd-boot
arch-chroot /mnt bootctl install

cat <<EOF >/mnt/boot/loader/loader.conf
default  arch.conf
timeout  0
console-mode max
editor   no
EOF

device_uuid=$(blkid | grep "${part_root}" | grep -oP ' UUID="\K[\w\d-]+')

cat <<EOF >/mnt/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux-cachyos
initrd  /initramfs-linux-cachyos.img
options cryptdevice=UUID=$device_uuid:root root=/dev/mapper/root quiet rw
EOF

# Setup mkinitcpio
sed -i '/^HOOKS/s/block/& encrypt/' /etc/mkinitcpio.conf
mkinitcpio -p

# Proceed to setup
arch-chroot /mnt bash <(curl -s https://install.alvinjay.site/setup2.sh)
