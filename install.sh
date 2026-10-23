#!/usr/bin/env bash
# NixOS 26.05 auf btrfs installieren
#   UEFI + systemd-boot, ESP >= 1 GiB, Rest btrfs (optional in LUKS2)
#   Subvolumes @ @home @nix @log @swap, zstd, Swapfile, PipeWire (ALSA/32 bit, Pulse, JACK)
#
# Aufruf im NixOS-Live-System als root:
#   bash nixos-btrfs-install.sh
#
# Jede Abfrage lässt sich per Umgebungsvariable vorbelegen, z. B.:
#   DISK=/dev/nvme0n1 KB=de LOCALE=de_DE.UTF-8 DESKTOP=plasma FLATPAK=j UNFREE=j ENCRYPT=j \
#   AUTOUPDATE=n LOGIN_SHELL=zsh OHMYZSH=j NIX_HOSTNAME=nixos NIX_USER=alice SWAP_GB=8 \
#   bash nixos-btrfs-install.sh
#
#   KB          Tastatur als xkb-Layout[:Variante], z. B. de, de:nodeadkeys, us:intl
#   LOCALE      z. B. de_DE.UTF-8 oder en_US.UTF-8+de_DE.UTF-8 (Sprache + Formate)
#   DESKTOP     gnome | plasma | cosmic | xfce | cinnamon | none
#   LOGIN_SHELL bash | zsh
# Ohne Abfrage, nur per Variable: TIMEZONE (Europe/Berlin), ESP_GB (1), COMPRESS (zstd)

set -Eeuo pipefail

# ---------- Hilfsfunktionen ----------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_bld=$'\e[1m'; c_rst=$'\e[0m'
info() { printf '\n%s==>%s %s%s%s\n' "$c_grn" "$c_rst" "$c_bld" "$*" "$c_rst"; }
warn() { printf '%s!!%s  %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%sFEHLER:%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }
trap 'die "Abbruch in Zeile $LINENO: $BASH_COMMAND"' ERR

is_yes() { [[ ${1,,} =~ ^(j|ja|y|yes|1)$ ]]; }

# ask VAR "Frage" "Standard" – Freitext, nur wenn VAR noch leer ist
ask() {
  local var=$1 prompt=$2 def=${3-} val
  val=${!var-}
  if [[ -z $val ]]; then
    read -rp "$prompt${def:+ [$def]}: " val
    val=${val:-$def}
  fi
  printf -v "$var" '%s' "$val"
}

# ask_yn VAR "Frage" j|n – setzt VAR auf 1 oder 0
ask_yn() {
  local var=$1 prompt=$2 def=$3 val hint
  val=${!var-}
  if [[ -z $val ]]; then
    if [[ $def == j ]]; then hint="J/n"; else hint="j/N"; fi
    read -rp "$prompt [$hint]: " val
    val=${val:-$def}
  fi
  if is_yes "$val"; then printf -v "$var" 1; else printf -v "$var" 0; fi
}

# choose VAR "Frage" Standardnummer "wert|Beschreibung" ... – nummeriertes Menü
choose() {
  local var=$1 prompt=$2 def=$3 i sel
  shift 3
  local opts=("$@")
  [[ -n ${!var-} ]] && return 0
  printf '\n%s\n' "$prompt"
  for i in "${!opts[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${opts[i]#*|}"
  done
  while true; do
    read -rp "Auswahl [$def]: " sel
    sel=${sel:-$def}
    if [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#opts[@]} )); then break; fi
    warn "Bitte eine Zahl von 1 bis ${#opts[@]} eingeben."
  done
  printf -v "$var" '%s' "${opts[sel - 1]%%|*}"
}

# emit "Überschrift" "Nix-Text" – schreibt einen Konfigurationsblock, wenn er nicht leer ist
emit() {
  [[ -n $2 ]] || return 0
  printf '\n  # %s\n%s\n' "$1" "$2"
}

# ---------- Vorabprüfungen ----------
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen (sudo -i)."
[[ -d /sys/firmware/efi ]] || die "Kein UEFI-Boot erkannt. Den USB-Stick im UEFI-Modus starten."
for cmd in parted partprobe wipefs mkfs.fat mkfs.btrfs btrfs cryptsetup nixos-generate-config nixos-install nixos-enter udevadm; do
  command -v "$cmd" >/dev/null || die "'$cmd' fehlt. Läuft das Skript im NixOS-Installer?"
done
ping -c1 -W3 cache.nixos.org >/dev/null 2>&1 || warn "Keine Verbindung zu cache.nixos.org. WLAN mit 'nmtui' einrichten."

# Reste eines abgebrochenen Laufs aufräumen
if mountpoint -q /mnt; then umount -R /mnt; fi
if [[ -e /dev/mapper/cryptroot ]]; then cryptsetup close cryptroot; fi

: "${TIMEZONE:=Europe/Berlin}"
: "${ESP_GB:=1}"
: "${COMPRESS:=zstd}"
[[ $ESP_GB =~ ^[0-9]+$ ]] && (( ESP_GB >= 1 )) || die "ESP_GB muss mindestens 1 sein."

# =====================================================================
#  Abfragen
# =====================================================================

# ---------- 1. Datenträger ----------
# Installationsmedium ermitteln, damit es nicht zur Auswahl steht
LIVE_DEV=""
if src=$(findmnt -no SOURCE /iso 2>/dev/null) && [[ -b $src ]]; then
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)
  LIVE_DEV=/dev/${pk:-$(basename "$src")}
fi

DISK_OPTS=()
while read -r name size model; do
  [[ $name == /dev/zram* || $name == "$LIVE_DEV" ]] && continue
  DISK_OPTS+=("$name|$(printf '%-16s %8s  %s' "$name" "$size" "${model:-}")")
done < <(lsblk -dpno NAME,SIZE,MODEL -e 7,11 | while read -r n rest; do
  [[ $(lsblk -dno TYPE "$n") == disk ]] && echo "$n $rest"
done)
(( ${#DISK_OPTS[@]} > 0 )) || die "Keine passende Platte gefunden."

choose DISK "Auf welchen Datenträger soll NixOS? (wird KOMPLETT gelöscht)" 1 "${DISK_OPTS[@]}"
[[ -b $DISK ]] || die "$DISK ist kein Blockgerät."
[[ $(lsblk -dno TYPE "$DISK") == disk ]] || die "$DISK ist keine ganze Platte."
[[ $DISK != "$LIVE_DEV" ]] || die "$DISK ist das Installationsmedium."
if lsblk -nro MOUNTPOINTS "$DISK" | grep -q .; then
  die "Auf $DISK ist noch etwas eingehängt. Erst aushängen."
fi

# ---------- 2. Tastaturlayout ----------
choose KB "Welches Tastaturlayout?" 1 \
  "de|Deutsch" \
  "de:nodeadkeys|Deutsch, ohne Tottasten" \
  "at|Österreich" \
  "ch|Schweiz (Deutsch)" \
  "us|Englisch (US)" \
  "us:intl|Englisch (US, international)" \
  "gb|Englisch (UK)" \
  "fr|Französisch" \
  "custom|Anderes (xkb-Layout selbst eingeben)"
if [[ $KB == custom ]]; then
  KB=""
  ask KB "xkb-Layout[:Variante], z. B. es oder us:dvorak"
fi
[[ $KB =~ ^[a-z]{2,}(:[a-z0-9_-]+)?$ ]] || die "Ungültiges Layout: $KB"
XKB_LAYOUT=${KB%%:*}
XKB_VARIANT=""
[[ $KB == *:* ]] && XKB_VARIANT=${KB#*:}

# Layout gleich für den Rest der Installation laden (nur auf der Textkonsole möglich)
if [[ $(tty 2>/dev/null) == /dev/tty* ]]; then
  case "$XKB_LAYOUT:$XKB_VARIANT" in
    de:nodeadkeys) km=de-latin1-nodeadkeys ;;
    gb:*)          km=uk ;;
    ch:*)          km=de_CH-latin1 ;;
    at:*)          km=de ;;
    *)             km=$XKB_LAYOUT ;;
  esac
  loadkeys "$km" >/dev/null 2>&1 || warn "Konsolen-Layout '$km' nicht gefunden, gilt erst im neuen System."
fi

# ---------- 3. Sprache ----------
choose LOCALE "Welche Systemsprache?" 1 \
  "de_DE.UTF-8|Deutsch (Deutschland)" \
  "de_AT.UTF-8|Deutsch (Österreich)" \
  "de_CH.UTF-8|Deutsch (Schweiz)" \
  "en_US.UTF-8|Englisch (US)" \
  "en_GB.UTF-8|Englisch (UK)" \
  "en_US.UTF-8+de_DE.UTF-8|Englisch, aber deutsche Formate (Datum, Zahlen, Papier)" \
  "custom|Andere (Locale selbst eingeben)"
if [[ $LOCALE == custom ]]; then
  LOCALE=""
  ask LOCALE "Locale, z. B. fr_FR.UTF-8"
fi
re_loc='^[a-z]{2,3}_[A-Z]{2}\.UTF-8(\+[a-z]{2,3}_[A-Z]{2}\.UTF-8)?$'
[[ $LOCALE =~ $re_loc ]] || die "Ungültige Locale: $LOCALE"
LANG_LOCALE=${LOCALE%%+*}
FORMAT_LOCALE=""
[[ $LOCALE == *+* ]] && FORMAT_LOCALE=${LOCALE#*+}

# ---------- 4. Desktop ----------
choose DESKTOP "Welche Desktop-Umgebung?" 2 \
  "gnome|GNOME" \
  "plasma|KDE Plasma 6" \
  "cosmic|COSMIC" \
  "xfce|Xfce" \
  "cinnamon|Cinnamon" \
  "none|Keine (nur Konsole, z. B. Server)"
case $DESKTOP in gnome|plasma|cosmic|xfce|cinnamon|none) ;; *) die "Unbekannter Desktop: $DESKTOP" ;; esac

# ---------- 5. Audio ----------
echo
echo "Audio: PipeWire mit ALSA (inkl. 32 bit), PulseAudio- und JACK-Unterstützung wird eingerichtet."

# ---------- 6.–10. Ja/Nein ----------
echo
if [[ $DESKTOP != none ]]; then
  ask_yn FLATPAK  "Flatpak mit Flathub einrichten?" j
else
  FLATPAK=0   # Flatpak braucht XDG-Portale, die erst ein Desktop mitbringt
fi
ask_yn UNFREE    "Unfreie Pakete erlauben (z. B. NVIDIA-Treiber, Steam)?" j
ask_yn ENCRYPT    "Datenträger mit LUKS verschlüsseln?" n
ask_yn AUTOUPDATE "Automatische Updates (nachts, ohne Neustart)?" n

choose LOGIN_SHELL "Welche Shell für den Benutzer?" 1 \
  "bash|Bash" \
  "zsh|Zsh"
case $LOGIN_SHELL in bash|zsh) ;; *) die "Unbekannte Shell: $LOGIN_SHELL" ;; esac
OHMYZSH=${OHMYZSH:-}
if [[ $LOGIN_SHELL == zsh ]]; then
  ask_yn OHMYZSH "oh-my-zsh mitinstallieren?" j
else
  OHMYZSH=0
fi

# ---------- Weitere Angaben ----------
echo
ask NIX_HOSTNAME "Hostname" "nixos"
[[ $NIX_HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Ungültiger Hostname."

ask NIX_USER "Benutzername"
[[ $NIX_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Ungültiger Benutzername (klein, a-z 0-9 _ -)."

ask SWAP_GB "Swapfile in GiB (0 = kein Swap)" "8"
[[ $SWAP_GB =~ ^[0-9]+$ ]] || die "Swap-Größe muss eine ganze Zahl sein."

# nvme0n1 -> nvme0n1p1, sda -> sda1
if [[ $DISK =~ [0-9]$ ]]; then P="${DISK}p"; else P="$DISK"; fi
ESP="${P}1"
ROOTPART="${P}2"
ESP_END_MIB=$(( 1 + ESP_GB * 1024 ))   # Start bei 1 MiB, damit die ESP volle ESP_GB GiB hat

yn() { if (( $1 )); then echo ja; else echo nein; fi; }

# ---------- Zusammenfassung ----------
info "Zusammenfassung"
cat <<EOF
  Datenträger:    $DISK
    ${ESP}  ${ESP_GB} GiB FAT32 -> /boot
    ${ROOTPART}  Rest, $( if (( ENCRYPT )); then echo "LUKS2 -> btrfs"; else echo "btrfs"; fi ) ($COMPRESS)
  Tastatur:       $XKB_LAYOUT${XKB_VARIANT:+ ($XKB_VARIANT)}
  Sprache:        $LANG_LOCALE${FORMAT_LOCALE:+, Formate $FORMAT_LOCALE}
  Zeitzone:       $TIMEZONE
  Desktop:        $DESKTOP
  Audio:          PipeWire (ALSA + 32 bit, Pulse, JACK)
  Flatpak:        $(yn "$FLATPAK")$( (( FLATPAK )) && echo " (Flathub)" )
  Unfree:         $(yn "$UNFREE")
  Verschlüsselt:  $(yn "$ENCRYPT")
  Auto-Updates:   $(yn "$AUTOUPDATE")
  Shell:          $LOGIN_SHELL$( [[ $LOGIN_SHELL == zsh ]] && echo " (oh-my-zsh: $(yn "$OHMYZSH"))" )
  Hostname:       $NIX_HOSTNAME
  Benutzer:       $NIX_USER
  Swap:           ${SWAP_GB} GiB
EOF
echo
warn "ALLE Daten auf $DISK werden gelöscht:"
lsblk -po NAME,SIZE,FSTYPE,LABEL "$DISK"
read -rp "Zum Fortfahren den Gerätenamen ($DISK) erneut eingeben: " confirm
[[ $confirm == "$DISK" ]] || die "Abgebrochen, nichts verändert."

# =====================================================================
#  Platte vorbereiten
# =====================================================================

info "Partitioniere $DISK"
# alte Signaturen der Partitionen und der Platte entfernen
while read -r part; do
  wipefs -af "$part" >/dev/null
done < <(lsblk -lnpo NAME "$DISK" | tail -n +2)
wipefs -af "$DISK" >/dev/null

parted -s "$DISK" -- \
  mklabel gpt \
  mkpart ESP fat32 1MiB "${ESP_END_MIB}MiB" \
  set 1 esp on \
  mkpart nixos btrfs "${ESP_END_MIB}MiB" 100%
partprobe "$DISK" || true
udevadm settle
[[ -b $ESP && -b $ROOTPART ]] || die "Partitionen $ESP / $ROOTPART nicht gefunden."

info "Formatiere ESP"
mkfs.fat -F 32 -n boot "$ESP" >/dev/null

if (( ENCRYPT )); then
  info "Richte LUKS2 ein – Passphrase zweimal eingeben, danach zum Öffnen ein drittes Mal"
  cryptsetup luksFormat --type luks2 --batch-mode --verify-passphrase "$ROOTPART"
  cryptsetup open "$ROOTPART" cryptroot
  BTRFS_DEV=/dev/mapper/cryptroot
else
  BTRFS_DEV=$ROOTPART
fi

info "Formatiere btrfs"
mkfs.btrfs -f -L nixos "$BTRFS_DEV" >/dev/null

info "Lege Subvolumes an"
SUBVOLS=(@ @home @nix @log)
if (( SWAP_GB > 0 )); then SUBVOLS+=(@swap); fi
mount "$BTRFS_DEV" /mnt
for sv in "${SUBVOLS[@]}"; do
  btrfs subvolume create "/mnt/$sv" >/dev/null
  echo "  $sv"
done
umount /mnt

info "Hänge Subvolumes ein"
OPTS="compress=$COMPRESS,noatime"
mount -o "subvol=@,$OPTS" "$BTRFS_DEV" /mnt
mkdir -p /mnt/{home,nix,var/log,boot}
mount -o "subvol=@home,$OPTS" "$BTRFS_DEV" /mnt/home
mount -o "subvol=@nix,$OPTS"  "$BTRFS_DEV" /mnt/nix
mount -o "subvol=@log,$OPTS"  "$BTRFS_DEV" /mnt/var/log
if (( SWAP_GB > 0 )); then
  mkdir -p /mnt/swap
  mount -o "subvol=@swap,noatime" "$BTRFS_DEV" /mnt/swap
fi
mount -o umask=077 "$ESP" /mnt/boot
findmnt -R /mnt

# =====================================================================
#  Konfiguration
# =====================================================================

info "Erzeuge Konfiguration"
nixos-generate-config --root /mnt >/dev/null
HW=/mnt/etc/nixos/hardware-configuration.nix
CFG=/mnt/etc/nixos/configuration.nix

grep -q 'subvol=@"' "$HW" || warn "subvol=@ fehlt in hardware-configuration.nix – bitte prüfen."
if (( ENCRYPT )) && ! grep -q 'luks.devices."cryptroot"' "$HW"; then
  warn "LUKS-Eintrag für cryptroot fehlt in hardware-configuration.nix – bitte vor der Installation prüfen."
fi

STATE_VERSION=$(grep -oP 'system\.stateVersion = "\K[0-9.]+' "$CFG" || echo "26.05")
mv "$CFG" "$CFG.generated"

# --- Bausteine ---
BOOT_NIX='  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;  # ESP nicht volllaufen lassen
  boot.loader.efi.canTouchEfiVariables = true;'

LUKS_NIX=""
if (( ENCRYPT )); then
  LUKS_NIX='  boot.initrd.luks.devices."cryptroot".allowDiscards = true;  # TRIM durch LUKS durchreichen'
fi

FS_NIX="  fileSystems = {
    \"/\".options        = [ \"compress=$COMPRESS\" \"noatime\" ];
    \"/home\".options    = [ \"compress=$COMPRESS\" \"noatime\" ];
    \"/nix\".options     = [ \"compress=$COMPRESS\" \"noatime\" ];
    \"/var/log\".options = [ \"compress=$COMPRESS\" \"noatime\" ];
    \"/var/log\".neededForBoot = true;"
if (( SWAP_GB > 0 )); then
  FS_NIX+="
    \"/swap\".options    = [ \"noatime\" ];"
fi
FS_NIX+="
  };"

SWAP_NIX=""
if (( SWAP_GB > 0 )); then
  SWAP_NIX="  swapDevices = [ { device = \"/swap/swapfile\"; size = $(( SWAP_GB * 1024 )); } ];  # MiB, NixOS legt die Datei inkl. NOCOW an"
fi

SCRUB_NIX='  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];  # reicht, gescrubbt wird das ganze Dateisystem
  };'

NET_NIX="  networking.hostName = \"$NIX_HOSTNAME\";
  networking.networkmanager.enable = true;"

LOCALE_NIX="  time.timeZone = \"$TIMEZONE\";
  i18n.defaultLocale = \"$LANG_LOCALE\";"
if [[ -n $FORMAT_LOCALE ]]; then
  LOCALE_NIX+="
  i18n.extraLocaleSettings = {"
  for lc in LC_ADDRESS LC_IDENTIFICATION LC_MEASUREMENT LC_MONETARY LC_NAME LC_NUMERIC LC_PAPER LC_TELEPHONE LC_TIME; do
    LOCALE_NIX+="
    $lc = \"$FORMAT_LOCALE\";"
  done
  LOCALE_NIX+="
  };"
fi

KB_NIX="  services.xserver.xkb.layout = \"$XKB_LAYOUT\";"
if [[ -n $XKB_VARIANT ]]; then
  KB_NIX+="
  services.xserver.xkb.variant = \"$XKB_VARIANT\";"
fi
KB_NIX+="
  console.useXkbConfig = true;  # Konsole nutzt dasselbe Layout"

case $DESKTOP in
  gnome)
    DESKTOP_NIX='  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;' ;;
  plasma)
    DESKTOP_NIX='  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;
  services.desktopManager.plasma6.enable = true;' ;;
  cosmic)
    DESKTOP_NIX='  services.displayManager.cosmic-greeter.enable = true;
  services.desktopManager.cosmic.enable = true;' ;;
  xfce)
    DESKTOP_NIX='  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.desktopManager.xfce.enable = true;' ;;
  cinnamon)
    DESKTOP_NIX='  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.desktopManager.cinnamon.enable = true;' ;;
  none)
    DESKTOP_NIX="" ;;
esac
if [[ $DESKTOP != none ]]; then
  DESKTOP_NIX+="
  programs.firefox.enable = true;"
fi

AUDIO_NIX='  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;'
if [[ $(uname -m) == x86_64 ]]; then
  AUDIO_NIX+='
    alsa.support32Bit = true;'
fi
AUDIO_NIX+='
    pulse.enable = true;
    jack.enable = true;
  };'

UNFREE_NIX=""
if (( UNFREE )); then
  UNFREE_NIX='  nixpkgs.config.allowUnfree = true;'
fi

UPDATE_NIX=""
if (( AUTOUPDATE )); then
  UPDATE_NIX='  system.autoUpgrade = {
    enable = true;
    dates = "04:00";
    randomizedDelaySec = "45min";
    allowReboot = false;  # neuer Kernel greift beim nächsten Neustart
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };'
fi

SHELL_NIX=""
USER_SHELL=""
if [[ $LOGIN_SHELL == zsh ]]; then
  USER_SHELL='
    shell = pkgs.zsh;'
  SHELL_NIX='  programs.zsh = {
    enable = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;'
  if (( OHMYZSH )); then
    SHELL_NIX+='
    ohMyZsh = {
      enable = true;
      theme = "robbyrussell";
      plugins = [ "git" "sudo" ];
    };'
  fi
  SHELL_NIX+='
  };'
fi

USER_NIX="  users.users.\"$NIX_USER\" = {
    isNormalUser = true;
    extraGroups = [ \"wheel\" \"networkmanager\" \"audio\" ];$USER_SHELL
  };"

FLATPAK_NIX=""
if (( FLATPAK )); then
  FLATPAK_NIX='  services.flatpak.enable = true;
  # Flathub einmalig als systemweites Repo hinzufügen, sobald das Netz da ist
  systemd.services.flatpak-repo = {
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.flatpak ];
    script = "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo";
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };'
fi

NIXSET_NIX='  nix.settings.auto-optimise-store = true;  # identische Dateien im Store per Hardlink zusammenlegen'

PKG_NIX='  environment.systemPackages = with pkgs; [
    # Grundausstattung
    git
    nixfmt              # offizieller Nix-Formatter
    vim
    curl
    wget
    # Hardware
    pciutils            # lspci
    usbutils            # lsusb
    smartmontools       # smartctl: Zustand von SSD/HDD
    # btrfs
    btrfs-progs
    compsize            # Kompressionsrate anzeigen
    # Werkzeuge
    htop
    tree
    file
    unzip
    rsync
    # NixOS-Helfer
    nix-output-monitor  # nom: lesbare Build-Ausgabe
    nvd                 # Paketunterschiede zwischen Generationen
  ];'

{
  printf '%s\n' '{ config, pkgs, ... }:' '{' '  imports = [ ./hardware-configuration.nix ];'
  emit "Bootloader"                          "$BOOT_NIX"
  emit "Verschlüsselung"                     "$LUKS_NIX"
  emit "btrfs-Mount-Optionen (ergänzen subvol=... aus hardware-configuration.nix)" "$FS_NIX"
  emit "Swap"                                "$SWAP_NIX"
  emit "btrfs-Scrub"                         "$SCRUB_NIX"
  emit "Netzwerk"                            "$NET_NIX"
  emit "Sprache und Zeit"                    "$LOCALE_NIX"
  emit "Tastatur"                            "$KB_NIX"
  emit "Desktop"                             "$DESKTOP_NIX"
  emit "Audio: PipeWire mit ALSA, Pulse und JACK" "$AUDIO_NIX"
  emit "Flatpak"                             "$FLATPAK_NIX"
  emit "Nix"                                 "$NIXSET_NIX"
  emit "Unfreie Pakete"                      "$UNFREE_NIX"
  emit "Automatische Updates"                "$UPDATE_NIX"
  emit "Shell"                               "$SHELL_NIX"
  emit "Benutzer"                            "$USER_NIX"
  emit "Systempakete"                        "$PKG_NIX"
  emit "Nicht ändern, auch nicht nach Upgrades" "  system.stateVersion = \"$STATE_VERSION\";"
  printf '}\n'
} > "$CFG"

echo "  $CFG geschrieben (Original: configuration.nix.generated)"
read -rp "configuration.nix vor der Installation ansehen/bearbeiten? [j/N] " edit
if is_yes "${edit:-n}"; then "${EDITOR:-nano}" "$CFG"; fi

# =====================================================================
#  Installation
# =====================================================================

info "Installiere NixOS (je nach Desktop und Leitung 10–30 Minuten)"
nixos-install --no-root-passwd

info "root-Passwort setzen"
until nixos-enter --root /mnt -c 'passwd root'; do warn "Nochmal versuchen."; done

info "Passwort für $NIX_USER setzen"
until nixos-enter --root /mnt -c "passwd $NIX_USER"; do warn "Nochmal versuchen."; done

info "Installation abgeschlossen."
read -rp "Jetzt aushängen und neu starten? [J/n] " rb
if [[ ${rb,,} != n* ]]; then
  umount -R /mnt
  if (( ENCRYPT )); then cryptsetup close cryptroot; fi
  reboot
else
  echo "System bleibt unter /mnt eingehängt. Später: umount -R /mnt && reboot"
fi
