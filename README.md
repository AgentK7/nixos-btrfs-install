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

In der Plattenauswahl stehen NVMe-SSDs oben (vorausgewählt ist die erste), USB-Sticks und Wechseldatenträger unten.

Jede Frage lässt sich vorbelegen und wird dann übersprungen, z. B. die Zielplatte, als Argument
(`sudo bash i.sh DISK=/dev/nvme0n1`) oder als Umgebungsvariable (`DISK=/dev/nvme0n1 sudo bash i.sh`).
Umgebungsvariablen dürfen vor oder nach `sudo` stehen; `sudo` verwirft sie zwar, das Skript holt die bekannten Namen
aber aus dem Aufruf zurück. Es zeigt an, was es übernommen hat; Argumente haben Vorrang.

Tastatur, Sprache und Zeitzone schlägt das Skript passend vor: aus dem Live-System (grafischer Stick) oder nach Standort
über den GeoIP-Dienst von Ubuntu (`geoip.ubuntu.com`, abschaltbar mit `GEOIP=n`).

## Sicherheit beim Installieren

- Die erzeugte Konfiguration wird **vor** dem Löschen gegen die gewählte NixOS-Version geprüft. Ist sie fehlerhaft, bricht das Skript ab, ohne etwas anzufassen.
- Schlägt `nixos-install` fehl, kannst du die Konfiguration bearbeiten und es erneut versuchen.
- Belegte Platten (Swap, LVM, LUKS, RAID) werden vor dem Partitionieren freigegeben.
- Plattenzustand per SMART: Bei Fehlern oder starker Abnutzung (defekte Sektoren, NVMe ≥ 90 % verbraucht) warnt das Skript und fragt, ob es trotzdem weitermachen soll.
- Komplettes Protokoll unter `/var/log/nixos-install.log`.

## Mehrere Rechner gleich installieren

Alle Antworten landen in `/etc/nixos/install-antworten.env`. Damit läuft die nächste Installation ohne Rückfragen (bis auf Passwörter und die Sicherheitsabfrage):

```bash
DISK=/dev/nvme0n1 ANTWORTEN=/pfad/install-antworten.env sudo -E bash i.sh
ANTWORTEN=https://server/install-antworten.env sudo -E bash i.sh
```

Die Datei wird nur gelesen, nicht ausgeführt. Grafik, Swap-Größe und feste IP ggf. pro Rechner anpassen.

**Hostname automatisch:** `NIX_HOSTNAME=auto` ergibt `pc-<Seriennummer>` (ohne brauchbare Seriennummer: die letzten
6 Stellen der MAC-Adresse), `NIX_HOSTNAME=raum12-auto` ergibt `raum12-<…>`. In der Antwortdatei bleibt `auto` stehen,
so bekommt jeder Rechner aus derselben Datei einen eigenen Namen.

**Binär-Cache im eigenen Netz:** Mit `CACHE_URL` und `CACHE_KEY` (oder bei den erweiterten Optionen) lädt die Installation
zuerst aus dem eigenen Cache, das neue System später auch. Eine Vollinstallation sind schnell mehrere GB je Rechner.
Als Cache eignet sich z. B. ein Proxy-Cache wie [ncps](https://github.com/kalbasit/ncps) oder [Attic](https://github.com/zhaofengli/attic),
oder [harmonia](https://github.com/nix-community/harmonia) auf einem Rechner, der dieselbe Konfiguration schon gebaut hat.

### Vollautomatisch

Mit `AUTO=j` stellt das Skript keine einzige Frage: Was nicht vorgegeben ist, bekommt den Vorschlag des Skripts.
Pflicht sind `DISK`, `NIX_USER` und als Schutz vor Tippfehlern `CONFIRM_DISK` (gleicher Wert wie `DISK`).
Passwörter kommen aus einer eigenen Datei, die nirgends gespeichert oder protokolliert wird:

```bash
AUTO=j DISK=/dev/nvme0n1 CONFIRM_DISK=/dev/nvme0n1 NIX_USER=alice \
  ANTWORTEN=antworten.env PASSWORT_DATEI=/root/geheim.env sudo -E bash i.sh
```

```bash
# geheim.env (chmod 600), ein Wert pro Zeile
LUKS_PASS='…'          # nur mit Verschlüsselung
USER_HASH='$y$j9T$…'   # oder USER_PASS='…'; Hash erzeugen mit: mkpasswd -m yescrypt
ROOT_HASH='…'          # optional, ohne bleibt root gesperrt (sudo reicht)
EXTRA_PASS='…'         # Startpasswort weiterer Benutzer, muss beim ersten Anmelden geändert werden
SAMBA_PASS='…'
BACKUP_PASS='…'
TS_AUTHKEY='tskey-…'   # Tailscale
```

Fehlt etwas Nötiges, bricht das Skript ab, **bevor** etwas gelöscht wird. Am Ende startet es neu (`REBOOT=n` verhindert das).

## Eigenes Installer-ISO

`build-iso.sh` baut einen NixOS-Stick mit eingebautem Installer (braucht Nix, also NixOS oder Nix auf einem anderen Linux):

```bash
curl -LO https://raw.githubusercontent.com/AgentK7/nixos-btrfs-install/main/build-iso.sh
bash build-iso.sh --antworten antworten.env --passwoerter geheim.env --auto --tastatur de
sudo dd if=nixos-btrfs-installer-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

| Option | Wirkung |
|---|---|
| `--antworten DATEI` | Antwortdatei einbauen |
| `--passwoerter DATEI` | Passwortdatei einbauen (liegt lesbar auf dem Stick, für Benutzer besser `*_HASH`) |
| `--auto` | Ohne Rückfragen: Zielplatte ist die einzige interne Platte, vorher 30 s Countdown, jede Taste bricht ab |
| `--disk GERÄT` / `--warten SEK` | Feste Zielplatte bzw. Länge des Countdowns |
| `--wlan SSID PASSWORT` | WLAN für das Live-System, wird ins neue System übernommen |
| `--ssh-key DATEI\|gh:NAME` | Fernzugriff auf das Live-System (`ssh nixos@<rechner>`) |
| `--tastatur LAYOUT` | Konsolen-Tastatur des Sticks (Standard: aus der Antwortdatei) |
| `--proxy URL` / `--ca DATEI` | Proxy bzw. eigenes CA-Zertifikat (z. B. Schulnetz mit HTTPS-Prüfung); beides gilt auch im neuen System |
| `--kein-autostart` | Installer nicht automatisch starten, nur Befehl `nixos-btrfs-install` |
| `--version` | `release` (Standard), `unstable` oder z. B. `26.05` |

Ohne `--auto` startet auf dem Stick der normale Installer mit Menüs (vorbelegt mit der Antwortdatei); fehlt das Netz, öffnet sich
erst die WLAN-Auswahl. Werkzeuge wie `dialog`, `smartctl` und `sbctl` sind schon auf dem Stick.

## Netzwerk

- **WLAN übernehmen:** Ist im Live-System ein WLAN verbunden, kopiert das Skript die Verbindung ins neue System – es ist nach dem ersten Start sofort online.
- **Server (ohne Desktop):** DHCP oder feste IP (IPv4, optional IPv6) über systemd-networkd; Vorschläge kommen aus der aktuellen Verbindung.
- **VPN:** Tailscale (mit Auth-Key meldet es sich beim ersten Start selbst an) oder WireGuard (vorhandene `wg0.conf` als Pfad oder https-URL, `ListenPort` wird in der Firewall geöffnet).
  Tailscale lässt sich auch bei den weiteren Programmen ankreuzen (`APP_TAILSCALE`). Mit Desktop kommt eine Oberfläche dazu
  (KTailctl unter Plasma, sonst Trayscale), und der Hauptbenutzer darf Tailscale ohne sudo steuern (`--operator`).
- **fail2ban** für SSH, wenn SSH eingerichtet wird.
- **DNS über TLS** (systemd-resolved): Quad9, Cloudflare oder ein eigener Server (`IP#Name`). Die DNS-Server aus dem Netz
  werden dann nicht verwendet. Geht nicht in Netzen, die Port 853 sperren (manche Schul- und Firmennetze, Hotel-WLAN mit Anmeldeseite).
- **Wake-on-LAN** (nur ohne Desktop): Magic Packet für alle Netzwerkkarten mit Kabel. Im BIOS muss es ggf. auch erlaubt sein.
- **Entsperren per SSH:** Verschlüsselte Rechner (Standard bei Servern) lassen sich beim Start über `ssh -p 2222 root@<rechner>`
  entsperren – nach dem Login fragt der Rechner direkt nach dem LUKS-Passwort. Läuft nur über Kabel; der Fingerabdruck des
  eigenen Start-Schlüssels steht am Ende der Installation.

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
- Kernel zur Wahl (siehe unten), dazu optional Leistungs-Optimierungen
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
- Optional: Drucken (mit Treibern für HP, Brother, Epson, Gutenprint, foo2zjs, splix), Bluetooth, Samba (Client oder Server), Flatpak + Flathub, SSH nur mit Schlüssel
- Laptops mit unterstützter Ladegrenze (ThinkPad, viele ASUS, Dell, Framework): Akku nur bis z. B. 80 % laden
- Gaming (nur mit Desktop, siehe unten): Steam, RetroArch und Emulatoren zum Ankreuzen, dazu Gamemode und Controller-Regeln
- Weitere Programme nach Kategorien (nur mit Desktop, siehe unten)
- Schriften: Noto mit Emoji und CJK, JetBrains Mono Nerd Font
- zsh mit fertiger `~/.zshrc`, optional oh-my-zsh; weitere Benutzer ohne Admin-Rechte
- Optional [home-manager](https://github.com/nix-community/home-manager): Shell, Aliase und Git-Identität in `/etc/nixos/home.nix`
- Systempakete: git, nixfmt, vim, btop, ripgrep, fd, bat, jq, tmux, ncdu, nvme-cli, inxi, hyfetch, unrar, dig, nmap, tcpdump, iperf3, nix-tree, nh, direnv u. a.
  (`unrar` ist unfrei, ohne Unfree kommt `unrar-free`)

## Kernel und Leistung

| Auswahl (`KERNEL`) | Paket | Hinweis |
|---|---|---|
| `latest` (Standard) | `linuxPackages_latest` | neuester stabiler Kernel |
| `lts` (Standard mit NVIDIA) | `linuxPackages` | am längsten gepflegt, NVIDIA-Treiber passen sicher |
| `xanmod` | `linuxPackages_xanmod` | XanMod auf LTS-Basis, für Desktop und Spiele optimiert |
| `xanmod_latest` | `linuxPackages_xanmod_latest` | XanMod aktuell |
| `zen` | `linuxPackages_zen` | Zen, für Desktop und Spiele optimiert |

Alle kommen fertig aus dem Binär-Cache. Den CachyOS-Kernel gibt es nicht in nixpkgs (nur über fremde Flakes mit eigenem
Cache), deshalb fehlt er hier; der wichtigste Teil davon, ein besserer Scheduler, kommt mit den Optimierungen:

**Leistungs-Optimierungen** (`TUNING`, Standard: ja)
- sched-ext-Scheduler `scx_lavd` (nur mit Desktop): hält den Desktop unter Last flüssig, Valve nutzt ihn auf dem Steam Deck.
  Läuft als BPF-Programm auf allen Kerneln oben; stürzt er ab, übernimmt der normale Scheduler.
- zram-Tuning: `vm.swappiness=180`, `page-cluster=0` und Watermark-Werte wie bei Fedora und Pop!_OS
- TCP BBR mit `fq`: schneller bei WLAN und Uploads

Mit Gaming zusätzlich `kernel.split_lock_mitigate=0` (wie SteamOS) und auf Wunsch ananicy-cpp mit den CachyOS-Regeln.
Bewusst nicht: `mitigations=off` (Sicherheitslücken für wenig Gewinn) und selbst gebaute Kernel (kein Cache, stundenlanges Bauen).

## Gaming

Mit Desktop fragt das Skript, ob Gaming eingerichtet werden soll. Dann gibt es eine Liste zum Ankreuzen:

| Auswahl | Paket | Variable |
|---|---|---|
| Steam (mit Proton) | `programs.steam` | `STEAM` |
| RetroArch: NES, SNES, N64, Mega Drive, PS1, GB/GBC/GBA | `retroarch.withCores` | `RETROARCH` |
| PlayStation 2 | PCSX2 | `EMU_PS2` |
| PlayStation 3 | RPCS3 | `EMU_PS3` |
| PSP | PPSSPP | `EMU_PSP` |
| GameCube / Wii | Dolphin | `EMU_GCWII` |
| Wii U | Cemu | `EMU_WIIU` |
| Switch | Ryubing und Eden | `EMU_SWITCH` |
| 3DS | Azahar | `EMU_3DS` |
| Nintendo DS | melonDS | `EMU_NDS` |
| Game Boy / Color / Advance | mGBA | `EMU_GBA` |
| Nintendo 64 | RMG | `EMU_N64` |
| Xbox Classic | xemu | `EMU_XBOX` |
| Dreamcast | Flycast | `EMU_DC` |

Immer dabei: Gamemode (`gamemoderun <programm>`) und udev-Regeln, damit Controller ohne root funktionieren
(Steam-Hardware, DualShock/DualSense, Switch Pro, Joy-Cons, 8BitDo; bei Dolphin auch der GameCube-Adapter).
Steam, RPCS3 und der Mega-Drive-Kern von RetroArch schalten Unfree ein.
RPCS3 liegt wegen der Lizenz nicht im Binär-Cache und wird bei der Installation kompiliert (dauert deutlich länger).
Ohne Abfrage: `GAMING=j STEAM=j EMU_PS2=j EMU_SWITCH=j …`. Ältere Antwortdateien mit `STEAM=j` funktionieren weiter.

### VR

Mit Gaming fragt das Skript nach der VR-Brille (`VR`):

| Auswahl | Für | Eingerichtet wird |
|---|---|---|
| `steamvr` | Valve Index, HTC Vive, Bigscreen Beyond u. a. (Lighthouse) | Steam mit SteamVR, udev-Regeln |
| `wivrn` | Meta Quest, Pico u. a. kabellos (empfohlen für Quest) | `services.wivrn` mit offener Firewall, Autostart, hoher Priorität; Steam- und OpenVR-Spiele (xrizer) laufen darüber |
| `alvr` | Meta Quest, Pico u. a. kabellos über SteamVR | `programs.alvr` mit offener Firewall |
| `rift` | Oculus Rift CV1 | [RiftLinux](https://github.com/AIIX/RiftLinux) (siehe unten) |
| `monado` | andere PC-Brillen: Rift S, Windows Mixed Reality u. a. | `services.monado` als OpenXR-Standard, xrizer für SteamVR-Spiele |

Immer dabei: [WayVR](https://github.com/wlx-team/wayvr) für Desktop und Fenster in der Brille (mit SteamVR: `steam-run wayvr`).
SteamVR braucht auf NixOS einmal von Hand: `sudo setcap CAP_SYS_NICE=eip ~/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrcompositor-launcher`.

**RiftLinux** (Oculus Rift CV1: Brille, Constellation-Sensoren, Touch-Controller, SteamVR und OpenXR) gibt es nicht in nixpkgs.
Das Skript holt die neueste Version vom Releases-Bereich (oder `RIFT_VERSION`, `RIFT_SHA256`) und schreibt
`/etc/nixos/riftlinux.nix`: ein Paket aus dem offiziellen Archiv mit Prüfsumme, die udev-Regeln, die Anmeldung bei SteamVR
beim Einstecken und Anmelden, und RealtimeKit. Der SteamVR-Treiber bleibt unverändert (er läuft in Steams eigenem Container),
nur die eigene OpenXR-Laufzeit wird an NixOS angepasst. Zwei kleine Änderungen am Skript `riftlinux-setup` sind nötig:
Es findet den Treiber im Nix-Store, und seine Kopie im Home-Verzeichnis wird beschreibbar (sonst scheitert die Anmeldung,
weil Dateien im Store schreibgeschützt sind). Danach: Steam einmal neu starten, Rift anstecken, aufsetzen.
`riftlinux-setup check` funktioniert, `riftlinux-setup fix` nicht (NixOS verwaltet `/etc` selbst). Neue Version: `version`
und `sha256` in `/etc/nixos/riftlinux.nix` ändern, dann `sudo nixos-rebuild switch`.
Für ein schon installiertes NixOS gibt es `install-riftlinux.sh` (nächster Abschnitt).

BIOS, Firmware und Schlüssel (PS2-BIOS, PS3-Firmware, Switch `prod.keys` und Firmware, Xbox-BIOS und MCPX-ROM)
liefert kein Paket mit, sie kommen aus den eigenen Konsolen.

### Oculus Rift CV1 (RiftLinux)

`install-riftlinux.sh` richtet auf einem fertig installierten NixOS den Rift-CV1-Treiber
[RiftLinux](https://github.com/AIIX/RiftLinux) ein (SteamVR und OpenXR, Headset, Sensoren und Touch-Controller):

```bash
curl -L is.gd/nixosrift -o rift.sh && sudo bash rift.sh
```

Langform: `https://raw.githubusercontent.com/AgentK7/nixos-btrfs-install/main/install-riftlinux.sh`

- Stellt `/etc/nixos` auf Flakes um. Channel-Importe, wie sie dieser Installer anlegt (`<home-manager/nixos>`,
  `<nixos-hardware/…>`), werden zu Flake-Inputs, ebenso `<nixpkgs/…>`, weitere Channels und `builtins.fetchTarball`
  ohne Hash. Vorher wird `/etc/nixos` nach `/etc/nixos.bak-<Datum>` gesichert, scheitert der Build, wird zurückgesetzt.
- Paketiert das offizielle Release in `/etc/nixos/riftlinux.nix` (der SteamVR-Treiber bleibt unverändert, wie
  RiftLinux es verlangt): udev-Regeln, Anmeldung bei SteamVR beim Login und Einstecken, rtkit, Steam.
- Gibt es schon eine `flake.nix`, legt es nur `riftlinux.nix` an und nennt die Zeilen zum Ergänzen.
- Danach Steam einmal neu starten, Rift anstecken und SteamVR starten; `riftlinux-setup check` prüft die Einrichtung.

Geprüft mit den Konfigurationen aller Test-Szenarien (`tests/szenarien/`), u. a. UKI mit lanzaboote, home-manager und
nixos-hardware: Nach der Umstellung wertet jedes System vollständig aus. Mit einem echten Headset ist es noch nicht getestet.

## Weitere Programme

Mit Desktop fragt das Skript, ob weitere Programme dazukommen sollen. Erst werden Kategorien angekreuzt,
dann die Programme darin (vorausgewählt ist jeweils das Übliche, **fett** unten):

| Kategorie (Variable) | Programme |
|---|---|
| Video und Musik (`SW_MEDIA`) | **VLC**, **Codecs** (FFmpeg, GStreamer good/bad/ugly/libav), mpv, Strawberry, Spotify, Audacity, OBS Studio, Kdenlive, HandBrake |
| Office und Dokumente (`SW_OFFICE`) | **LibreOffice** (mit Rechtschreibprüfung de/en), ONLYOFFICE, Okular, PDF Arranger, Xournal++, Obsidian, Joplin |
| Internet und Dateien (`SW_WEB`) | Chromium, Google Chrome, Brave, Tor Browser, Nextcloud, qBittorrent, FileZilla, Tailscale, LocalSend |
| Kommunikation (`SW_CHAT`) | **Thunderbird**, Signal, Telegram, Element, Discord, Vesktop, Zoom, Teams (inoffiziell), Slack |
| Grafik, Foto und 3D (`SW_GRAPHICS`) | **GIMP**, Inkscape, Krita, darktable, Blender, FreeCAD |
| 3D-Druck (`SW_PRINT`) | **PrusaSlicer**, **OrcaSlicer** (Flatpak von Flathub), Anycubic Slicer Next (Flatpak), UltiMaker Cura, Bambu Studio, OpenSCAD, MeshLab, Pronterface |
| Entwicklung (`SW_DEV`) | **VS Code**, VSCodium, Zed, Neovim, C/C++-Werkzeuge, Python mit uv, Node.js, Rust, Go, **gh und lazygit**, DBeaver, Bruno |
| System und Werkzeuge (`SW_TOOLS`) | **KeePassXC**, Bitwarden, Remmina, RustDesk, Wireshark, GParted, Impression, Mission Center, Wine mit winetricks, Bottles |

Ohne Abfrage: `SOFTWARE=j APP_VLC=j APP_VSCODE=j …`, die Kategorie schaltet sich dabei selbst ein. Alle Variablen
stehen in der Liste `SW_APPS` im Skript. Unfreie Programme (VS Code, Chrome, Spotify, Discord, Zoom, Slack, Obsidian)
schalten Unfree ein, ebenso Bottles (unter unstable mit unfreier Abhängigkeit).
Wireshark: Der Hauptbenutzer kommt in die Gruppe `wireshark` und darf ohne root mitschneiden.
Pronterface: Der Hauptbenutzer kommt in die Gruppe `dialout` (Drucker per USB).
Bambu Studio liegt nicht im Binär-Cache und wird bei der Installation kompiliert.

**Flatpaks:** OrcaSlicer kommt von Flathub, Anycubic Slicer Next (nicht in nixpkgs) aus dem inoffiziellen Flatpak-Repo
[RoccoRakete/anycubic-slicer-next-flatpak](https://github.com/RoccoRakete/anycubic-slicer-next-flatpak)
(signiert, Laufzeit von Flathub). Ist eins davon gewählt, schaltet das Skript Flatpak ein. Installiert werden sie beim
ersten Start mit Internet durch den Dienst `flatpak-repo`; die GNOME-Laufzeit teilen sich beide (zusammen etwa 800 MB,
Fortschritt: `journalctl -fu flatpak-repo`). Updates kommen mit `flatpak update` oder über die Software-Verwaltung.
Weitere Flatpaks lassen sich in `SW_APPS` mit `flatpak:<Repo>:<App-ID>` eintragen, eigene Repos in `FLATPAK_REMOTES`.

## Secure Boot (nur mit UKI)

**Am einfachsten:** Vor der Installation im Firmware-Setup Secure Boot einschalten und in den **Setup Mode** setzen
(„Reset to Setup Mode“ / „Clear Secure Boot keys“, nicht „Restore Factory Keys“). Dann trägt das Skript die eigenen
Schlüssel plus die von Microsoft selbst ein, nachdem es geprüft hat, dass Bootloader und Kernel-Images signiert sind.
Danach startet der NixOS-Stick nur noch mit ausgeschaltetem Secure Boot.

**TPM2:** Ein einmaliger Schlüssel auf der verschlüsselten Platte meldet beim ersten Start mit aktivem Secure Boot den TPM an
und wird danach gelöscht. Ab dann startet der Rechner ohne LUKS-Passwort (das Passwort bleibt als Rückfall).

Ohne Setup Mode, von Hand nach dem ersten Start:

1. `sudo sbctl verify`: ✓ bei `BOOTX64.EFI`, `systemd-bootx64.efi` und `/EFI/Linux/nixos-generation-*.efi`.
   **✗ bei `/EFI/nixos/kernel-*.efi` ist richtig so** – die signierte UKI prüft den Kernel über seine Prüfsumme.
   Den Kernel nicht mit sbctl signieren, sonst startet die Generation nicht mehr („Kernel hash does not match“).
2. Im Firmware-Setup Secure Boot einschalten und in den Setup Mode setzen
3. `sudo sbctl enroll-keys --microsoft`, neu starten, `bootctl status`
4. TPM2 meldet sich beim nächsten Start selbst an. Nach Firmware-Updates ggf. erneut: `sudo luks-tpm2-enroll`

Kernel versehentlich signiert? Signatur aus sbctl entfernen (`sudo sbctl remove-file <datei>`),
`sudo rm /boot/EFI/nixos/kernel-*.efi` und `sudo nixos-rebuild boot` – lzbt installiert den
Kernel dann im Original neu.

## Prüfung

[`tests/eval.sh`](tests/eval.sh) baut die `configuration.nix` für mehrere Szenarien (`tests/szenarien/`) und wertet
sie gegen das aktuelle Release oder unstable aus. So fallen entfernte oder umbenannte NixOS-Optionen auf, bevor eine
Installation daran scheitert: `tests/eval.sh release` oder `tests/eval.sh unstable server` (braucht Nix, installiert nichts).

## Nach der Installation

- Fingerabdruck einlernen: `fprintd-enroll` oder Systemeinstellungen → Benutzer
- Zweiten YubiKey als Ersatz für sudo: `pamu2fcfg -n -o pam://<hostname> -i pam://<hostname> >> ~/.config/Yubico/u2f_keys`
- Kanäle (nixos, home-manager, nixos-hardware) aktualisieren: `sudo nix-channel --update`, dann `sudo nixos-rebuild switch`.
  Nach `install-riftlinux.sh` (Flakes) stattdessen: `sudo nix flake update --flake /etc/nixos`, dann `sudo nixos-rebuild switch`

**Achtung:** Ohne Dual-Boot wird die gewählte Platte komplett gelöscht.
