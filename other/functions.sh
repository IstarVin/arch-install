#!/usr/bin/bash

baseurl="https://arch-install.pages.dev"

install_qemu() {
	sudo pacman -S --noconfirm --needed qemu-desktop virt-manager virt-viewer dnsmasq \
		vde2 bridge-utils openbsd-netcat ebtables libguestfs dmidecode

	sudo usermod -a -G libvirt,kvm $(whoami)

	sudo sed -i 's/^#\(unix_sock_group = "libvirt"\)/\1/; s/^#\(unix_sock_rw_perms = "0770"\)/\1/' /etc/libvirt/libvirtd.conf

	sudo sed -i 's/#dynamic_ownership = 1/dynamic_ownership = 0/' /etc/libvirt/qemu.conf
	sudo sed -i 's/#user = "libvirt-qemu"/user = "root"/' /etc/libvirt/qemu.conf

	sudo systemctl enable libvirtd

	echo "Reboot"
}

setup_vm() {
	local name=$1
	local vmhooks="${baseurl}/extras/vm/hooks"

	yay -S --noconfirm looking-glass looking-glass-dkms
	sudo mkdir -p /etc/libvirt/hooks/qemu.d
	sudo wget 'https://asus-linux.org/files/vfio/libvirt_hooks/qemu' -O /etc/libvirt/hooks/qemu
	sudo chmod +x /etc/libvirt/hooks/qemu

	local hooks_dir="/etc/libvirt/hooks/qemu.d/${name}"

	sudo mkdir -p "${hooks_dir}/prepare/begin"
	sudo mkdir -p "${hooks_dir}/release/end"

	local files=("vm-vars.conf" \
				"prepare/begin/10-asusd-vfio.sh" "prepare/begin/20-reserve-hugepages.sh" "prepare/begin/40-isolate-cpus.sh" \
				"release/end/10-release-hugepages.sh" "release/end/20-return-cpus.sh" "release/end/40-asusd-integrated.sh" \
				"release/end/60-kill-looking-glass.sh")

	for file in "${files[@]}"; do
		sudo wget "${vmhooks}/${file}" -O "${hooks_dir}/${file}"
		sudo sed -i "s/%name%/$(printf '%s' "${name}" | sed 's/[\/&]/\\&/g')/" "${hooks_dir}/${file}"
		sudo chmod +x "${hooks_dir}/${file}"
	done

	sudo tee /etc/modules-load.d/kvmfr.conf <<-EOF
		#KVMFR Looking Glass Module
		kvmfr
	EOF

	sudo tee /etc/modprobe.d/kvmfr.conf <<-EOF
		#KVMFR Looking Glass Module
		options kvmfr static_size_mb=32
	EOF

	sudo tee /etc/udev/rules.d/99-kvmfr.rules <<-EOF
		SUBSYSTEM=="kvmfr", OWNER="${USER}", GROUP="kvm", MODE="0660"
	EOF
}

install_chaotic() {
	bash <(curl -s https://arch-install.pages.dev/other/chaotic.sh)
}