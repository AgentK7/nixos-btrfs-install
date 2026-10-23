# nixos-btrfs-install

Interaktives Installer-Skript für NixOS auf btrfs, wahlweise aktuelles Release oder unstable.

Im NixOS-Live-System (UEFI, Secure Boot aus) als root:

```bash
curl -L is.gd/B1rzoc -o i.sh && sudo bash i.sh
```

Langform: `https://raw.githubusercontent.com/AgentK7/nixos-btrfs-install/main/install.sh`

## Sicherheit beim Installieren

- Die erzeugte Konfiguration wird **vor** dem Löschen gegen die gewählte NixOS-Version geprüft. Ist sie fehlerhaft, bricht das Skript ab, ohne etwas anzufassen.
- Schlägt `nixos-install` fehl, kannst du die Konfiguration bearbeiten und es erneut versuchen.
- Belegte Platten (Swap, LVM, LUKS, RAID) werden vor dem Partitionieren freigegeben.
- Komplettes Protokoll unter `/var/log/nixos-install.log`.

## Mehrere Rechner gleich installieren

Alle Antworten landen in `/etc/nixos/install-antworten.env`. Damit läuft die nächste Installation ohne Rückfragen (bis auf Passwörter und die Sicherheitsabfrage):

```bash
DISK=/dev/nvme0n1 ANTWORTEN=/pfad/install-antworten.env sudo -E bash i.sh
ANTWORTEN=https://server/install-antworten.env sudo -E bash i.sh
```

Die Datei wird nur gelesen, nicht ausgeführt. Hostname, Grafik und Swap-Größe ggf. pro Rechner anpassen.

## Was es einrichtet

- GPT: 1 GiB EFI-Partition (`/boot`), Rest btrfs, optional in LUKS2
- Subvolumes `@`, `@home`, `@nix`, `@log`, `@swap` mit `compress=zstd,noatime`, optional snapper-Snapshots für `/home`
- systemd-boot oder UKI über [lanzaboote](https://github.com/nix-community/lanzaboote) v1.2.0, optional TPM2-Entsperren für LUKS
- Neuester stabiler Kernel (`KERNEL=lts` für den Standard-Kernel), bei NVIDIA auf Wunsch LTS
- Grafik: Intel, AMD, NVIDIA (offene Module oder Treiber 580), NVIDIA-PRIME für Laptops, nouveau
- Laptops: Ruhezustand (Swapfile und resume-Offset automatisch), Verhalten beim Zuklappen, Energieprofile, thermald auf Intel
- Swapfile plus zram, btrfs-Scrub, Store-Optimierung, fwupd, smartd (Warnung bei sterbenden Platten)
- Backup von `/home` mit restic auf einen anderen Rechner (SFTP, REST-Server, S3 …), täglich
- VMs (libvirt, virt-manager), Container (Podman oder Docker)
- PipeWire mit ALSA (inkl. 32 bit), PulseAudio und JACK
- Optional: Drucken, Bluetooth, Steam + Gamemode, Samba (Client oder Server), Flatpak + Flathub, SSH nur mit Schlüssel
- Schriften: Noto mit Emoji und CJK, JetBrains Mono Nerd Font
- zsh mit fertiger `~/.zshrc`, optional oh-my-zsh; weitere Benutzer ohne Admin-Rechte
- Systempakete: git, nixfmt, vim, btop, ripgrep, fd, bat, jq, tmux, ncdu, nvme-cli, inxi, dig, nmap, tcpdump, iperf3, nix-tree, nh, direnv u. a.

## Secure Boot nach der Installation (nur mit UKI)

1. `sudo sbctl verify`
2. Im Firmware-Setup Secure Boot einschalten und in den Setup Mode setzen
3. `sudo sbctl enroll-keys --microsoft`, neu starten, `bootctl status`
4. Mit TPM2: `sudo luks-tpm2-enroll`, danach startet das System ohne LUKS-Passwort

**Achtung:** Die gewählte Platte wird komplett gelöscht.
