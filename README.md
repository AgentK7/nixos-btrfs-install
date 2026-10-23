# nixos-btrfs-install

Interaktives Installer-Skript für NixOS 26.05 auf btrfs.

Im NixOS-Live-System (UEFI) als root:

```bash
curl -L https://raw.githubusercontent.com/AgentK7/nixos-btrfs-install/main/install.sh -o i.sh && sudo bash i.sh
```

## Was es einrichtet

- GPT: 1 GiB EFI-Partition (`/boot`), Rest btrfs, optional in LUKS2
- Subvolumes `@`, `@home`, `@nix`, `@log`, `@swap` mit `compress=zstd,noatime`
- systemd-boot, Swapfile, monatlicher btrfs-Scrub, Store-Optimierung
- PipeWire mit ALSA (inkl. 32 bit), PulseAudio und JACK
- Abfragen: Datenträger, Tastatur, Sprache, Desktop (GNOME, Plasma 6, COSMIC, Xfce, Cinnamon, keiner), Flatpak + Flathub, Unfree, Verschlüsselung, Auto-Updates, Shell (bash/zsh, optional oh-my-zsh)

Alle Abfragen lassen sich per Umgebungsvariable vorbelegen, siehe Kopf von `install.sh`.

**Achtung:** Die gewählte Platte wird komplett gelöscht.
