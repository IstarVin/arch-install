install_qemu() {
	sudo pacman -S --noconfirm --needed qemu-desktop virt-manager virt-viewer dnsmasq \
		vde2 bridge-utils openbsd-netcat ebtables libguestfs

	sudo usermod -a -G libvirt $(whoami)

	sudo sed -i 's/^#\(unix_sock_group = "libvirt"\)/\1/; s/^#\(unix_sock_rw_perms = "0770"\)/\1/' /etc/libvirt/libvirtd.conf

	echo "Reboot"
}