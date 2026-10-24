# nixos-btrfs-install

Interaktives Installer-Skript für NixOS auf btrfs, wahlweise aktuelles Release oder unstable.

Im NixOS-Live-System als root (UEFI mit ausgeschaltetem Secure Boot oder Legacy-BIOS):

```bash
curl -L is.gd/B1rzoc -o i.sh && sudo bash i.sh
```

Langform: `https://raw.githubusercontent.com/AgentK7/nixos-btrfs-install/main/install.sh`

## Bedienung

Fragen erscheinen als Menüs mit Pfeiltasten und Checklisten (`dialog`). Mit `TUI=n` gibt es reine Textabfragen,
ohne Terminal (z. B. über eine Pipe) schaltet das Skript automatisch darauf um.

Die erste Frage ist **„Erweiterte Optionen anzeigen?“** (Standard: nein). Nur dort gibt es Dual-Boot und die zweite Platte.

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

Die Datei wird nur gelesen, nicht ausgeführt. Hostname, Grafik, Swap-Größe und feste IP ggf. pro Rechner anpassen.

### Vollautomatisch

Mit `AUTO=j` stellt das Skript keine einzige Frage: Was nicht vorgegeben ist, bekommt den Vorschlag des Skripts.
Pflicht sind `DISK`, `NIX_USER` und als Schutz vor Tippfehlern `CONFIRM_DISK` (gleicher Wert wie `DISK`).
Passwörter kommen aus einer eigenen Datei, die nirgends gespeichert oder protokolliert wird:

```bash
AUTO=j DISK=/dev/nvme0n1 CONFIRM_DISK=/dev/nvme0n1 NIX_USER=alice \
  ANTWORTEN=antworten.env PASSWORT_DATEI=/root/geheim.env sudo -E bash i.sh
```

```bash
# geheim.env (chmod 600)
LUKS_PASS='…'          # nur mit Verschlüsselung
USER_HASH='$y$j9T$…'   # oder USER_PASS='…'; Hash erzeugen mit: mkpasswd -m yescrypt
ROOT_HASH='…'          # optional, ohne bleibt root gesperrt (sudo reicht)
EXTRA_PASS='…'         # Startpasswort weiterer Benutzer, muss beim ersten Anmelden geändert werden
SAMBA_PASS='…'  BACKUP_PASS='…'  TS_AUTHKEY='tskey-…'
```

Fehlt etwas Nötiges, bricht das Skript ab, **bevor** etwas gelöscht wird. Am Ende startet es neu (`REBOOT=n` verhindert das).

## Netzwerk

- **WLAN übernehmen:** Ist im Live-System ein WLAN verbunden, kopiert das Skript die Verbindung ins neue System – es ist nach dem ersten Start sofort online.
- **Server (ohne Desktop):** DHCP oder feste IP (IPv4, optional IPv6) über systemd-networkd; Vorschläge kommen aus der aktuellen Verbindung.
- **VPN:** Tailscale (mit Auth-Key meldet es sich beim ersten Start selbst an) oder WireGuard (vorhandene `wg0.conf` als Pfad oder https-URL, `ListenPort` wird in der Firewall geöffnet).
- **fail2ban** für SSH, wenn SSH eingerichtet wird.

## Erweiterte Optionen

**Dual-Boot** (nur UEFI, GPT): NixOS kommt in den größten freien Bereich, vorhandene Partitionen bleiben unangetastet.
Vorher im anderen System Platz freigeben (Windows: Datenträgerverwaltung → Volume verkleinern, mindestens 20 GiB).
- Vorhandene EFI-Partition wird mitbenutzt; systemd-boot zeigt Windows im Bootmenü.
- Ist sie kleiner als 1 GiB (Windows legt meist 100 MiB an), bekommt NixOS eine eigene 1-GiB-Boot-Partition (XBOOTLDR) für Kernel und initrd. UKI gibt es dann nicht.
- Windows erkannt: Hardware-Uhr auf Ortszeit. In Windows vorher Schnellstart ausschalten und den BitLocker-Wiederherstellungsschlüssel bereithalten.

**Zweite Platte:**
- *RAID1:* btrfs-Spiegel über beide Platten (Daten und Metadaten), mit Verschlüsselung beide in LUKS (ein Passwort). Kein Swapfile, nur zram.
- *Datenplatte:* neu formatiert, btrfs unter `/data` (`nofail`, startet auch ohne die Platte).
- *Vorhandene Daten:* eine Partition (ext4, btrfs, xfs, NTFS, exFAT, FAT) bleibt erhalten und wird unter `/data` eingehängt.

## Was es einrichtet

- UEFI: GPT mit 1 GiB EFI-Partition (`/boot`), systemd-boot oder UKI
- Legacy-BIOS (automatisch erkannt, erzwingbar mit `BOOT_MODE=bios`): GPT mit BIOS-Boot-Partition für GRUB und 1 GiB `/boot` (ext4)
- Rest btrfs, optional in LUKS2
- Subvolumes `@`, `@home`, `@nix`, `@log`, `@swap` mit `compress=zstd,noatime`, optional snapper-Snapshots für `/home`
- systemd-boot oder UKI über [lanzaboote](https://github.com/nix-community/lanzaboote) v1.2.0, optional TPM2-Entsperren für LUKS
- Neuester stabiler Kernel (`KERNEL=lts` für den Standard-Kernel), bei NVIDIA auf Wunsch LTS
- Grafik: Intel, AMD, NVIDIA (offene Module oder Treiber 580), NVIDIA-PRIME für Laptops, nouveau
- Hardware-Profil aus [nixos-hardware](https://github.com/NixOS/nixos-hardware): Modell wird erkannt, passende Profile werden vorgeschlagen
- Fingerabdruckleser (erkannt über die Geräteliste von libfprint) für sudo, Admin-Abfragen und Sperrbildschirm
- YubiKey/FIDO2 zum Entsperren der Verschlüsselung und für sudo, wird während der Installation angemeldet
- Laptops: Ruhezustand (Swapfile und resume-Offset automatisch), Verhalten beim Zuklappen, Energieprofile, thermald auf Intel
- Swapfile plus zram, btrfs-Scrub, Store-Optimierung, fwupd, smartd (Warnung bei sterbenden Platten)
- Wöchentliches Aufräumen alter Generationen (`nh clean`, die letzten 10 bleiben)
- Rettungseinträge im Bootmenü: Memtest86+ und netboot.xyz (systemd-boot) bzw. Memtest86+ (GRUB)
- Backup von `/home` mit restic auf einen anderen Rechner (SFTP, REST-Server, S3 …), täglich
- VMs (libvirt, virt-manager), Container (Podman oder Docker)
- PipeWire mit ALSA (inkl. 32 bit), PulseAudio und JACK
- Optional: Drucken, Bluetooth, Steam + Gamemode, Samba (Client oder Server), Flatpak + Flathub, SSH nur mit Schlüssel
- Schriften: Noto mit Emoji und CJK, JetBrains Mono Nerd Font
- zsh mit fertiger `~/.zshrc`, optional oh-my-zsh; weitere Benutzer ohne Admin-Rechte
- Optional [home-manager](https://github.com/nix-community/home-manager): Shell, Aliase und Git-Identität in `/etc/nixos/home.nix`
- Systempakete: git, nixfmt, vim, btop, ripgrep, fd, bat, jq, tmux, ncdu, nvme-cli, inxi, dig, nmap, tcpdump, iperf3, nix-tree, nh, direnv u. a.

## Secure Boot nach der Installation (nur mit UKI)

1. `sudo sbctl verify`: ✓ bei `BOOTX64.EFI`, `systemd-bootx64.efi` und `/EFI/Linux/nixos-generation-*.efi`.
   **✗ bei `/EFI/nixos/kernel-*.efi` ist richtig so** – die signierte UKI prüft den Kernel über seine Prüfsumme.
   Den Kernel nicht mit sbctl signieren, sonst startet die Generation nicht mehr („Kernel hash does not match“).
2. Im Firmware-Setup Secure Boot einschalten und in den Setup Mode setzen
3. `sudo sbctl enroll-keys --microsoft`, neu starten, `bootctl status`
4. Mit TPM2: `sudo luks-tpm2-enroll`, danach startet das System ohne LUKS-Passwort

Kernel versehentlich signiert? Signatur aus sbctl entfernen (`sudo sbctl remove-file <datei>`),
`sudo rm /boot/EFI/nixos/kernel-*.efi` und `sudo nixos-rebuild boot` – lzbt installiert den
Kernel dann im Original neu.

## Nach der Installation

- Fingerabdruck einlernen: `fprintd-enroll` oder Systemeinstellungen → Benutzer
- Zweiten YubiKey als Ersatz für sudo: `pamu2fcfg -n -o pam://<hostname> -i pam://<hostname> >> ~/.config/Yubico/u2f_keys`
- Kanäle (nixos, home-manager, nixos-hardware) aktualisieren: `sudo nix-channel --update`, dann `sudo nixos-rebuild switch`

**Achtung:** Ohne Dual-Boot wird die gewählte Platte komplett gelöscht.
