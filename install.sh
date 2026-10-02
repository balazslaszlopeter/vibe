#!/usr/bin/env bash
set -Eeuo pipefail

# Gentoo X60 TUI Installer
# Run from a Debian live environment on the target ThinkPad X60.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/mnt/gentoo"
LOG="/tmp/gentoo-x60-installer.log"
STAGE_BASE="https://distfiles.gentoo.org/releases/x86/autobuilds/current-stage3-i686-openrc"
CHROOT_SCRIPT="$SCRIPT_DIR/chroot-install.sh"

exec 3>&1
: > "$LOG"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&3
}

fatal() {
    local msg="$1"
    log "ERROR: $msg"
    if command -v dialog >/dev/null 2>&1; then
        dialog --title "Gentoo X60 Installer — Error" --msgbox "$msg\n\nLog: $LOG" 10 70 || true
    else
        printf '\nERROR: %s\nLog: %s\n' "$msg" "$LOG" >&2
    fi
    exit 1
}

on_error() {
    local rc=$?
    local line=${BASH_LINENO[0]:-unknown}
    fatal "The installer stopped unexpectedly (exit $rc, line $line). Nothing will reboot automatically."
}
trap on_error ERR

need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "Run this installer as root: sudo ./install.sh"
}

bootstrap_dependencies() {
    local required=(dialog curl wget lsblk sfdisk wipefs mkfs.ext2 mkfs.ext4 mkswap swapon mount umount mountpoint chroot sha256sum tar findmnt blkid partprobe blockdev)
    local missing=()
    local cmd

    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    ((${#missing[@]} == 0)) && return 0

    command -v apt-get >/dev/null 2>&1 || fatal "Missing commands: ${missing[*]}. This script expects a Debian live environment with apt-get."

    printf 'Installing Debian-side dependencies: %s\n' "${missing[*]}" | tee -a "$LOG"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >>"$LOG" 2>&1
    apt-get install -y dialog curl wget ca-certificates parted util-linux e2fsprogs xz-utils tar >>"$LOG" 2>&1
}

ui_msg() {
    dialog --title "Gentoo X60 Installer" --msgbox "$1" 12 74
}

ui_status() {
    dialog --title "Gentoo X60 Installer" --infobox "$1\n\nDetailed log: $LOG" 8 74
}

ui_input() {
    local prompt="$1" default="${2:-}"
    dialog --stdout --title "Gentoo X60 Installer" --inputbox "$prompt" 10 74 "$default"
}

ui_password() {
    local prompt="$1"
    dialog --stdout --insecure --title "Gentoo X60 Installer" --passwordbox "$prompt" 10 74
}

run_logged() {
    local status="$1"
    shift
    ui_status "$status"
    log "$status"
    "$@" >>"$LOG" 2>&1
}

parent_disk_for_path() {
    local path="$1" src pk type
    src="$(findmnt -n -o SOURCE -T "$path" 2>/dev/null || true)"
    [[ "$src" == /dev/* ]] || return 0
    type="$(lsblk -ndo TYPE "$src" 2>/dev/null || true)"
    if [[ "$type" == "disk" ]]; then
        printf '%s\n' "$src"
        return 0
    fi
    pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
    [[ -n "$pk" ]] && printf '/dev/%s\n' "$pk"
}

part_path() {
    local disk="$1" num="$2"
    if [[ "$disk" =~ [0-9]$ ]]; then
        printf '%sp%s\n' "$disk" "$num"
    else
        printf '%s%s\n' "$disk" "$num"
    fi
}

validate_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

validate_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

validate_timezone() {
    [[ "$1" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]]
}

collect_protected_disks() {
    PROTECTED_DISKS=()
    declare -gA PROTECTED_MAP=()
    local p d
    for p in /run/live/medium /cdrom "$SCRIPT_DIR" /; do
        [[ -e "$p" ]] || continue
        d="$(parent_disk_for_path "$p" || true)"
        if [[ -n "$d" && -z "${PROTECTED_MAP[$d]:-}" ]]; then
            PROTECTED_MAP["$d"]=1
            PROTECTED_DISKS+=("$d")
        fi
    done
}

choose_disk() {
    collect_protected_disks

    local -a args=()
    local name size model type desc
    while read -r name size type model; do
        [[ "$type" == "disk" ]] || continue
        [[ -n "$name" ]] || continue
        if [[ -n "${PROTECTED_MAP[$name]:-}" ]]; then
            log "Skipping protected/live-media disk: $name"
            continue
        fi
        desc="$size ${model:-unknown-model}"
        args+=("$name" "$desc")
    done < <(lsblk -dpno NAME,SIZE,TYPE,MODEL)

    ((${#args[@]} >= 2)) || fatal "No safe target disk was found. The live/install-media disk is intentionally excluded."

    DISK="$(dialog --stdout --title "Select target disk" --menu \
        "Choose the INTERNAL disk that Gentoo will completely erase.\n\nLive/install media is hidden from this list." \
        18 78 8 "${args[@]}")"

    [[ -b "$DISK" ]] || fatal "Selected target is not a block device: $DISK"
}

check_environment() {
    local machine cpu_model
    machine="$(uname -m)"
    if ((10#$(date +%Y) < 2024)); then
        fatal "System clock appears wrong ($(date -Is)). Fix the Debian live clock before using HTTPS mirrors."
    fi
    cpu_model="$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)"

    if [[ "$machine" != i?86 && "$machine" != x86_64 ]]; then
        fatal "This installer only supports x86 hosts. Detected: $machine"
    fi

    run_logged "Checking Gentoo mirror connectivity..." curl -fsS --max-time 20 "$STAGE_BASE/latest-stage3-i686-openrc.txt" -o /tmp/gentoo-stage-latest.txt

    ui_msg "Host architecture: $machine\nCPU: ${cpu_model:-unknown}\n\nTarget Gentoo architecture: i686 (32-bit)\nInit system: OpenRC\nBoot mode: legacy BIOS/Libreboot GRUB\n\nThis is intended for the 32-bit ThinkPad X60/Core Duo class machine."
}

collect_settings() {
    HOSTNAME="$(ui_input "Hostname:" "x60")"
    validate_hostname "$HOSTNAME" || fatal "Invalid hostname: $HOSTNAME"

    USERNAME="$(ui_input "Normal username:" "user")"
    validate_username "$USERNAME" || fatal "Invalid username: $USERNAME"

    TIMEZONE="$(ui_input "Timezone:" "Europe/Budapest")"
    validate_timezone "$TIMEZONE" || fatal "Invalid timezone format: $TIMEZONE"
    [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] || ui_msg "Debian does not have /usr/share/zoneinfo/$TIMEZONE locally. Gentoo will still verify it after stage3 extraction."

    SWAP_GIB="$(ui_input "Swap size in GiB (whole number):" "4")"
    [[ "$SWAP_GIB" =~ ^[1-9][0-9]*$ ]] || fatal "Swap size must be a positive whole number."

    if dialog --title "Full system update" --yes-label "Yes (slow)" --no-label "No (recommended)" --defaultno --yesno \
        "Run a full emerge --update --deep --newuse @world during installation?\n\nOn an X60 this can add a lot of time. The base system will be installable without it." 13 74; then
        WORLD_UPDATE=1
    else
        WORLD_UPDATE=0
    fi

    ROOT_PASSWORD="$(ui_password "Set the Gentoo root password:")"
    [[ -n "$ROOT_PASSWORD" ]] || fatal "Root password cannot be empty."
    local root2
    root2="$(ui_password "Repeat the Gentoo root password:")"
    [[ "$ROOT_PASSWORD" == "$root2" ]] || fatal "Root passwords did not match."

    USER_PASSWORD="$(ui_password "Set password for $USERNAME:")"
    [[ -n "$USER_PASSWORD" ]] || fatal "User password cannot be empty."
    local user2
    user2="$(ui_password "Repeat password for $USERNAME:")"
    [[ "$USER_PASSWORD" == "$user2" ]] || fatal "User passwords did not match."
}

confirm_destructive_action() {
    local disk_info confirm
    disk_info="$(lsblk -dn -o NAME,SIZE,MODEL "$DISK" | sed 's/^[[:space:]]*//')"

    dialog --title "FINAL REVIEW — DATA LOSS" --yes-label "Continue" --no-label "Cancel" --defaultno --yesno \
"Target: $disk_info

Partition plan:
  1: 512 MiB ext2  /boot
  2: ${SWAP_GIB} GiB swap
  3: remaining disk ext4 /

Hostname: $HOSTNAME
User: $USERNAME
Timezone: $TIMEZONE
Gentoo: i686 + OpenRC
Kernel: gentoo-kernel-bin
Bootloader: GRUB i386-pc

EVERYTHING ON $DISK WILL BE ERASED." 23 78 || exit 0

    confirm="$(ui_input "Type exactly: ERASE $DISK")"
    [[ "$confirm" == "ERASE $DISK" ]] || fatal "Confirmation text did not match. No disk changes were made."
}

deactivate_target_disk() {
    local dev mp

    # After the explicit ERASE confirmation, unmount any auto-mounted partitions
    # from the chosen target disk and disable swap on them.
    while read -r dev mp; do
        [[ -n "$dev" ]] || continue
        swapoff "$dev" >>"$LOG" 2>&1 || true
        if [[ -n "${mp:-}" ]]; then
            umount "$dev" >>"$LOG" 2>&1 || fatal "Could not unmount $dev from $mp. Refusing to continue."
        fi
    done < <(lsblk -nrpo NAME,MOUNTPOINT "$DISK" | tail -n +2 | tac)
}

partition_disk() {
    local swap_mib root_start
    swap_mib=$((SWAP_GIB * 1024))
    root_start=$((513 + swap_mib))

    deactivate_target_disk

    BOOT_PART="$(part_path "$DISK" 1)"
    SWAP_PART="$(part_path "$DISK" 2)"
    ROOT_PART="$(part_path "$DISK" 3)"

    local disk_bytes min_bytes
    disk_bytes="$(blockdev --getsize64 "$DISK")"
    min_bytes=$(((root_start + 4096) * 1024 * 1024))
    ((disk_bytes > min_bytes)) || fatal "Disk is too small for /boot + swap + at least 4 GiB root."

    run_logged "Erasing old partition signatures on $DISK..." wipefs -a "$DISK"

    ui_status "Creating MBR partitions on $DISK..."
    log "Creating MBR partition table"
    {
        printf 'label: dos\n'
        printf '\n'
        printf 'start=1MiB, size=512MiB, type=83, bootable\n'
        printf 'start=513MiB, size=%sMiB, type=82\n' "$swap_mib"
        printf 'start=%sMiB, type=83\n' "$root_start"
    } | sfdisk --wipe always "$DISK" >>"$LOG" 2>&1

    partprobe "$DISK" >>"$LOG" 2>&1 || true
    udevadm settle 2>/dev/null || true
    sleep 2

    [[ -b "$BOOT_PART" && -b "$SWAP_PART" && -b "$ROOT_PART" ]] || fatal "Partitions were not detected after partitioning."

    run_logged "Formatting /boot as ext2..." mkfs.ext2 -F -L BOOT "$BOOT_PART"
    run_logged "Creating swap..." mkswap -L SWAP "$SWAP_PART"
    run_logged "Formatting root as ext4..." mkfs.ext4 -F -L ROOT "$ROOT_PART"
}

mount_target() {
    mkdir -p "$TARGET"
    mountpoint -q "$TARGET" && fatal "$TARGET is already mounted. Clean up the previous attempt before retrying."
    run_logged "Mounting Gentoo root filesystem..." mount "$ROOT_PART" "$TARGET"
    mkdir -p "$TARGET/boot"
    run_logged "Mounting /boot..." mount "$BOOT_PART" "$TARGET/boot"
    run_logged "Enabling swap..." swapon "$SWAP_PART"
}

download_stage3() {
    local latest stage sha_file expected actual
    latest="$(curl -fsSL "$STAGE_BASE/latest-stage3-i686-openrc.txt")"
    stage="$(awk '/^stage3-i686-openrc-.*\.tar\.xz[[:space:]]/{print $1; exit}' <<<"$latest")"
    [[ -n "$stage" ]] || fatal "Could not determine the current i686/OpenRC stage3 filename."

    STAGE_PATH="$TARGET/$stage"
    sha_file="$STAGE_PATH.sha256"

    run_logged "Downloading current Gentoo i686/OpenRC stage3..." curl -fL --retry 3 --progress-bar "$STAGE_BASE/$stage" -o "$STAGE_PATH"
    run_logged "Downloading stage3 SHA-256 file..." curl -fL --retry 3 "$STAGE_BASE/$stage.sha256" -o "$sha_file"

    expected="$(grep -Eo '^[[:space:]]*[0-9a-fA-F]{64}' "$sha_file" | tr -d '[:space:]' | head -n1)"
    [[ ${#expected} -eq 64 ]] || fatal "Could not parse SHA-256 from $stage.sha256"
    actual="$(sha256sum "$STAGE_PATH" | awk '{print $1}')"
    [[ "${actual,,}" == "${expected,,}" ]] || fatal "Stage3 SHA-256 mismatch. Download is not trusted."

    run_logged "Extracting Gentoo stage3..." tar xpf "$STAGE_PATH" --xattrs-include='*.*' --numeric-owner -C "$TARGET"
    rm -f "$STAGE_PATH" "$sha_file"
}

prepare_chroot() {
    [[ -f "$CHROOT_SCRIPT" ]] || fatal "Missing bundled chroot-install.sh next to install.sh"

    cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
    install -m 0755 "$CHROOT_SCRIPT" "$TARGET/root/chroot-install.sh"

    cat > "$TARGET/root/x60-installer.env" <<EOF_ENV
DISK='$DISK'
BOOT_PART='$BOOT_PART'
SWAP_PART='$SWAP_PART'
ROOT_PART='$ROOT_PART'
HOSTNAME='$HOSTNAME'
USERNAME='$USERNAME'
TIMEZONE='$TIMEZONE'
WORLD_UPDATE='$WORLD_UPDATE'
EOF_ENV
    chmod 0600 "$TARGET/root/x60-installer.env"

    mount -t proc /proc "$TARGET/proc"
    mount --rbind /sys "$TARGET/sys"
    mount --make-rslave "$TARGET/sys"
    mount --rbind /dev "$TARGET/dev"
    mount --make-rslave "$TARGET/dev"
    mkdir -p "$TARGET/run"
    mount --rbind /run "$TARGET/run"
    mount --make-rslave "$TARGET/run"
}

run_chroot_install() {
    run_logged "Installing and configuring the Gentoo base system. This is the long part..." chroot "$TARGET" /bin/bash /root/chroot-install.sh

    log "Setting account passwords"
    printf 'root:%s\n%s:%s\n' "$ROOT_PASSWORD" "$USERNAME" "$USER_PASSWORD" | chroot "$TARGET" /usr/sbin/chpasswd >>"$LOG" 2>&1
    unset ROOT_PASSWORD USER_PASSWORD

    rm -f "$TARGET/root/x60-installer.env" "$TARGET/root/chroot-install.sh"
}

sanity_check() {
    local failed=0
    [[ -f "$TARGET/boot/grub/grub.cfg" ]] || failed=1
    compgen -G "$TARGET/boot/vmlinuz-*" >/dev/null || failed=1
    [[ -f "$TARGET/etc/fstab" ]] || failed=1
    [[ -f "$TARGET/etc/gentoo-release" ]] || failed=1
    ((failed == 0)) || fatal "Post-install sanity checks failed. Inspect $LOG before rebooting."
}

finish_install() {
    sync
    dialog --title "Installation complete" --msgbox \
"Gentoo installation completed successfully.

Target: $DISK
Hostname: $HOSTNAME
User: $USERNAME

The installer verified:
  • Gentoo release file
  • kernel image in /boot
  • GRUB configuration
  • /etc/fstab

Log: $LOG

Choose OK, then the filesystems will be unmounted. After that you can remove the Debian USB and reboot." 20 76

    swapoff "$SWAP_PART" >>"$LOG" 2>&1 || true
    umount -R "$TARGET" >>"$LOG" 2>&1 || umount -l "$TARGET" >>"$LOG" 2>&1 || true
    sync

    dialog --title "Ready to reboot" --msgbox \
        "The Gentoo target is unmounted.\n\nRemove the Debian USB, then reboot when you are ready.\n\nThis script will NOT reboot automatically." 12 70
}

main() {
    need_root
    bootstrap_dependencies
    [[ -t 1 || -t 2 ]] || fatal "This installer needs an interactive terminal."

    ui_msg "Gentoo X60 TUI Installer\n\nThis installer uses Debian as the live environment and installs Gentoo i686/OpenRC to the X60's internal disk.\n\nIt performs destructive disk partitioning only after two confirmations."

    check_environment
    choose_disk
    collect_settings
    confirm_destructive_action
    partition_disk
    mount_target
    download_stage3
    prepare_chroot
    run_chroot_install
    sanity_check
    finish_install
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
