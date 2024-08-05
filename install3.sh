set -e

# Ensure /mnt is unmounted
if lsblk | grep /mnt >/dev/null 2>&1; then
    umount -q -A --recursive /mnt
fi

# Print available disks
lsblk -n --output TYPE,KNAME,SIZE | awk '$1=="disk"{print $2"|"$3}'

# Enter necessary infos
read -p "Enter disk name: " disk
read -p "Enter username: " username
read -p "Enter Full Name: " fullname

while :; do
    read -s -p "Enter user password: " password
    echo
    read -s -p "Enter user password again: " password2
    echo
    [[ $password != $password2 ]] || break
    echo "error try again"
done

while :; do
    echo
    read -s -p "Enter root password: " rootPassword
    echo
    read -s -p "Enter root password: " rootPassword2
    echo
    [[ $rootPassword != $rootPassword2 ]] || break
    echo "error try again"
done

while :; do
    echo
    read -s -p "Enter root password: " luksPassword
    echo
    read -s -p "Enter root password: " luksPassword2
    echo
    [[ $luksPassword != $luksPassword2 ]] || break
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

## Add CachyOS Repo
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
pacman -U 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst' \
    'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst' \
    'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-v3-mirrorlist-18-1-any.pkg.tar.zst' \
    'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-v4-mirrorlist-6-1-any.pkg.tar.zst' \
    'https://mirror.cachyos.org/repo/x86_64/cachyos/pacman-6.1.0-7-x86_64.pkg.tar.zst'

sed -i '/# after the header, and they will be used before the default mirrors./a\
\
#CachyOS Repos\
[cachyos-v3]\
Include = /etc/pacman.d/cachyos-v3-mirrorlist\
[cachyos-core-v3]\
Include = /etc/pacman.d/cachyos-v3-mirrorlist\
[cachyos-extra-v3]\
Include = /etc/pacman.d/cachyos-v3-mirrorlist\
[cachyos]\
Include = /etc/pacman.d/cachyos-mirrorlist' /etc/pacman.conf

## Setup disk
device=/dev/${disk}
wipefs --all ${device}
sgdisk --clear "${device}" --new 1::-512MiB "${device}" --new 2::0 --typecode 2:ef00 "${device}"
sgdisk --change-name=1:primary --change-name=2:ESP "${device}"
part_root=${device}1
part_boot=${device}2
mkfs.vfat -n "EFI" -F 32 "${part_boot}"

## Setuo LUKS
echo -n ${luksPassword} | cryptsetup luksFormat --pbkdf pbkdf2 "${part_root}"
echo -n ${luksPassword} | cryptsetup luksOpen "${part_root}" root
part_root_install=/dev/mapper/root

mkfs.btrfs -fL btrfs ${part_root_install}
mount ${part_root_install} /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

umount /mnt
mount -o noatime,nodiratime,compress=zstd,subvol=@ ${part_root_install} /mnt
mkdir /mnt/{var,home,.snapshots}
mount -o noatime,nodiratime,compress=zstd,subvol=@var ${part_root_install} /mnt/var
mount -o noatime,nodiratime,compress=zstd,subvol=@home ${part_root_install} /mnt/home
mount -o noatime,nodiratime,compress=zstd,subvol=@snapshots ${part_root_install} /mnt/.snapshots

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
pacstrap /mnt iptables-nft
pacstrap /mnt base linux-cachyos linux-cachyos-headers linux-firmware git vim neovim sudo grub efibootmgr networkmanager $ucode base-devel

## Setup fstab
genfstab -L /mnt >>/mnt/etc/fstab

## Copy post install to new root
cp /etc/pacman.conf /mnt/etc/pacman.conf -f

## Setup users and password
useradd -m -R /mnt ${username}
usermod -R /mnt -c "$fullname" ${username}
echo -n "${username}:${password}" | chpasswd -R /mnt
echo -n "root:${rootPassword}" | chpasswd -R /mnt
echo "${username} ALL=(ALL) ALL" >/mnt/etc/sudoers.d/00_${username}

exit 0

efi_dir="/efi"
## Setup grub
sed -i 's/#GRUB_ENABLE_CRYPTODISK/GRUB_ENABLE_CRYPTODISK' /etc/default/grub
sed -i '/'
## Setup initramfs
cat <<EOF >/mnt/etc/mkinitcpio.conf
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev autodetect keyboard keymap modconf block encrypt filesystems keyboard fsck)
EOF
mount ${part_boot} /mnt${efi_dir}
arch-chroot /mnt mkinitcpio -p linux
device_uuid=$(blkid | grep ${part_root} | grep -oP ' UUID="\K[\w\d-]+')
echo "GRUB_ENABLE_CRYPTODISK=y" >>/mnt/etc/default/grub
perl -pi -e "s~GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet\K~ cryptdevice=UUID=${device_uuid}:root root=${part_root_install}~" /mnt/etc/default/grub

arch-chroot /mnt grub-install --target=x86_64-efi --bootloader-id=Archer --efi-directory=${efi_dir}
perl -pi -e "s/GRUB_TIMEOUT=\K\d+/0/" /mnt/etc/default/grub
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

arch-chroot /mnt bash <(curl -s https://install.alvinjay.site/setup2.sh)
