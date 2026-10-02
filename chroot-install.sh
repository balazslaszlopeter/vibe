#!/usr/bin/env bash
set -Eeuo pipefail

source /root/x60-installer.env
source /etc/profile
export PS1="(gentoo-x60) ${PS1:-# }"

say() {
    printf '\n==> %s\n' "$*"
}

say "Configuring Portage"
mkdir -p /etc/portage/package.use /etc/portage/package.license

# The install runs on the actual target machine, so -march=native targets the X60 CPU in place.
cat >> /etc/portage/make.conf <<'EOF_MAKE'

# Added by gentoo-x60-installer
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j2"
GRUB_PLATFORMS="pc"
EOF_MAKE

cat > /etc/portage/package.use/x60-installer <<'EOF_USE'
sys-kernel/installkernel dracut grub
EOF_USE

cat > /etc/portage/package.license/x60-installer <<'EOF_LICENSE'
sys-kernel/linux-firmware linux-fw-redistributable
sys-firmware/intel-microcode intel-ucode
EOF_LICENSE

say "Syncing Gentoo repository"
emerge --sync

say "Setting timezone and locale"
[[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] || { echo "Unknown timezone: $TIMEZONE" >&2; exit 1; }
ln -snf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
printf '%s\n' "$TIMEZONE" > /etc/timezone

cat > /etc/locale.gen <<'EOF_LOCALE'
en_US.UTF-8 UTF-8
hu_HU.UTF-8 UTF-8
EOF_LOCALE
locale-gen
cat > /etc/env.d/02locale <<'EOF_ENVLOCALE'
LANG="en_US.UTF-8"
LC_COLLATE="C.UTF-8"
EOF_ENVLOCALE
env-update

say "Configuring hostname, hosts and fstab"
printf 'hostname="%s"\n' "$HOSTNAME" > /etc/conf.d/hostname
cat > /etc/hosts <<EOF_HOSTS
127.0.0.1   localhost $HOSTNAME
::1         localhost $HOSTNAME
EOF_HOSTS

cat > /etc/fstab <<'EOF_FSTAB'
LABEL=ROOT  /      ext4  noatime  0 1
LABEL=BOOT  /boot  ext2  noatime  0 2
LABEL=SWAP  none   swap  sw       0 0
EOF_FSTAB

say "Installing kernel, bootloader, networking and base tools"
emerge --verbose --noreplace \
    sys-kernel/gentoo-kernel-bin \
    sys-kernel/installkernel \
    sys-kernel/dracut \
    sys-kernel/linux-firmware \
    sys-firmware/intel-microcode \
    sys-boot/grub \
    net-misc/networkmanager \
    net-wireless/wpa_supplicant \
    net-wireless/iw \
    app-admin/sudo \
    app-editors/nano \
    app-admin/sysklogd \
    sys-process/cronie \
    sys-apps/pciutils \
    sys-apps/usbutils \
    sys-power/acpid \
    sys-apps/smartmontools \
    app-portage/gentoolkit

say "Enabling OpenRC services"
rc-update add dbus default || true
rc-update add NetworkManager default
rc-update add sysklogd default || true
rc-update add cronie default || true
rc-update add acpid default || true

say "Creating normal user"
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -G wheel,audio,video -s /bin/bash "$USERNAME"
fi
mkdir -p /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers

say "Configuring GRUB for legacy BIOS / Libreboot"
if grep -q '^GRUB_TERMINAL=' /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL=console/' /etc/default/grub
else
    printf '\nGRUB_TERMINAL=console\n' >> /etc/default/grub
fi
if grep -q '^GRUB_TIMEOUT=' /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
else
    printf 'GRUB_TIMEOUT=3\n' >> /etc/default/grub
fi

grub-install --target=i386-pc --recheck "$DISK"
grub-mkconfig -o /boot/grub/grub.cfg

if [[ "$WORLD_UPDATE" == "1" ]]; then
    say "Running optional full @world update"
    emerge --verbose --update --deep --newuse @world
    emerge @preserved-rebuild || true
fi

say "Final target-side checks"
ls -lh /boot
[[ -f /boot/grub/grub.cfg ]]
compgen -G '/boot/vmlinuz-*' >/dev/null
rc-status -a || true

say "Gentoo target configuration complete"
