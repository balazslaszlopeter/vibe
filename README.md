# Gentoo X60 TUI Installer

A small terminal-user-interface installer for installing **Gentoo Linux x86/i686 + OpenRC** on a **Librebooted ThinkPad X60** from a **Debian live environment**.

This project is intentionally narrow. It assumes the target is an old-school BIOS/Libreboot X60-class machine and uses a simple MBR layout rather than trying to be a universal Gentoo installer.

## What it installs

- Gentoo i686 stage3, OpenRC
- `gentoo-kernel-bin` (prebuilt Gentoo distribution kernel)
- GRUB `i386-pc` / legacy BIOS bootloader
- ext2 `/boot`
- ext4 `/`
- swap
- NetworkManager + Wi-Fi tooling
- Linux firmware + Intel microcode
- sudo and a few basic admin tools

The stage3 filename is **not hardcoded**. The installer reads Gentoo's current `latest-stage3-i686-openrc.txt`, downloads the current tarball, downloads its `.sha256`, and verifies the SHA-256 before extraction.

## ⚠️ Destructive warning

This installer **erases the selected target disk**.

To reduce the chance of wiping the Debian USB by accident it:

1. detects the device backing `/run/live/medium`, `/cdrom`, the installer directory, and `/` when possible;
2. hides those parent disks from target selection;
3. shows a full review screen;
4. requires a second confirmation containing the exact target device, for example `ERASE /dev/sda`.

Still: read the target disk model and size before confirming.

## Recommended setup

Boot a **32-bit Debian i386 live system** on a 32-bit Core Duo X60. A 64-bit Debian environment also works on an x86-64 host, but the intended target here is the 32-bit X60.

Use Ethernet during installation if possible. It removes Wi-Fi/live-environment variables while Portage and the stage3 are downloading.

## Run it from Debian

If Git is available:

```bash
sudo apt update
sudo apt install -y git

git clone https://github.com/balazslaszlopeter/vibe.git gentoo-x60-installer
cd gentoo-x60-installer
sudo ./install.sh
```

If the script reports missing Debian-side utilities, it installs its own small dependency set with `apt-get`.

## Copy it to another pendrive instead

On another Linux machine, after downloading/cloning this repo:

```bash
cp -a gentoo-x60-installer /media/$USER/YOUR_USB_NAME/
```

Then on Debian live:

```bash
cd /media/user/YOUR_USB_NAME/gentoo-x60-installer
sudo ./install.sh
```

The exact mount path varies. `lsblk -f` is useful for finding it.

## TUI flow

The installer walks you through:

1. environment/network check;
2. safe target-disk selection;
3. hostname;
4. username;
5. timezone (defaults to `Europe/Budapest`);
6. swap size (defaults to 4 GiB);
7. optional full `@world` update;
8. root/user passwords;
9. destructive review + exact erase confirmation;
10. MBR partitioning and formatting;
11. current Gentoo stage3 download + SHA-256 verification;
12. chroot configuration;
13. kernel, firmware, NetworkManager and GRUB installation;
14. sanity checks;
15. clean unmount.

It **never reboots automatically**.

## Default disk layout

| Partition | Size | Filesystem | Mount |
|---|---:|---|---|
| 1 | 512 MiB | ext2 | `/boot` |
| 2 | configurable, 4 GiB default | swap | swap |
| 3 | remainder | ext4 | `/` |

Partition table: DOS/MBR.

## Why `gentoo-kernel-bin`?

The X60 is slow by modern standards. The initial goal is to get a known-good booting Gentoo system without first spending a long time compiling a kernel. Once the machine is booted and healthy, you can replace it with a hand-tuned kernel later.

## Why `-march=native`?

The install is designed to run **on the actual target X60**, so Portage compilation occurs on the CPU the resulting system will use. The script adds:

```text
COMMON_FLAGS="-O2 -pipe -march=native"
MAKEOPTS="-j2"
```

Do not use this installer to build an X60 disk on a newer unrelated PC and then move the drive into the X60; `-march=native` would then target the wrong CPU.

## Libreboot notes

The installer writes a conventional GRUB `i386-pc` bootloader to the internal disk and generates `/boot/grub/grub.cfg`. It also forces `GRUB_TERMINAL=console`, avoiding unnecessary graphics-mode switching in GRUB.

## Log and failure behavior

The Debian-side log is:

```text
/tmp/gentoo-x60-installer.log
```

If an installation step fails, the script **does not reboot** and tells you where the log is. Passwords are not written to the installer environment file or log.

## Files

- `install.sh` — Debian/live-environment TUI and destructive-disk work
- `chroot-install.sh` — copied temporarily into the new Gentoo system and executed inside the chroot

## Scope

This is intentionally for the ThinkPad X60 / 32-bit Gentoo use case. It does not currently support:

- UEFI/GPT installs
- LUKS
- LVM
- systemd stage3s
- dual boot
- automatic desktop/Xorg installation

Get the base system booting first; desktop setup is much easier to debug afterward.

## License

MIT. See `LICENSE`.
