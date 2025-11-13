#!/usr/bin/bash

baseurl="https://arch-install.pages.dev"

install_qemu() {
	sudo pacman -S --noconfirm --needed qemu-desktop virt-manager virt-viewer dnsmasq \
		vde2 bridge-utils openbsd-netcat ebtables libguestfs dmidecode

	sudo usermod -a -G libvirt,kvm $(whoami)

	sudo sed -i 's/^#\(unix_sock_group = "libvirt"\)/\1/; s/^#\(unix_sock_rw_perms = "0770"\)/\1/' /etc/libvirt/libvirtd.conf

	sudo sed -i 's/#dynamic_ownership = 1/dynamic_ownership = 0/' /etc/libvirt/qemu.conf
	sudo sed -i 's/#user = "libvirt-qemu"/user = "root"/' /etc/libvirt/qemu.conf

	sudo systemctl enable --now libvirtd

	virsh -c qemu:///system net-autostart default
	virsh -c qemu:///system net-start default

	echo "Reboot"
}

setup_vm() {
	local name=$1
	local vmhooks="${baseurl}/extras/vm/hooks"

	yay -S --noconfirm looking-glass looking-glass-module-dkms
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
		SUBSYSTEM=="misc", KERNEL=="kvmfr*", GROUP="kvm", MODE="0660"
	EOF

	if ! grep -q "^cgroup_device_acl" /etc/libvirt/qemu.conf; then
		sudo tee -a /etc/libvirt/qemu.conf <<-EOF
			cgroup_device_acl = [
				"/dev/null", "/dev/full", "/dev/zero",
				"/dev/random", "/dev/urandom",
				"/dev/ptmx", "/dev/kvm",
				"/dev/userfaultfd", "/dev/kvmfr0"
			]
		EOF
	fi
}

install_chaotic() {
	bash <(curl -s https://arch-install.pages.dev/other/chaotic.sh)
}

setup_win11() {
	install_qemu
	setup_vm win11

	wget -O /tmp/win11.xml "${baseurl}/extras/vm/win11.xml"
	virsh -c qemu:///system define --file /tmp/win11.xml
}

secure_boot() {
	# Install required packages
	sudo pacman -S --needed --noconfirm sbctl tpm2-tss

	# Check if Secure Boot is supported
	if ! sudo sbctl status &>/dev/null; then
		echo "Error: Secure Boot is not supported on this system"
		return 1
	fi

	# Check if system is in Setup Mode
	if ! sudo sbctl status | grep -q "Setup Mode.*Enabled"; then
		echo "Warning: System is not in Setup Mode"
		echo "Please enable Setup Mode in UEFI/BIOS settings and clear existing keys"
		echo "Then run this function again"
		return 1
	fi

	# Create custom Secure Boot keys
	echo "Creating custom Secure Boot keys..."
	sudo sbctl create-keys

	# Enroll the keys (with Microsoft keys for compatibility)
	echo "Enrolling Secure Boot keys..."
	sudo sbctl enroll-keys -m

	# Find and sign bootloader and kernel files
	echo "Signing bootloader and kernel files..."

	# Sign GRUB bootloader
	if [ -f "/boot/grub/x86_64-efi/core.efi" ]; then
		sudo sbctl sign -s /boot/grub/x86_64-efi/core.efi
	fi
	if [ -f "/boot/grub/x86_64-efi/grub.efi" ]; then
		sudo sbctl sign -s /boot/grub/x86_64-efi/grub.efi
	fi
	if [ -f "/boot/EFI/GRUB/grubx64.efi" ]; then
		sudo sbctl sign -s /boot/EFI/GRUB/grubx64.efi
	fi
	if [ -f "/boot/EFI/systemd/systemd-bootx64.efi" ]; then
		sudo sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
	fi

	# Sign kernel and initramfs
	for kernel in /boot/vmlinuz-*; do
		if [ -f "$kernel" ]; then
			sudo sbctl sign -s "$kernel"
		fi
	done

	# Sign EFI binaries
	if [ -f "/boot/EFI/BOOT/BOOTX64.EFI" ]; then
		sudo sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
	fi

	# Verify signatures
	echo "Verifying signatures..."
	sudo sbctl verify

	echo "Secure Boot setup complete!"
	echo "Status:"
	sudo sbctl status
	echo ""
	echo "IMPORTANT: Reboot and enable Secure Boot in UEFI/BIOS settings"
}