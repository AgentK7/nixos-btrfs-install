# nixos-btrfs-install

Interaktives Installer-Skript für NixOS auf btrfs, wahlweise aktuelles Release oder unstable.

Im NixOS-Live-System (UEFI, Secure Boot aus) als root:

```bash
curl -L is.gd/B1rzoc -o i.sh && sudo bash i.sh
```

Langform: `https://raw.githubusercontent.com/AgentK7/nixos-btrfs-install/main/install.sh`

## Was es einrichtet

- GPT: 1 GiB EFI-Partition (`/boot`), Rest btrfs, optional in LUKS2
- Subvolumes `@`, `@home`, `@nix`, `@log`, `@swap` mit `compress=zstd,noatime`
- systemd-boot oder UKI über [lanzaboote](https://github.com/nix-community/lanzaboote) v1.2.0 mit erzeugten Secure-Boot-Schlüsseln
- Neuester stabiler Kernel (`KERNEL=lts` für den Standard-Kernel), Swapfile, monatlicher btrfs-Scrub, Store-Optimierung
- PipeWire mit ALSA (inkl. 32 bit), PulseAudio und JACK
- fwupd für Firmware-Updates
- Systempakete: git, nixfmt, pciutils, usbutils, smartmontools, btrfs-progs, compsize, htop, nom, nvd u. a.

## Abfragen

Datenträger, Version (Release/unstable), Tastatur, Sprache, Desktop (GNOME, Plasma 6, COSMIC, Xfce, Cinnamon, keiner) minimal oder vollständig, Flatpak + Flathub, Unfree, Verschlüsselung, UKI, Silent Boot (Plymouth), Auto-Updates, Shell (bash/zsh, optional oh-my-zsh mit fertiger `~/.zshrc`), Hostname, Benutzer, Swap.

Alle Abfragen lassen sich per Umgebungsvariable vorbelegen, siehe Kopf von `install.sh`.

## Secure Boot nach der Installation (nur mit UKI)

1. `sudo sbctl verify`
2. Im Firmware-Setup Secure Boot einschalten und in den Setup Mode setzen
3. `sudo sbctl enroll-keys --microsoft`, neu starten, `bootctl status`

**Achtung:** Die gewählte Platte wird komplett gelöscht.
