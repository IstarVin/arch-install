#!/usr/bin/bash

baseurl="https://arch-install.pages.dev"

install_qemu() {
	sudo pacman -S --needed --noconfirm qemu-desktop virt-manager virt-viewer dnsmasq \
		vde2 bridge-utils openbsd-netcat ebtables libguestfs dmidecode

	local current_user
	current_user=$(whoami)
	if ! id -nG "${current_user}" | grep -qw libvirt; then
		sudo usermod -a -G libvirt "${current_user}"
	fi
	if ! id -nG "${current_user}" | grep -qw kvm; then
		sudo usermod -a -G kvm "${current_user}"
	fi

	if grep -q '^#unix_sock_group = "libvirt"' /etc/libvirt/libvirtd.conf; then
		sudo sed -i 's/^#\(unix_sock_group = "libvirt"\)/\1/' /etc/libvirt/libvirtd.conf
	fi
	if grep -q '^#unix_sock_rw_perms = "0770"' /etc/libvirt/libvirtd.conf; then
		sudo sed -i 's/^#\(unix_sock_rw_perms = "0770"\)/\1/' /etc/libvirt/libvirtd.conf
	fi

	if grep -q '^#dynamic_ownership = 1' /etc/libvirt/qemu.conf; then
		sudo sed -i 's/#dynamic_ownership = 1/dynamic_ownership = 0/' /etc/libvirt/qemu.conf
	fi
	if grep -q '^#user = "libvirt-qemu"' /etc/libvirt/qemu.conf; then
		sudo sed -i 's/#user = "libvirt-qemu"/user = "root"/' /etc/libvirt/qemu.conf
	fi

	sudo systemctl enable --now libvirtd

	if ! virsh -c qemu:///system net-info default 2>/dev/null | grep -q "Autostart:.*yes"; then
		virsh -c qemu:///system net-autostart default
	fi
	if ! virsh -c qemu:///system net-info default 2>/dev/null | grep -q "Active:.*yes"; then
		virsh -c qemu:///system net-start default
	fi

	echo "Reboot"
}

setup_vm() {
	local name=$1
	local vmhooks="${baseurl}/extras/vm/hooks"

	yay -S --needed --noconfirm looking-glass looking-glass-module-dkms
	sudo mkdir -p /etc/libvirt/hooks/qemu.d
	if [[ ! -f /etc/libvirt/hooks/qemu ]]; then
		sudo wget 'https://asus-linux.org/files/vfio/libvirt_hooks/qemu' -O /etc/libvirt/hooks/qemu
		sudo chmod +x /etc/libvirt/hooks/qemu
	fi

	local hooks_dir="/etc/libvirt/hooks/qemu.d/${name}"

	sudo mkdir -p "${hooks_dir}/prepare/begin"
	sudo mkdir -p "${hooks_dir}/release/end"

	local files=("vm-vars.conf" \
				"prepare/begin/10-asusd-vfio.sh" "prepare/begin/20-reserve-hugepages.sh" "prepare/begin/40-isolate-cpus.sh" \
				"release/end/10-release-hugepages.sh" "release/end/20-return-cpus.sh" "release/end/40-asusd-integrated.sh" \
				"release/end/60-kill-looking-glass.sh")

	for file in "${files[@]}"; do
		if [[ ! -f "${hooks_dir}/${file}" ]]; then
			sudo wget "${vmhooks}/${file}" -O "${hooks_dir}/${file}"
			sudo sed -i "s/%name%/$(printf '%s' "${name}" | sed 's/[\/&]/\\&/g')/" "${hooks_dir}/${file}"
			sudo chmod +x "${hooks_dir}/${file}"
		fi
	done

	if [[ ! -f /etc/modules-load.d/kvmfr.conf ]]; then
		sudo tee /etc/modules-load.d/kvmfr.conf <<-EOF
			#KVMFR Looking Glass Module
			kvmfr
		EOF
	fi

	if [[ ! -f /etc/modprobe.d/kvmfr.conf ]]; then
		sudo tee /etc/modprobe.d/kvmfr.conf <<-EOF
			#KVMFR Looking Glass Module
			options kvmfr static_size_mb=32
		EOF
	fi

	if [[ ! -f /etc/udev/rules.d/99-kvmfr.rules ]]; then
		sudo tee /etc/udev/rules.d/99-kvmfr.rules <<-EOF
			SUBSYSTEM=="kvmfr", GROUP="kvm", MODE="0660"
		EOF
	fi

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

	if ! virsh -c qemu:///system dominfo win11 &>/dev/null; then
		wget -O /tmp/win11.xml "${baseurl}/extras/vm/win11.xml"
		virsh -c qemu:///system define --file /tmp/win11.xml
	fi
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
	if ! sudo sbctl status | grep -q "Secure Boot Keys.*Created"; then
		echo "Creating custom Secure Boot keys..."
		sudo sbctl create-keys
	else
		echo "Secure Boot keys already exist, skipping creation."
	fi

	# Enroll the keys (with Microsoft keys for compatibility)
	if ! sudo sbctl status | grep -q "Secure Boot Keys.*Enrolled"; then
		echo "Enrolling Secure Boot keys..."
		sudo sbctl enroll-keys -m
	else
		echo "Secure Boot keys already enrolled, skipping."
	fi

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

setup_tpm_luks() {
	local luks_source="${1:-}"
	local pcrs="${2:-7}"
	local luks_device=""
	local mapper_name=""

	sudo pacman -S --needed --noconfirm tpm2-tss

	if [[ -z "${luks_source}" ]]; then
		luks_source="$(findmnt -no SOURCE / 2>/dev/null)"
	fi

	if [[ -z "${luks_source}" ]]; then
		echo "Error: unable to detect the current root source"
		return 1
	fi

	if [[ "${luks_source}" == /dev/mapper/* ]]; then
		mapper_name="$(basename "${luks_source}")"
		luks_device="$(sudo cryptsetup status "${mapper_name}" 2>/dev/null | awk '/device:/ {print $2; exit}')"
	else
		luks_device="${luks_source}"
	fi

	if [[ -z "${luks_device}" || ! -b "${luks_device}" ]]; then
		echo "Error: unable to resolve the underlying LUKS device"
		return 1
	fi

	if ! sudo cryptsetup luksDump "${luks_device}" 2>/dev/null | grep -q '^Version:[[:space:]]*2'; then
		echo "Error: TPM enrollment requires a LUKS2 volume"
		return 1
	fi

	echo "Enrolling TPM2 unlock for ${luks_device} with PCRs ${pcrs}..."
	if sudo systemd-cryptenroll --list-devices 2>/dev/null | grep -q "${luks_device}" || \
		sudo cryptsetup luksDump "${luks_device}" 2>/dev/null | grep -q "systemd-tpm2"; then
		echo "TPM2 slot already enrolled for ${luks_device}, skipping."
	else
		sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs="${pcrs}" "${luks_device}"
	fi

	if [[ -f /etc/mkinitcpio.conf ]]; then
		echo "Regenerating initramfs..."
		if ! sudo sbctl list-files 2>/dev/null | grep -q "initramfs" || [[ -z "$(sudo sbctl list-files 2>/dev/null)" ]]; then
			sudo mkinitcpio -P
		else
			echo "Initramfs already up to date, skipping regeneration."
		fi
	fi

	echo "TPM-based LUKS unlock has been configured. Reboot to test it."
}
