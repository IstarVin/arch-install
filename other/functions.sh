install_qemu() {
	sudo pacman -S --noconfirm --needed qemu-desktop virt-manager virt-viewer dnsmasq \
		vde2 bridge-utils openbsd-netcat ebtables libguestfs

	sudo usermod -a -G libvirt $(whoami)

	sudo sed -i 's/^#\(unix_sock_group = "libvirt"\)/\1/; s/^#\(unix_sock_rw_perms = "0770"\)/\1/' /etc/libvirt/libvirtd.conf

	sudo sed -i 's/#dynamic_ownership = 1/dynamic_ownership = 0/' /etc/libvirt/qemu.conf
	sudo sed -i 's/#user = "libvirt-qemu"/user = "root"/' /etc/libvirt/qemu.conf

	sudo systemctl enable libvirtd

	echo "Reboot"
}

install_chaotic() {
	bash <(curl -s https://arch-install.pages.dev/other/chaotic.sh)
}