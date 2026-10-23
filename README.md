# nixos-btrfs-install

Interaktives Installer-Skript für NixOS auf btrfs, wahlweise aktuelles Release oder unstable.

Im NixOS-Live-System (UEFI, Secure Boot aus) als root:

```bash
curl -L is.gd/B1rzoc -o i.sh && sudo bash i.sh
```

Langform: `https://raw.githubusercontent.com/AgentK7/nixos-btrfs-install/main/install.sh`

## Was es einrichtet

- GPT: 1 GiB EFI-Partition (`/boot`), Rest btrfs, optional in LUKS2; belegte Platten (Swap, LVM, LUKS, RAID) werden vorher freigegeben
- Subvolumes `@`, `@home`, `@nix`, `@log`, `@swap` mit `compress=zstd,noatime`, optional snapper-Snapshots für `/home`
- systemd-boot oder UKI über [lanzaboote](https://github.com/nix-community/lanzaboote) v1.2.0 mit Secure-Boot-Schlüsseln, optional TPM2-Entsperren für LUKS
- Neuester stabiler Kernel (`KERNEL=lts` für den Standard-Kernel), bei NVIDIA auf Wunsch LTS
- Grafik: Intel, AMD, NVIDIA (offene Module oder Treiber 580 für ältere Karten), NVIDIA-PRIME für Laptops, nouveau
- Swapfile plus zram, monatlicher btrfs-Scrub, Store-Optimierung, fwupd
- PipeWire mit ALSA (inkl. 32 bit), PulseAudio und JACK
- Samba: Netzlaufwerke nutzen oder zusätzlich `~/Freigabe` freigeben (sichtbar in Windows, macOS und Linux)
- Optional: Drucken (CUPS + Avahi), Bluetooth, Steam + Gamemode, SSH nur mit Schlüssel (eingefügt oder `gh:<GitHub-Name>`)
- zsh mit fertiger `~/.zshrc`, optional oh-my-zsh
- Systempakete: git, nixfmt, vim, btop, ripgrep, fd, bat, jq, tmux, ncdu, nvme-cli, inxi, dig, nmap, tcpdump, iperf3, nix-tree, nh, direnv u. a.
- Komplettes Protokoll unter `/var/log/nixos-install.log`

## Abfragen

Datenträger, Version, Tastatur, Sprache, Desktop (GNOME, Plasma 6, COSMIC, Xfce, Cinnamon, keiner) minimal oder vollständig, Grafiktreiber, Drucken, Bluetooth, Steam, Samba, Flatpak + Flathub, Unfree, Verschlüsselung, UKI, TPM2, Silent Boot (Plymouth), Snapshots, Auto-Updates, Shell, SSH, Hostname, Benutzer, Swap.

Alle Abfragen lassen sich per Umgebungsvariable vorbelegen, siehe Kopf von `install.sh`.

## Secure Boot nach der Installation (nur mit UKI)

1. `sudo sbctl verify`
2. Im Firmware-Setup Secure Boot einschalten und in den Setup Mode setzen
3. `sudo sbctl enroll-keys --microsoft`, neu starten, `bootctl status`
4. Mit TPM2: `sudo luks-tpm2-enroll`, danach startet das System ohne LUKS-Passwort

**Achtung:** Die gewählte Platte wird komplett gelöscht.
