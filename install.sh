#!/usr/bin/env bash
# NixOS (aktuelles Release oder unstable) auf btrfs installieren
#   UEFI: systemd-boot oder UKI via lanzaboote, EFI-Partition >= 1 GiB
#   Legacy-BIOS: GRUB, BIOS-Boot-Partition + /boot (ext4) >= 1 GiB
#   Rest btrfs (optional in LUKS2)
#   Subvolumes @ @home @nix @log @swap, zstd, Swapfile, PipeWire (ALSA/32 bit, Pulse, JACK)
#
# Aufruf im NixOS-Live-System als root:
#   bash nixos-btrfs-install.sh
#
# Jede Abfrage lässt sich per Umgebungsvariable vorbelegen, z. B.:
#   DISK=/dev/nvme0n1 CHANNEL=release KB=de DESKTOP=plasma NIX_USER=alice bash nixos-btrfs-install.sh
#
# Antworten einer früheren Installation wiederverwenden (dort unter /etc/nixos/install-antworten.env):
#   ANTWORTEN=/pfad/install-antworten.env bash nixos-btrfs-install.sh
#   ANTWORTEN=https://server/install-antworten.env bash nixos-btrfs-install.sh
#
#   CHANNEL      release (neuestes stabiles Release) | unstable
#   KB           Tastatur als xkb-Layout[:Variante], z. B. de, de:nodeadkeys, us:intl
#   LOCALE       z. B. de_DE.UTF-8 oder en_US.UTF-8+de_DE.UTF-8 (Sprache + Formate)
#   TIMEZONE     z. B. Europe/Berlin
#   DESKTOP      gnome | plasma | cosmic | xfce | cinnamon | none
#   DESKTOP_MODE minimal (Desktop, Terminal, Dateimanager, Editor) | full (alle Standard-Apps)
#   GPU          intel | amd | nvidia | nvidia-prime | nouveau | generic
#   SAMBA        none | client (Netzlaufwerke nutzen) | server (zusätzlich ~/Freigabe freigeben)
#   CONTAINERS   none | podman | docker
#   BACKUP_REPO  restic-Ziel, z. B. sftp:benutzer@nas:/backup/rechner
#   LID          suspend | hibernate (Standby, nach 1 h Ruhezustand) | ignore
#   HW_PROFILE   nixos-hardware-Profil, z. B. lenovo/thinkpad/t480, oder none
#   LOGIN_SHELL  bash | zsh
#   SSH_KEYS     öffentlicher Schlüssel oder gh:<GitHub-Name>
#   GIT_NAME, GIT_EMAIL  Git-Identität (nur mit home-manager)
#   EXTRA_USERS  weitere Benutzer, durch Leerzeichen getrennt
#   NIX_HOSTNAME, NIX_USER, SWAP_GB
#   Ja/Nein (j/n): PRINTING BLUETOOTH STEAM LIBVIRT FLATPAK UNFREE ENCRYPT UKI TPM2 SILENT
#                  SNAPPER BACKUP HIBERNATE AUTOUPDATE OHMYZSH SSHD NV_OPEN FINGERPRINT
#                  FIDO2_LUKS FIDO2_SUDO RESCUE HOME_MANAGER
# Ohne Abfrage, nur per Variable: ESP_GB (Größe von /boot in GiB, 1), COMPRESS (zstd), ZRAM (j),
#   BOOT_MODE (uefi | bios; Standard: wie der USB-Stick gestartet wurde),
#   KERNEL (latest = neuester stabiler Kernel | lts = Standard-Kernel des Releases),
#   TUI (j = Menüs mit dialog, n = reine Textabfragen)
#
# Das komplette Protokoll landet in /var/log/nixos-install.log des neuen Systems.

set -Eeuo pipefail

# ---------- Hilfsfunktionen ----------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_bld=$'\e[1m'; c_rst=$'\e[0m'
info() { printf '\n%s==>%s %s%s%s\n' "$c_grn" "$c_rst" "$c_bld" "$*" "$c_rst"; }
warn() { printf '%s!!%s  %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die() {
  printf '%sFEHLER:%s %s\n' "$c_red" "$c_rst" "$*" >&2
  if [[ -n ${LOG:-} ]]; then
    printf 'Protokoll: %s\n' "$LOG" >&2
    if mountpoint -q /mnt/var/log 2>/dev/null; then cp "$LOG" /mnt/var/log/nixos-install.log 2>/dev/null || true; fi
  fi
  exit 1
}
trap 'die "Abbruch in Zeile $LINENO: $BASH_COMMAND"' ERR

is_yes() { [[ ${1,,} =~ ^(j|ja|y|yes|1)$ ]]; }
yn() { if (( $1 )); then echo ja; else echo nein; fi; }

# ---------- Oberfläche: dialog-Menüs, sonst Textabfragen ----------
USE_DIALOG=0; DIALOG_BIN=""; WIPED=0
USB_DIR=${USB_DIR:-/sys/bus/usb/devices}

# dialog zeichnet auf dem Terminal, das Ergebnis kommt über fd 3 zurück
dlg() {
  local out rc=0
  out=$(LANG=${LANG:-C.UTF-8} "$DIALOG_BIN" --backtitle "NixOS-Installer" --output-fd 3 "$@" \
        3>&1 1>/dev/tty 2>/dev/tty </dev/tty) || rc=$?
  printf '%s' "$out"
  return "$rc"
}

# Abbrechen/Esc in einem Menü
dlg_abort() {
  clear >/dev/tty 2>/dev/null || true
  if (( WIPED )); then die "Abgebrochen. Das neue System ist unter /mnt eingehängt."; fi
  die "Abgebrochen, nichts verändert."
}

# Hinweis während der Fragen: im Menü als Meldung, sonst als Warnung
note() {
  if (( USE_DIALOG )); then
    dlg --title "Hinweis" --msgbox "$*" 0 0 || true
    echo "  Hinweis: $*"
  else
    warn "$*"
  fi
}

# ask VAR "Frage" "Standard" ["Regex" "Fehlertext"] – Freitext, nur wenn VAR noch nicht gesetzt ist
ask() {
  local var=$1 prompt=$2 def=${3-} re=${4-} msg=${5:-Ungültige Eingabe.} val
  if [[ -n ${!var+x} ]]; then   # vorbelegt (auch leer) = schon beantwortet
    if [[ -n $re && ! ${!var} =~ $re ]]; then die "$var: $msg (${!var})"; fi
    return 0
  fi
  while true; do
    if (( USE_DIALOG )); then
      val=$(dlg --title "Eingabe" --inputbox "$prompt" 0 0 "$def") || dlg_abort
    else
      read -rp "$prompt${def:+ [$def]}: " val
      val=${val:-$def}
    fi
    if [[ -z $re || $val =~ $re ]]; then break; fi
    if (( ! USE_DIALOG )) && [[ ! -t 0 ]]; then die "$msg ($val)"; fi   # nicht interaktiv: nicht endlos fragen
    note "$msg"
  done
  printf -v "$var" '%s' "$val"
  if (( USE_DIALOG )); then echo "  $prompt: $val"; fi
}

# ask_yn VAR "Frage" j|n – setzt VAR auf 1 oder 0
ask_yn() {
  local var=$1 prompt=$2 def=$3 val hint rc
  val=${!var-}
  if [[ -z $val ]]; then
    if (( USE_DIALOG )); then
      rc=0
      if [[ $def == j ]]; then
        dlg --yes-label "Ja" --no-label "Nein" --yesno "$prompt" 0 0 || rc=$?
      else
        dlg --yes-label "Ja" --no-label "Nein" --defaultno --yesno "$prompt" 0 0 || rc=$?
      fi
      case $rc in 0) val=j ;; 1) val=n ;; *) dlg_abort ;; esac
      echo "  $prompt -> $(if [[ $val == j ]]; then echo ja; else echo nein; fi)"
    else
      if [[ $def == j ]]; then hint="J/n"; else hint="j/N"; fi
      read -rp "$prompt [$hint]: " val
      val=${val:-$def}
    fi
  fi
  if is_yes "$val"; then printf -v "$var" 1; else printf -v "$var" 0; fi
}

# ask_multi "Titel" VAR "Text" j|n ... – im Menü eine Checkliste, sonst einzelne Ja/Nein-Fragen
ask_multi() {
  local title=$1 i var st sel
  shift
  local args=("$@") open=() items=()
  for ((i = 0; i < ${#args[@]}; i += 3)); do
    var=${args[i]}
    if [[ -n ${!var-} ]]; then
      if is_yes "${!var}"; then printf -v "$var" 1; else printf -v "$var" 0; fi
    else
      open+=("$i")
    fi
  done
  if (( ${#open[@]} == 0 )); then return 0; fi
  if (( USE_DIALOG )); then
    for i in "${open[@]}"; do
      if [[ ${args[i+2]} == j ]]; then st=on; else st=off; fi
      items+=("${args[i]}" "${args[i+1]}" "$st")
    done
    sel=$(dlg --title "$title" --no-tags --separate-output \
              --checklist "Leertaste wählt aus oder ab, Enter bestätigt." 0 0 0 "${items[@]}") || dlg_abort
    for i in "${open[@]}"; do
      var=${args[i]}
      if grep -qx "$var" <<<"$sel"; then printf -v "$var" 1; else printf -v "$var" 0; fi
      echo "  ${args[i+1]}: $(yn "${!var}")"
    done
  else
    printf '\n%s\n' "$title"
    for i in "${open[@]}"; do ask_yn "${args[i]}" "${args[i+1]}?" "${args[i+2]}"; done
  fi
}

# ask_pass VAR "Frage" – Passwort zweimal ohne Echo; landet nicht im Protokoll
ask_pass() {
  local var=$1 prompt=$2 p1 p2
  while true; do
    if (( USE_DIALOG )); then
      p1=$(dlg --insecure --passwordbox "$prompt" 0 0) || dlg_abort
      p2=$(dlg --insecure --passwordbox "Passwort wiederholen" 0 0) || dlg_abort
    else
      read -rsp "$prompt: " p1; echo
      read -rsp "Passwort wiederholen: " p2; echo
    fi
    if [[ -n $p1 && $p1 == "$p2" ]]; then break; fi
    if (( ! USE_DIALOG )) && [[ ! -t 0 ]]; then die "Passwörter leer oder nicht gleich."; fi
    note "Leer oder nicht gleich, bitte nochmal."
  done
  printf -v "$var" '%s' "$p1"
}

# choose VAR "Frage" Standardnummer "wert|Beschreibung" ... – Auswahlmenü
choose() {
  local var=$1 prompt=$2 def=$3 i sel
  shift 3
  local opts=("$@") items=()
  [[ -n ${!var-} ]] && return 0
  if (( USE_DIALOG )); then
    for i in "${!opts[@]}"; do items+=("${opts[i]%%|*}" "${opts[i]#*|}"); done
    sel=$(dlg --no-tags --default-item "${opts[def - 1]%%|*}" --menu "$prompt" 0 0 0 "${items[@]}") || dlg_abort
    printf -v "$var" '%s' "$sel"
    echo "  $prompt -> $sel"
    return 0
  fi
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

# Zusätzlichen Kanal einrichten und laden (z. B. nixos-hardware, home-manager)
add_channel() {
  local name=$1 url=$2
  if [[ " ${CHANNELS_DONE-} " == *" $name "* ]]; then return 0; fi
  if (( USE_DIALOG )); then dlg --infobox "Lade $name ..." 3 50 || true; fi
  echo "  Lade Kanal $name ($url)"
  if nix-channel --add "$url" "$name" && nix-channel --update "$name" >/dev/null; then
    CHANNELS_DONE="${CHANNELS_DONE-} $name"
    return 0
  fi
  nix-channel --remove "$name" >/dev/null 2>&1 || true
  return 1
}

# Fingerabdruckleser über die Geräteliste von libfprint erkennen
# setzt FP_DEV (vendor:product) und FP_STATUS (supported | unsupported | leer)
detect_fingerprint() {
  local lf hwdb d id st
  FP_DEV=""; FP_STATUS=""
  ls "$USB_DIR"/*/idVendor >/dev/null 2>&1 || return 0
  if (( USE_DIALOG )); then dlg --infobox "Suche Fingerabdruckleser ..." 3 50 || true; fi
  lf=$(nix-build '<nixpkgs>' -A libfprint --no-out-link 2>/dev/null) || return 0
  hwdb=$lf/lib/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb
  [[ -r $hwdb ]] || return 0
  for d in "$USB_DIR"/*; do
    [[ -r $d/idVendor && -r $d/idProduct ]] || continue
    id="usb:v$(tr 'a-f' 'A-F' <"$d/idVendor")p$(tr 'a-f' 'A-F' <"$d/idProduct")*"
    st=$(awk -v id="$id" '/^# Known unsupported/ { u = 1 } /^# Supported by/ { u = 0 }
                          $0 == id { print (u ? "unsupported" : "supported"); exit }' "$hwdb")
    if [[ -n $st ]]; then
      FP_DEV="$(<"$d/idVendor"):$(<"$d/idProduct")"
      FP_STATUS=$st
      if [[ $st == supported ]]; then return 0; fi
    fi
  done
}

# hw_candidates "<DMI-Text>" README.md – gibt "Punkte<TAB>Treffer<TAB>Pfad<TAB>Name" aus, beste zuerst
hw_candidates() {
  local dmi=$1 readme=$2
  awk -v dmi="$dmi" '
    function toks(s, arr,   n, i, t, k, parts, m, j) {
      s = tolower(s); gsub(/[^a-z0-9]+/, " ", s)
      n = split(s, parts, " "); k = 0
      for (i = 1; i <= n; i++) if (parts[i] != "") arr[++k] = parts[i]
      return k
    }
    # Teile an Buchstabe/Ziffer-Grenzen: t480s -> t 480 s
    function pieces(w, arr,   k, cur, c, i, cls, prev) {
      k = 0; cur = ""; prev = ""
      for (i = 1; i <= length(w); i++) {
        c = substr(w, i, 1); cls = (c ~ /[0-9]/) ? "d" : "a"
        if (cur != "" && cls != prev) { arr[++k] = cur; cur = "" }
        cur = cur c; prev = cls
      }
      if (cur != "") arr[++k] = cur
      return k
    }
    BEGIN {
      d = tolower(dmi)
      if (d ~ /asustek/) d = d " asus"
      if (d ~ /micro-star/) d = d " msi"
      if (d ~ /hewlett/) d = d " hp"
      n = toks(d, w)
      for (i = 1; i <= n; i++) {
        # Seriennummern-artige Codes (z. B. 20L5CTO1WW) liefern nur Zufallstreffer
        if (length(w[i]) >= 8 && w[i] ~ /[a-z]/ && w[i] ~ /[0-9]/) continue
        have[w[i]] = 1; m = pieces(w[i], p); for (j = 1; j <= m; j++) have[p[j]] = 1
      }
    }
    /^\| \[.*\]\(.*\) *\| *`<nixos-hardware\// {
      name = $0; sub(/^\| \[/, "", name); sub(/\]\(.*/, "", name); gsub(/\\/, "", name)
      path = $0; sub(/.*`<nixos-hardware\//, "", path); sub(/\/?>`.*/, "", path)
      if (seen[path]++) next
      n = toks(name, t); hit = 0
      for (i = 1; i <= n; i++) {
        if (t[i] in have) { hit++; continue }
        m = pieces(t[i], p); ok = (m > 1)
        for (j = 1; j <= m; j++) if (!(p[j] in have)) ok = 0
        if (ok) hit += 0.9   # nur in Teilen getroffen (GA401 in GA401QM): etwas schwächer
      }
      if (n > 0 && hit / n >= 0.75) printf "%.3f\t%d\t%s\t%s\n", hit / n, n, path, name
    }
  ' "$readme" | sort -t$'\t' -k1,1nr -k2,2nr
}

# home.nix für home-manager; $1 = Zieldatei
write_home_nix() {
  {
    cat <<EOF
# Benutzer-Einstellungen, verwaltet von home-manager (gilt für alle Benutzer).
# Persönliches pro Benutzer (z. B. Git-Name) steht in configuration.nix unter home-manager.users.
# Nach Änderungen: sudo nixos-rebuild switch
{ config, pkgs, ... }:
{
  home.stateVersion = "$STATE_VERSION";  # nicht ändern

  home.shellAliases = {
    rebuild = "sudo nixos-rebuild switch";
    update = "sudo nixos-rebuild switch --upgrade";
  };
EOF
    if [[ $LOGIN_SHELL == zsh ]]; then
      cat <<'EOF'

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;      # Vorschläge aus dem Verlauf, Pfeil rechts übernimmt
    syntaxHighlighting.enable = true;
    history = {
      size = 10000;
      ignoreDups = true;
    };
EOF
      if (( OHMYZSH )); then
        cat <<'EOF'
    oh-my-zsh = {
      enable = true;
      theme = "robbyrussell";          # Auswahl: ls $(nix-build '<nixpkgs>' -A oh-my-zsh)/share/oh-my-zsh/themes
      plugins = [ "git" "sudo" "colored-man-pages" ];
    };
EOF
      fi
      echo '  };'
    else
      printf '\n  programs.bash.enable = true;\n'
    fi
    cat <<'EOF'

  programs.git.enable = true;

  # Programme nur für die Benutzer, z. B.:
  # home.packages = with pkgs; [ thunderbird ];
}
EOF
  } > "$1"
}

# emit "Überschrift" "Nix-Text" – schreibt einen Konfigurationsblock, wenn er nicht leer ist
emit() {
  [[ -n $2 ]] || return 0
  printf '\n  # %s\n%s\n' "$1" "$2"
}

# ~/.zshrc mit oh-my-zsh aus dem Nix-Store
write_zshrc_ohmyzsh() {
  cat <<'EOF'
# ~/.zshrc – vom NixOS-Installer angelegt
# oh-my-zsh kommt aus dem Nix-Store und wird mit "update" (nixos-rebuild) aktualisiert.
# Theme und Plugins hier ändern, wirksam in jeder neuen Shell oder sofort mit: exec zsh

export ZSH=/run/current-system/sw/share/oh-my-zsh
ZSH_CUSTOM="$HOME/.oh-my-zsh-custom"     # eigene Themes und Plugins
ZSH_CACHE_DIR="$HOME/.cache/oh-my-zsh"   # der Nix-Store ist schreibgeschützt
ZSH_COMPDUMP="$ZSH_CACHE_DIR/.zcompdump"
mkdir -p "$ZSH_CUSTOM" "$ZSH_CACHE_DIR"
zstyle ':omz:update' mode disabled       # Updates kommen über NixOS

# Theme, Auswahl: ls $ZSH/themes
ZSH_THEME="robbyrussell"

# Plugins, Auswahl: ls $ZSH/plugins
plugins=(git sudo colored-man-pages)

source "$ZSH/oh-my-zsh.sh"

# Vorschläge aus dem Verlauf, Pfeil rechts übernimmt
if [[ -r /run/current-system/sw/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
  source /run/current-system/sw/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
fi

# Eigene Aliase
alias rebuild='sudo nixos-rebuild switch'
alias update='sudo nixos-rebuild switch --upgrade'

# Syntax-Hervorhebung, muss als Letztes geladen werden
if [[ -r /run/current-system/sw/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
  source /run/current-system/sw/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi
EOF
}

# ~/.zshrc ohne oh-my-zsh: Grundeinstellungen kommen aus /etc/zshrc
write_zshrc_plain() {
  cat <<'EOF'
# ~/.zshrc – vom NixOS-Installer angelegt
# Verlauf, Vervollständigung, Vorschläge und Syntax-Hervorhebung richtet NixOS
# über programs.zsh in /etc/nixos/configuration.nix ein. Eigenes hier ergänzen.

alias rebuild='sudo nixos-rebuild switch'
alias update='sudo nixos-rebuild switch --upgrade'
EOF
}

# sysfs-Adresse 0000:01:00.0 -> NixOS-Bus-ID PCI:1:0:0 (dezimal)
pci_busid() {
  local a=${1#*:} bus dev fn
  bus=${a%%:*}; a=${a#*:}; dev=${a%%.*}; fn=${a#*.}
  printf 'PCI:%d:%d:%d' "0x$bus" "0x$dev" "0x$fn"
}

# Öffentliche SSH-Schlüssel als Nix-Liste; Eingabe: Schlüssel oder gh:<GitHub-Name>
ssh_keys_nix() {
  local input=$1 keys line out=""
  if [[ $input == gh:* ]]; then
    keys=$(curl -fsSL --max-time 15 "https://github.com/${input#gh:}.keys" || true)
    [[ -n $keys ]] || warn "Keine Schlüssel von GitHub für ${input#gh:} erhalten."
  else
    keys=$input
  fi
  while read -r line; do
    line=${line//[\"\\\$]/}   # Zeichen entfernen, die in einem Nix-String stören
    if [[ $line =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\ [A-Za-z0-9+/=]+ ]]; then
      out+="
      \"$line\""
    elif [[ -n $line ]]; then
      warn "Kein gültiger SSH-Schlüssel, übersprungen: ${line:0:40}..."
    fi
  done <<<"$keys"
  printf '%s' "$out"
}

# Neuestes stabiles Release laut status.nixos.org, sonst die Version des Installers
detect_latest_release() {
  local json rel=""
  json=$(curl -fsSL --max-time 10 'https://prometheus.nixos.org/api/v1/query?query=channel_revision' 2>/dev/null || true)
  rel=$(grep -o '"metric":{[^}]*}' <<<"$json" | grep '"status":"stable"' \
        | grep -o '"channel":"nixos-[0-9][0-9]\.[0-9][0-9]"' | grep -o '[0-9][0-9]\.[0-9][0-9]' \
        | sort -V | tail -n1 || true)
  [[ -n $rel ]] || rel=$(nixos-version 2>/dev/null | grep -oE '^[0-9]{2}\.[0-9]{2}' || true)
  echo "$rel"
}

# Alle Geräte der Platte samt Partitionen und Geräten darüber (LVM, LUKS, RAID) als echte Pfade
disk_devs() {
  lsblk -lnpo NAME "$1" | while read -r d; do realpath "$d"; done
}

# Löst alles, was die Platte noch belegt: Swap, Mounts, LVM, RAID, LUKS.
# Ohne das meldet parted "unable to inform the kernel of the change".
release_disk() {
  local disk=$1 devs sw src tgt vg name type
  devs=$(disk_devs "$disk")
  on_disk() { [[ -n $1 ]] && grep -qxF "$(realpath "$1" 2>/dev/null)" <<<"$devs"; }

  # Swap-Partitionen und Swapfiles auf der Platte
  while read -r sw _; do
    [[ $sw == Filename ]] && continue
    src=$(findmnt -no SOURCE -T "$sw" 2>/dev/null | sed 's/\[.*//' || true)
    if on_disk "$sw" || on_disk "$src"; then
      echo "  swapoff $sw"
      swapoff "$sw"
    fi
  done < /proc/swaps

  # Mounts, tiefste zuerst
  while read -r tgt; do
    echo "  umount $tgt"
    umount "$tgt" 2>/dev/null || umount -l "$tgt"
  done < <(findmnt -rno TARGET,SOURCE | while read -r tgt src; do
             src=${src%%\[*}
             if [[ -b $src ]] && on_disk "$src"; then printf '%s\n' "$tgt"; fi
           done | sort -r)

  # LVM-Volume-Groups auf der Platte deaktivieren
  if command -v pvs >/dev/null; then
    while read -r dev; do
      vg=$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | tr -d ' ' || true)
      if [[ -n $vg ]]; then
        echo "  vgchange -an $vg"
        vgchange -an "$vg" >/dev/null
      fi
    done <<<"$devs"
  fi

  # LUKS und RAID von oben nach unten schließen
  while read -r name type; do
    case $type in
      crypt) echo "  cryptsetup close ${name##*/}"; cryptsetup close "${name##*/}" ;;
      raid*) echo "  mdadm --stop $name"; mdadm --stop "$name" >/dev/null ;;
    esac
  done < <(lsblk -lnpo NAME,TYPE "$disk" | tac)

  udevadm settle
}

# Kernel die neue Partitionstabelle einlesen lassen und prüfen, dass er die neuen Größen sieht
reread_partitions() {
  local disk=$1 want_esp=$(( ESP_GB * 1024 * 1024 * 1024 )) i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    udevadm settle
    partprobe "$disk" 2>/dev/null || partx -u "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
    udevadm settle
    if [[ -b $BOOTPART && -b $ROOTPART ]] && [[ $(lsblk -bdno SIZE "$BOOTPART") == "$want_esp" ]]; then
      return 0
    fi
    sleep 1
  done
  lsblk -po NAME,SIZE,TYPE,MOUNTPOINTS "$disk" >&2
  die "Der Kernel sieht die neuen Partitionen auf $disk nicht. Irgendetwas hält die Platte noch fest. Neu starten und das Skript erneut ausführen."
}

# ---------- Antwortdatei ----------
# Alle Antworten, die gespeichert und wiederverwendet werden (DISK absichtlich nicht)
ANSWER_VARS=(CHANNEL KB LOCALE TIMEZONE DESKTOP DESKTOP_MODE GPU NV_OPEN KERNEL PRINTING BLUETOOTH
  STEAM SAMBA LIBVIRT CONTAINERS FLATPAK UNFREE ENCRYPT UKI TPM2 SILENT SNAPPER BACKUP BACKUP_REPO
  HIBERNATE LID AUTOUPDATE LOGIN_SHELL OHMYZSH SSHD SSH_KEYS NIX_HOSTNAME NIX_USER EXTRA_USERS
  SWAP_GB ZRAM ESP_GB COMPRESS FINGERPRINT FIDO2_LUKS FIDO2_SUDO RESCUE HOME_MANAGER GIT_NAME
  GIT_EMAIL)
# Nicht gespeichert, weil rechnerspezifisch: DISK, HW_PROFILE

# Liest nur Zeilen der Form NAME='wert' mit bekannten Namen; nichts davon wird ausgeführt.
# Per Umgebungsvariable gesetzte Werte haben Vorrang.
load_answers() {
  local src=$1 file line k v n=0
  if [[ $src == http://* || $src == https://* ]]; then
    file=$(mktemp)
    curl -fsSL --max-time 30 "$src" -o "$file" || die "Antwortdatei $src nicht abrufbar."
  else
    file=$src
  fi
  [[ -r $file ]] || die "Antwortdatei $file nicht lesbar."
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^([A-Z][A-Z0-9_]*)=\'(.*)\'$ ]]; then
      k=${BASH_REMATCH[1]}
      v=${BASH_REMATCH[2]//\'\\\'\'/\'}
      if [[ " ${ANSWER_VARS[*]} " == *" $k "* && -z ${!k+x} ]]; then
        printf -v "$k" '%s' "$v"
        n=$((n + 1))
      fi
    fi
  done < "$file"
  echo "  $n Antworten aus $src übernommen."
}

save_answers() {
  local f=$1 k v
  {
    echo "# Antworten des NixOS-Installers vom $(date +%F) für $NIX_HOSTNAME"
    echo "# Wiederverwenden: ANTWORTEN=/pfad/zu/dieser/datei bash install.sh"
    echo "# Die Zielplatte (DISK) ist absichtlich nicht enthalten."
    echo "# Hostname, Grafik (GPU) und Swap-Größe für einen anderen Rechner ggf. anpassen."
    for k in "${ANSWER_VARS[@]}"; do
      v=${!k-}
      if [[ -z $v ]]; then continue; fi
      if [[ $v == none && $k =~ ^(GPU|DESKTOP_MODE|LID)$ ]]; then continue; fi
      v=${v//\'/\'\\\'\'}
      printf "%s='%s'\n" "$k" "$v"
    done
  } > "$f"
  chmod 600 "$f"
}

# Platzhalter-Hardware für die Vorabprüfung der Konfiguration
write_mock_hw() {
  local dev=/dev/disk/by-label/nixos m
  echo '{ lib, ... }: {'
  echo '  nixpkgs.hostPlatform = lib.mkDefault builtins.currentSystem;'
  for m in "/:@" "/home:@home" "/nix:@nix" "/var/log:@log"; do
    printf '  fileSystems."%s" = { device = "%s"; fsType = "btrfs"; options = [ "subvol=%s" ]; };\n' "${m%%:*}" "$dev" "${m#*:}"
  done
  if (( SWAP_GB > 0 )); then
    printf '  fileSystems."/swap" = { device = "%s"; fsType = "btrfs"; options = [ "subvol=@swap" ]; };\n' "$dev"
  fi
  if [[ $BOOT_MODE == uefi ]]; then
    echo '  fileSystems."/boot" = { device = "/dev/disk/by-label/boot"; fsType = "vfat"; };'
  else
    echo '  fileSystems."/boot" = { device = "/dev/disk/by-label/boot"; fsType = "ext4"; };'
  fi
  if (( ENCRYPT )); then
    echo '  boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";'
  fi
  echo '}'
}

# Baut configuration.nix aus allen Antworten; $1 = Zieldatei
build_config() {
  local CFG=$1
# --- Bausteine ---
IMPORTS='    ./hardware-configuration.nix'
if (( UKI )); then IMPORTS+=$'\n    lanzaboote.nixosModules.lanzaboote'; fi
if [[ $HW_PROFILE != none ]]; then IMPORTS+=$'\n    <nixos-hardware/'"$HW_PROFILE"'>  # Anpassungen für dieses Modell (nixos-hardware)'; fi
if (( HOME_MANAGER )); then IMPORTS+=$'\n    <home-manager/nixos>'; fi
if (( UKI )); then
  HEADER_NIX='{ config, lib, pkgs, ... }:
let
  # lanzaboote v1.2.0 (nix-community): baut für jede Generation eine signierte UKI
  lanzaboote = import (builtins.fetchTarball {
    url = "https://github.com/nix-community/lanzaboote/archive/c1c5edd31802d181c8aa2c71588995d93425d650.tar.gz";
    sha256 = "0syvqpi77ia1vd189658g53mqjgw7i39zym2r0g7asdjkrz0mgmj";
  }) { inherit pkgs; };
in
{'
  BOOT_NIX='  boot.loader.systemd-boot.enable = lib.mkForce false;  # lanzaboote ersetzt systemd-boot
  boot.loader.systemd-boot.configurationLimit = 10;     # gilt auch für lanzaboote
  boot.loader.efi.canTouchEfiVariables = true;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";  # Secure-Boot-Schlüssel, vom Installer erzeugt
  };'
elif [[ $BOOT_MODE == bios ]]; then
  HEADER_NIX='{ config, lib, pkgs, ... }:
{'
  BOOT_NIX="  boot.loader.grub = {
    enable = true;
    device = \"$GRUB_DEV\";  # Legacy-BIOS: GRUB in den Bootsektor dieser Platte
    configurationLimit = 10;
  };"
  if (( RESCUE )); then
    BOOT_NIX+=$'\n  boot.loader.grub.memtest86.enable = true;  # Eintrag „Memtest86+“: Arbeitsspeicher testen'
  fi
else
  HEADER_NIX='{ config, lib, pkgs, ... }:
{'
  BOOT_NIX='  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;  # ESP nicht volllaufen lassen
  boot.loader.efi.canTouchEfiVariables = true;'
  if (( RESCUE )); then
    BOOT_NIX+='
  boot.loader.systemd-boot.memtest86.enable = true;   # Eintrag „Memtest86+“: Arbeitsspeicher testen
  boot.loader.systemd-boot.netbootxyz.enable = true;  # Eintrag „netboot.xyz“: Rettungssysteme aus dem Netz'
  fi
fi
HEADER_NIX+=$'\n  imports = [\n'"$IMPORTS"$'\n  ];'

KERNEL_NIX="  boot.kernelPackages = pkgs.$KERNEL_ATTR;"
if [[ $KERNEL == latest ]]; then KERNEL_NIX+="  # neuester stabiler Kernel"; fi
KPARAMS=()
if (( SILENT )); then KPARAMS+=(quiet rd.systemd.show_status=auto rd.udev.log_level=3 udev.log_level=3); fi
if (( HIBERNATE )); then KPARAMS+=("resume_offset=$RESUME_OFFSET"); fi
if (( ${#KPARAMS[@]} > 0 )); then
  KERNEL_NIX+=$'\n  boot.kernelParams = ['
  for kp in "${KPARAMS[@]}"; do KERNEL_NIX+=$'\n    "'"$kp"'"'; done
  KERNEL_NIX+=$'\n  ];'
fi

SILENT_NIX=""
if (( SILENT )); then
  SILENT_NIX='  boot.plymouth.enable = true;   # Startbildschirm, fragt auch das LUKS-Passwort ab
  boot.consoleLogLevel = 3;      # nur Fehler auf der Konsole
  boot.initrd.verbose = false;   # Kernel-Parameter dafür stehen oben bei "Kernel"'
fi

LUKS_NIX=""
if (( ENCRYPT )); then
  LUKS_NIX='  boot.initrd.luks.devices."cryptroot".allowDiscards = true;  # TRIM durch LUKS durchreichen'
fi
if (( TPM2 )); then
  LUKS_NIX+='
  # TPM2: entsperrt ohne Passwort, sobald "sudo luks-tpm2-enroll" gelaufen ist (nach Secure Boot)
  security.tpm2.enable = true;'
fi
if (( TPM2 && FIDO2_LUKS )); then
  LUKS_NIX+='
  # TPM2 und FIDO2: ohne feste Vorgabe probiert systemd alle eingerichteten Schlüssel, dann das Passwort'
elif (( TPM2 )); then
  LUKS_NIX+='
  boot.initrd.luks.devices."cryptroot".crypttabExtraOpts = [ "tpm2-device=auto" ];'
elif (( FIDO2_LUKS )); then
  LUKS_NIX+='
  # FIDO2: beim Start Schlüssel einstecken (ggf. PIN) und antippen; das Passwort geht weiterhin
  boot.initrd.luks.devices."cryptroot".crypttabExtraOpts = [ "fido2-device=auto" ];'
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
if (( HIBERNATE )); then
  SWAP_NIX="  swapDevices = [ { device = \"/swap/swapfile\"; } ];  # vom Installer angelegt, feste Lage für den Ruhezustand
  boot.resumeDevice = \"/dev/disk/by-uuid/$RESUME_UUID\";"
elif (( SWAP_GB > 0 )); then
  SWAP_NIX="  swapDevices = [ { device = \"/swap/swapfile\"; size = $(( SWAP_GB * 1024 )); } ];  # MiB, NixOS legt die Datei inkl. NOCOW an"
fi
if (( ZRAM )); then
  if [[ -n $SWAP_NIX ]]; then SWAP_NIX+=$'\n'; fi
  SWAP_NIX+='  zramSwap = {
    enable = true;        # komprimierter Swap im RAM, wird vor dem Swapfile genutzt
    memoryPercent = 50;
  };'
fi

SNAP_NIX=""
if (( SNAPPER )); then
  SNAP_NIX="  services.snapper.configs.home = {
    SUBVOLUME = \"/home\";
    ALLOW_USERS = [ \"$NIX_USER\" ];  # darf snapper -c home list/undochange
    SYNC_ACL = true;                # und in /home/.snapshots lesen
    TIMELINE_CREATE = true;
    TIMELINE_CLEANUP = true;
    TIMELINE_LIMIT_HOURLY = 10;
    TIMELINE_LIMIT_DAILY = 7;
    TIMELINE_LIMIT_WEEKLY = 4;
    TIMELINE_LIMIT_MONTHLY = 6;
    TIMELINE_LIMIT_YEARLY = 0;
  };"
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

# Grafik
GPU_NIX=""
if [[ $GPU != none ]]; then
  GPU_NIX='  hardware.graphics.enable = true;'
  if [[ $(uname -m) == x86_64 ]]; then
    GPU_NIX+='
  hardware.graphics.enable32Bit = true;  # 32-bit-Treiber für Steam und Wine'
  fi
  if [[ $GPU == intel || ( $GPU == nvidia-prime && $IGPU_VENDOR == intel ) ]]; then
    GPU_NIX+='
  hardware.graphics.extraPackages = with pkgs; [ intel-media-driver ];  # Video-Beschleunigung (VA-API)'
  fi
  if [[ $GPU == amd ]]; then
    GPU_NIX+='
  hardware.amdgpu.initrd.enable = true;  # Grafik früh laden, sauberer Startbildschirm'
  fi
  # Mit Hardware-Profil gelten dessen NVIDIA-Werte; unsere greifen nur, wo es nichts vorgibt
  if [[ $HW_PROFILE != none ]]; then W='lib.mkOverride 1100 '; else W=''; fi
  if [[ $GPU == nvidia || $GPU == nvidia-prime ]]; then
    if (( NV_OPEN )); then nvopen=true; else nvopen=false; fi
    GPU_NIX+="
  services.xserver.videoDrivers = [ \"nvidia\" ];
  hardware.nvidia = {
    modesetting.enable = true;
    open = $W$nvopen;          # offene Kernelmodule, ab GTX 16xx/RTX 20xx
    nvidiaSettings = true;"
    if (( ! NV_OPEN )); then
      GPU_NIX+="
    # Treiber 580 ist der letzte für GTX 9xx/10xx (Maxwell, Pascal, Volta);
    # noch ältere Karten brauchen legacy_470 oder nouveau
    package = ${W}config.boot.kernelPackages.nvidiaPackages.legacy_580;"
    fi
    GPU_NIX+="
  };"
  fi
  if [[ $GPU == nvidia-prime ]]; then
    if [[ $IGPU_VENDOR == intel ]]; then igpu_opt=intelBusId; else igpu_opt=amdgpuBusId; fi
    GPU_NIX+="
  hardware.nvidia.prime = {
    offload.enable = ${W}true;
    offload.enableOffloadCmd = ${W}true;  # Programme mit \"nvidia-offload <programm>\" auf der NVIDIA-GPU starten
    $igpu_opt = $W\"$(pci_busid "$IGPU_DEV")\";
    nvidiaBusId = $W\"$(pci_busid "$NV_DEV")\";
  };"
  fi
fi

# Desktop-Extras
EXTRAS_NIX=""
if (( PRINTING )); then
  EXTRAS_NIX+='  services.printing.enable = true;'
fi
if [[ $DESKTOP != none ]]; then
  if [[ -n $EXTRAS_NIX ]]; then EXTRAS_NIX+=$'\n'; fi
  if (( BLUETOOTH )); then
    EXTRAS_NIX+='  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };'
    if [[ $DESKTOP == xfce ]]; then
      EXTRAS_NIX+='
  services.blueman.enable = true;  # Bluetooth-Oberfläche für Xfce'
    fi
  else
    EXTRAS_NIX+='  hardware.bluetooth.enable = false;'
  fi
fi
if (( STEAM )); then
  EXTRAS_NIX+='
  programs.steam.enable = true;
  programs.gamemode.enable = true;  # Spiele mit "gamemoderun %command%" starten'
fi

# Avahi: Drucker, NAS und Rechner im Netz finden, Namen wie nas.local auflösen
AVAHI_NIX=""
if (( PRINTING )) || [[ $SAMBA != none ]]; then
  AVAHI_NIX='  services.avahi = {
    enable = true;
    nssmdns4 = true;      # Namen wie drucker.local oder nas.local auflösen
    openFirewall = true;'
  if [[ $SAMBA == server ]] && (( AVAHI_SETTINGS )); then
    AVAHI_NIX+='
    settings.publish = {   # Samba-Freigabe für macOS und Linux sichtbar machen
      disable-publishing = false;
      disable-user-service-publishing = false;
      publish-addresses = true;
    };'
  elif [[ $SAMBA == server ]]; then
    AVAHI_NIX+='
    publish = {
      enable = true;
      userServices = true;  # Samba-Freigabe für macOS und Linux sichtbar machen
    };'
  fi
  AVAHI_NIX+='
  };'
fi

# Samba: Client-Werkzeuge kommen in die Systempakete, der Server hier
SAMBA_NIX=""
if [[ $SAMBA == server ]]; then
  SAMBA_NIX="  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = \"WORKGROUP\";
        \"server string\" = \"$NIX_HOSTNAME\";
        security = \"user\";
        \"map to guest\" = \"never\";      # kein Gastzugang
        \"server min protocol\" = \"SMB2_10\"; # kein SMB1
      };
      freigabe = {
        path = \"/home/$NIX_USER/Freigabe\";
        browseable = \"yes\";
        \"read only\" = \"no\";
        \"valid users\" = \"$NIX_USER\";   # Samba-Passwort: sudo smbpasswd -a $NIX_USER
        \"create mask\" = \"0644\";
        \"directory mask\" = \"0755\";
      };
    };
  };
  services.samba-wsdd = {
    enable = true;        # in der Windows-Netzwerkumgebung sichtbar
    openFirewall = true;
  };"
fi

SSH_NIX=""
if (( SSHD )); then
  SSH_NIX='  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };'
fi

# Programme mit eigener NixOS-Einbindung
PROGRAMS_NIX='  programs.direnv.enable = true;  # Projektumgebungen, inkl. nix-direnv
  programs.mtr.enable = true;     # mtr ohne root
  programs.nh = {
    enable = true;                # nh os switch -f "<nixpkgs/nixos>", nh search
    clean = {
      enable = true;              # alte Generationen und Pakete wöchentlich aufräumen
      dates = "weekly";
      extraArgs = "--keep 10 --keep-since 30d";
    };
  };'

# Minimal: Standard-Apps weglassen, Terminal, Dateimanager und Editor bleiben
DESKTOP_PKGS=""
if [[ $DESKTOP_MODE == minimal ]]; then
  case $DESKTOP in
    gnome)
      DESKTOP_NIX+='
  # Minimal: keine GNOME-Standard-Apps, nur das Nötigste unten in den Systempaketen
  services.gnome.core-apps.enable = false;
  environment.gnome.excludePackages = with pkgs; [ gnome-tour gnome-user-docs ];'
      DESKTOP_PKGS='
    # GNOME minimal
    gnome-console
    nautilus
    gnome-text-editor
    gnome-system-monitor' ;;
    plasma)
      DESKTOP_NIX+='
  # Minimal: Konsole, Dolphin, Ark, Spectacle und Discover bleiben
  environment.plasma6.excludePackages = with pkgs.kdePackages; [
    elisa gwenview okular kate khelpcenter krdp
  ];' ;;
    cosmic)
      DESKTOP_NIX+='
  # Minimal: Terminal, Dateien, Editor und Store bleiben
  environment.cosmic.excludePackages = with pkgs; [ cosmic-player cosmic-reader ];' ;;
    xfce)
      DESKTOP_NIX+='
  # Minimal: Terminal, Thunar und Mousepad bleiben
  environment.xfce.excludePackages = with pkgs; [ parole ristretto ];' ;;
    cinnamon)
      DESKTOP_NIX+='
  # Minimal: keine Mint-Apps, Nemo ist Teil des Desktops
  services.cinnamon.apps.enable = false;
  programs.gnome-terminal.enable = true;'
      DESKTOP_PKGS='
    # Cinnamon minimal
    xed-editor' ;;
  esac
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
  };'
fi

SHELL_NIX=""
USER_SHELL=""
if [[ $LOGIN_SHELL == zsh ]]; then
  USER_SHELL='
    shell = pkgs.zsh;'
  if (( HOME_MANAGER )); then
    # zsh-Einstellungen kommen aus home.nix (home-manager)
    SHELL_NIX='  programs.zsh = {
    enable = true;
    enableGlobalCompInit = false;  # compinit übernimmt home-manager in ~/.zshrc'
    if (( OHMYZSH )); then
      SHELL_NIX+='
    promptInit = "";               # Prompt kommt vom oh-my-zsh-Theme'
    fi
    SHELL_NIX+='
  };
  environment.pathsToLink = [ "/share/zsh" ];  # Vervollständigung für Systempakete'
  elif (( OHMYZSH )); then
    # oh-my-zsh wird in ~/.zshrc geladen (vom Installer angelegt), nicht in /etc/zshrc
    SHELL_NIX='  programs.zsh = {
    enable = true;
    enableGlobalCompInit = false;  # compinit übernimmt oh-my-zsh in ~/.zshrc
    promptInit = "";               # Prompt kommt vom oh-my-zsh-Theme
  };
  # feste Pfade für ~/.zshrc: /run/current-system/sw/share/...
  environment.pathsToLink = [ "/share/oh-my-zsh" "/share/zsh-syntax-highlighting" ];'
  else
    SHELL_NIX='  programs.zsh = {
    enable = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
  };'
  fi
fi

USER_KEYS=""
if [[ -n $SSH_KEYS_NIX ]]; then
  USER_KEYS="
    openssh.authorizedKeys.keys = [$SSH_KEYS_NIX
    ];"
fi
ADMIN_GROUPS='"wheel" "networkmanager" "audio"'
if (( LIBVIRT )); then ADMIN_GROUPS+=' "libvirtd"'; fi
if [[ $CONTAINERS == docker ]]; then ADMIN_GROUPS+=' "docker"'; fi
USER_NIX="  users.users.\"$NIX_USER\" = {
    isNormalUser = true;
    extraGroups = [ $ADMIN_GROUPS ];$USER_SHELL$USER_KEYS
  };"
for u in $EXTRA_USERS; do
  USER_NIX+="
  users.users.\"$u\" = {
    isNormalUser = true;   # ohne Admin-Rechte
    extraGroups = [ \"networkmanager\" \"audio\" ];$USER_SHELL
  };"
done

# Fingerabdruck
FP_NIX=""
if (( FINGERPRINT )) || [[ $HW_PROFILE != none ]]; then
  if (( FINGERPRINT )); then
    FP_NIX='  services.fprintd.enable = true;  # Finger einlernen: fprintd-enroll oder in den Systemeinstellungen
'
  fi
  FP_NIX+='  # Konsole und Anmeldebildschirm nur mit Passwort, sonst blockiert das Warten auf den Finger
  # die Passworteingabe; sudo, Admin-Abfragen und Sperrbildschirm nehmen den Finger
  security.pam.services.login.fprintAuth = false;'
  case $DESKTOP in
    plasma)        FP_NIX+=$'\n  security.pam.services.sddm.fprintAuth = false;' ;;
    xfce|cinnamon) FP_NIX+=$'\n  security.pam.services.lightdm.fprintAuth = false;' ;;
    cosmic)        FP_NIX+=$'\n  security.pam.services.greetd.fprintAuth = false;' ;;
  esac
fi

# YubiKey/FIDO2 für sudo
U2F_NIX=""
if (( FIDO2_SUDO )); then
  U2F_NIX="  security.pam.u2f = {
    control = \"sufficient\";  # Schlüssel antippen genügt, sonst Passwort
    settings = {
      cue = true;            # Hinweis \"Please touch the device\" anzeigen
      origin = \"pam://$NIX_HOSTNAME\";
      appid = \"pam://$NIX_HOSTNAME\";
    };
  };
  security.pam.services.sudo.u2f.enable = true;  # Schlüssel: ~/.config/Yubico/u2f_keys (pamu2fcfg)"
  if [[ $DESKTOP != none ]]; then
    U2F_NIX+=$'\n  security.pam.services.polkit-1.u2f.enable = true;  # grafische Admin-Abfragen'
  fi
fi

# home-manager
HM_NIX=""
if (( HOME_MANAGER )); then
  HM_NIX='  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "vor-home-manager";  # vorhandene Dateien umbenennen statt abbrechen'
  if [[ -n $GIT_NAME || -n $GIT_EMAIL ]]; then
    HM_NIX+="
    users.\"$NIX_USER\" = {
      imports = [ ./home.nix ];
      programs.git.settings.user = {"
    if [[ -n $GIT_NAME ]]; then HM_NIX+=$'\n        name = "'"$GIT_NAME"'";'; fi
    if [[ -n $GIT_EMAIL ]]; then HM_NIX+=$'\n        email = "'"$GIT_EMAIL"'";'; fi
    HM_NIX+=$'\n      };\n    };'
  else
    HM_NIX+=$'\n    users."'"$NIX_USER"'".imports = [ ./home.nix ];'
  fi
  for u in $EXTRA_USERS; do HM_NIX+=$'\n    users."'"$u"'".imports = [ ./home.nix ];'; done
  HM_NIX+=$'\n  };'
  write_home_nix "$(dirname "$CFG")/home.nix"
fi

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

FWUPD_NIX='  services.fwupd.enable = true;  # Firmware-Updates: fwupdmgr refresh && fwupdmgr update'

# Laptop: Energie, Deckel
POWER_NIX=""
if (( LAPTOP )); then
  POWER_NIX='  services.power-profiles-daemon.enable = true;  # Energieprofile: sparsam, ausgeglichen, Leistung
  services.upower.enable = true;'
  if (( CPU_INTEL )); then
    POWER_NIX+='
  services.thermald.enable = true;  # Intel: Überhitzung vermeiden, ohne unnötig zu drosseln'
  fi
  case $LID in
    suspend)
      POWER_NIX+='
  services.logind.settings.Login.HandleLidSwitch = "suspend";' ;;
    hibernate)
      POWER_NIX+='
  services.logind.settings.Login.HandleLidSwitch = "suspend-then-hibernate";
  systemd.sleep.settings.Sleep.HibernateDelaySec = "1h";  # nach 1 Stunde Standby in den Ruhezustand' ;;
    ignore)
      POWER_NIX+='
  services.logind.settings.Login.HandleLidSwitch = "ignore";' ;;
  esac
fi

# Festplatten überwachen (nicht in VMs, dort gibt es keine SMART-Werte)
SMARTD_NIX=""
if (( ! IS_VM )); then
  SMARTD_NIX='  services.smartd = {
    enable = true;
    notifications.wall.enable = true;  # Warnung in allen Terminals'
  if [[ $DESKTOP != none && -z $EXTRA_USERS ]]; then
    SMARTD_NIX+='
    notifications.systembus-notify.enable = true;  # Warnung als Desktop-Benachrichtigung'
  fi
  SMARTD_NIX+='
  };'
fi

# Virtualisierung und Container
VIRT_NIX=""
if (( LIBVIRT )); then
  VIRT_NIX='  virtualisation.libvirtd.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;  # USB-Geräte an VMs durchreichen'
  if [[ $DESKTOP != none ]]; then
    VIRT_NIX+='
  programs.virt-manager.enable = true;'
  fi
fi
case $CONTAINERS in
  podman)
    if [[ -n $VIRT_NIX ]]; then VIRT_NIX+=$'\n'; fi
    VIRT_NIX+='  virtualisation.podman = {
    enable = true;
    dockerCompat = true;                         # "docker"-Befehl ruft podman auf
    defaultNetwork.settings.dns_enabled = true;  # Container finden sich per Name
  };' ;;
  docker)
    if [[ -n $VIRT_NIX ]]; then VIRT_NIX+=$'\n'; fi
    VIRT_NIX+='  virtualisation.docker.enable = true;' ;;
esac

# Backup mit restic
BACKUP_NIX=""
if (( BACKUP )); then
  BACKUP_NIX="  services.restic.backups.home = {
    repository = \"$BACKUP_REPO\";
    passwordFile = \"/root/.restic-passwort\";  # ohne dieses Passwort keine Wiederherstellung
    initialize = true;                         # legt das Backup-Ziel beim ersten Lauf an
    paths = [ \"/home\" ];
    exclude = [ \"/home/.snapshots\" \"/home/*/.cache\" ];
    timerConfig = {
      OnCalendar = \"daily\";
      Persistent = true;          # verpasste Läufe nachholen
      RandomizedDelaySec = \"1h\";
    };
    pruneOpts = [ \"--keep-daily 7\" \"--keep-weekly 4\" \"--keep-monthly 6\" ];"
  if [[ $BACKUP_REPO == sftp:* ]]; then
    BACKUP_NIX+="
    extraOptions = [ \"sftp.args='-o StrictHostKeyChecking=accept-new'\" ];  # Host-Schlüssel beim ersten Mal annehmen"
  fi
  BACKUP_NIX+="
  };"
fi

# Schriften
FONTS_NIX=""
if [[ $DESKTOP != none ]]; then
  FONTS_NIX='  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans        # Chinesisch, Japanisch, Koreanisch
    noto-fonts-color-emoji
    nerd-fonts.jetbrains-mono  # Symbole für Terminal-Themes
  ];'
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
    # Shell-Alltag
    htop
    btop
    ripgrep             # rg: schnelle Textsuche
    fd                  # schnelles find
    bat                 # cat mit Hervorhebung
    jq                  # JSON
    tmux
    tree
    file
    # Dateien und Archive
    unzip
    p7zip
    rsync
    ncdu                # Platzfresser finden
    lsof                # wer hält eine Datei offen?
    # Hardware
    nvme-cli
    lshw
    inxi                # Hardware-Übersicht
    # Netzwerk (mtr über programs.mtr)
    dnsutils            # dig, nslookup
    nmap
    tcpdump
    iperf3
    ethtool
    whois
    ipcalc
    # NixOS-Helfer
    nix-output-monitor  # nom: lesbare Build-Ausgabe
    nvd                 # Paketunterschiede zwischen Generationen
    nix-tree            # Speicherverbrauch des Systems untersuchen
    nix-index           # nix-locate: welches Paket enthält Datei X? (einmal nix-index ausführen)'
case $DESKTOP in
  gnome|plasma|cosmic)
    PKG_NIX+='
    wl-clipboard        # wl-copy, wl-paste' ;;
  xfce|cinnamon)
    PKG_NIX+='
    xclip               # Zwischenablage im Terminal' ;;
esac
if (( BACKUP )); then
  PKG_NIX+='
    restic              # Backups ansehen und wiederherstellen'
fi
case $CONTAINERS in
  podman) PKG_NIX+='
    podman-compose' ;;
  docker) PKG_NIX+='
    docker-compose' ;;
esac
if [[ $SAMBA != none ]]; then
  PKG_NIX+='
    # Samba-Client (im Dateimanager: smb://server/freigabe)
    cifs-utils          # mount -t cifs
    samba               # smbclient, nmblookup, smbpasswd'
fi
if (( SNAPPER )) && [[ $DESKTOP != none ]]; then
  PKG_NIX+='
    btrfs-assistant     # Snapshots grafisch verwalten'
fi
if (( TPM2 )); then
  PKG_NIX+="
    # LUKS an TPM2 binden (PCR 7 = Secure-Boot-Zustand), erst nach dem Aktivieren von Secure Boot
    (writeShellScriptBin \"luks-tpm2-enroll\" \"exec \${systemd}/bin/systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-uuid/$LUKS_UUID\")"
fi
if [[ $LOGIN_SHELL == zsh ]] && (( OHMYZSH && ! HOME_MANAGER )); then
  PKG_NIX+='
    # zsh: oh-my-zsh und Plugins, geladen in ~/.zshrc
    oh-my-zsh
    zsh-autosuggestions
    zsh-syntax-highlighting'
fi
if (( UKI )); then
  PKG_NIX+='
    # Secure Boot
    sbctl               # Schlüssel prüfen und in die Firmware eintragen'
fi
PKG_NIX+="$DESKTOP_PKGS"
PKG_NIX+='
  ];'

{
  printf '%s\n' "$HEADER_NIX"
  emit "Bootloader"                         "$BOOT_NIX"
  emit "Kernel"                             "$KERNEL_NIX"
  emit "Silent Boot"                        "$SILENT_NIX"
  emit "Laptop: Energie und Deckel"          "$POWER_NIX"
  emit "Verschlüsselung"                     "$LUKS_NIX"
  emit "btrfs-Mount-Optionen (ergänzen subvol=... aus hardware-configuration.nix)" "$FS_NIX"
  emit "Swap"                                "$SWAP_NIX"
  emit "Snapshots für /home"                 "$SNAP_NIX"
  emit "Backup"                              "$BACKUP_NIX"
  emit "Festplatten überwachen"              "$SMARTD_NIX"
  emit "btrfs-Scrub"                         "$SCRUB_NIX"
  emit "Netzwerk"                            "$NET_NIX"
  emit "Sprache und Zeit"                    "$LOCALE_NIX"
  emit "Tastatur"                            "$KB_NIX"
  emit "Desktop"                             "$DESKTOP_NIX"
  emit "Grafik"                              "$GPU_NIX"
  emit "Drucken, Bluetooth, Spiele"          "$EXTRAS_NIX"
  emit "Netzwerkdienste finden (mDNS)"       "$AVAHI_NIX"
  emit "Samba-Freigabe"                      "$SAMBA_NIX"
  emit "Virtualisierung und Container"       "$VIRT_NIX"
  emit "Schriften"                           "$FONTS_NIX"
  emit "Audio: PipeWire mit ALSA, Pulse und JACK" "$AUDIO_NIX"
  emit "Flatpak"                             "$FLATPAK_NIX"
  emit "Firmware"                            "$FWUPD_NIX"
  emit "Nix"                                 "$NIXSET_NIX"
  emit "Unfreie Pakete"                      "$UNFREE_NIX"
  emit "Automatische Updates"                "$UPDATE_NIX"
  emit "Shell"                               "$SHELL_NIX"
  emit "Fingerabdruck"                       "$FP_NIX"
  emit "YubiKey/FIDO2 für sudo"              "$U2F_NIX"
  emit "home-manager: Benutzer-Einstellungen in home.nix" "$HM_NIX"
  emit "SSH"                                 "$SSH_NIX"
  emit "Programme"                           "$PROGRAMS_NIX"
  emit "Benutzer"                            "$USER_NIX"
  emit "Systempakete"                        "$PKG_NIX"
  emit "Nicht ändern, auch nicht nach Upgrades" "  system.stateVersion = \"$STATE_VERSION\";"
  printf '}\n'
} > "$CFG"
}

# ---------- Vorabprüfungen ----------
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen (sudo -i)."

# Alles mitschreiben; landet am Ende in /var/log/nixos-install.log des neuen Systems.
# Passwörter tauchen nicht auf, weil sie ohne Echo eingegeben werden.
LOG=/tmp/nixos-install-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
echo "Protokoll: $LOG"

if [[ -n ${ANTWORTEN:-} ]]; then
  info "Lese Antworten aus $ANTWORTEN"
  load_answers "$ANTWORTEN"
fi
# Startmodus: wie der USB-Stick gestartet wurde; BOOT_MODE=bios erzwingt GRUB für Legacy-BIOS
if [[ -d /sys/firmware/efi ]]; then FW_MODE=uefi; else FW_MODE=bios; fi
BOOT_MODE=${BOOT_MODE:-$FW_MODE}
case $BOOT_MODE in
  uefi) [[ $FW_MODE == uefi ]] || die "BOOT_MODE=uefi geht nur, wenn der USB-Stick im UEFI-Modus gestartet wurde." ;;
  bios) ;;
  *)    die "BOOT_MODE muss uefi oder bios sein." ;;
esac
if [[ $BOOT_MODE == bios ]]; then
  info "Legacy-BIOS: Installation mit GRUB (ohne Secure Boot und UKI)"
  if [[ $FW_MODE == uefi ]]; then warn "Der Stick wurde per UEFI gestartet, installiert wird trotzdem für Legacy-BIOS."; fi
fi
for cmd in parted partprobe wipefs mkfs.fat mkfs.ext4 mkfs.btrfs btrfs cryptsetup curl nix-channel nix-instantiate nix-shell nixos-generate-config nixos-install nixos-enter udevadm; do
  command -v "$cmd" >/dev/null || die "'$cmd' fehlt. Läuft das Skript im NixOS-Installer?"
done
ping -c1 -W3 cache.nixos.org >/dev/null 2>&1 || warn "Keine Verbindung zu cache.nixos.org. WLAN mit 'nmtui' einrichten."

# Feste Suchpfade, damit <nixpkgs> auch bei "sudo bash" auf den root-Kanal zeigt
export NIX_PATH="nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:/nix/var/nix/profiles/per-user/root/channels"

# Reste eines abgebrochenen Laufs aufräumen
if mountpoint -q /mnt; then umount -R /mnt; fi
if [[ -e /dev/mapper/cryptroot ]]; then cryptsetup close cryptroot; fi

: "${ESP_GB:=1}"
: "${COMPRESS:=zstd}"
KERNEL_PRESET=${KERNEL:-}   # per Variable gesetzt? Dann bei NVIDIA nicht nachfragen
: "${KERNEL:=latest}"
: "${ZRAM:=j}"
if is_yes "$ZRAM"; then ZRAM=1; else ZRAM=0; fi
[[ $ESP_GB =~ ^[0-9]+$ ]] && (( ESP_GB >= 1 )) || die "ESP_GB muss mindestens 1 sein."

# Rechner erkennen: RAM, Akku (Laptop), Intel-CPU, virtuelle Maschine
RAM_GIB=$(( ( $(awk '/^MemTotal/ {print $2}' /proc/meminfo) + 1048575 ) / 1048576 ))
LAPTOP=0
for b in /sys/class/power_supply/*; do
  if [[ -r $b/type && $(<"$b/type") == Battery ]]; then LAPTOP=1; fi
done
if grep -q GenuineIntel /proc/cpuinfo; then CPU_INTEL=1; else CPU_INTEL=0; fi
if systemd-detect-virt -q 2>/dev/null; then IS_VM=1; else IS_VM=0; fi
LUKS_UUID=""; RESUME_UUID=""; RESUME_OFFSET=0; AVAHI_SETTINGS=0

# Menüs mit dialog, wenn ein Terminal da ist (TUI=n schaltet sie ab)
if [[ ${TUI:-j} != [nN]* && -t 0 ]] && [[ -r /dev/tty ]]; then
  echo "  Lade dialog für die Menüs ..."
  DIALOG_BIN=$(nix-build '<nixpkgs>' -A dialog --no-out-link 2>/dev/null)/bin/dialog || true
  if [[ -x $DIALOG_BIN ]]; then USE_DIALOG=1; else warn "dialog nicht verfügbar, frage im Textmodus."; fi
fi

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
  if [[ $(lsblk -dno TYPE "$n") == disk ]]; then echo "$n $rest"; fi
done)
(( ${#DISK_OPTS[@]} > 0 )) || die "Keine passende Platte gefunden."

choose DISK "Auf welchen Datenträger soll NixOS? (wird KOMPLETT gelöscht)" 1 "${DISK_OPTS[@]}"
[[ -b $DISK ]] || die "$DISK ist kein Blockgerät."
[[ $(lsblk -dno TYPE "$DISK") == disk ]] || die "$DISK ist keine ganze Platte."
[[ $DISK != "$LIVE_DEV" ]] || die "$DISK ist das Installationsmedium."
# Nie die Platte des laufenden Systems anfassen
for m in / /nix /nix/store /iso; do
  src=$(findmnt -no SOURCE "$m" 2>/dev/null | sed 's/\[.*//' || true)
  if [[ -b $src ]] && disk_devs "$DISK" | grep -qxF "$(realpath "$src")"; then
    die "$DISK enthält $m des laufenden Systems."
  fi
done

# ---------- Version ----------
LATEST_REL=$(detect_latest_release)
choose CHANNEL "Welche NixOS-Version?" 1 \
  "release|Aktuelles Release ${LATEST_REL:-?} (stabil, empfohlen)" \
  "unstable|Unstable (rollend, neueste Pakete)"
case $CHANNEL in
  release)
    [[ -n $LATEST_REL ]] || die "Aktuelles Release nicht ermittelbar. Netzwerk prüfen."
    CHANNEL_NAME="nixos-$LATEST_REL" ;;
  unstable)
    CHANNEL_NAME="nixos-unstable" ;;
  *) die "Unbekannte Version: $CHANNEL (release oder unstable)" ;;
esac

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
  unset KB
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
  loadkeys "$km" >/dev/null 2>&1 || note "Konsolen-Layout '$km' nicht gefunden, gilt erst im neuen System."
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
  unset LOCALE
  ask LOCALE "Locale, z. B. fr_FR.UTF-8"
fi
re_loc='^[a-z]{2,3}_[A-Z]{2}\.UTF-8(\+[a-z]{2,3}_[A-Z]{2}\.UTF-8)?$'
[[ $LOCALE =~ $re_loc ]] || die "Ungültige Locale: $LOCALE"
LANG_LOCALE=${LOCALE%%+*}
FORMAT_LOCALE=""
[[ $LOCALE == *+* ]] && FORMAT_LOCALE=${LOCALE#*+}

# ---------- Zeitzone ----------
ask TIMEZONE "Zeitzone (z. B. Europe/Berlin, Europe/Vienna, Europe/Zurich)" "Europe/Berlin" \
  '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$' "Ungültige Zeitzone, Form: Kontinent/Stadt"
if [[ -d /etc/zoneinfo && ! -f /etc/zoneinfo/$TIMEZONE ]]; then die "Unbekannte Zeitzone: $TIMEZONE"; fi

# ---------- 4. Desktop ----------
choose DESKTOP "Welche Desktop-Umgebung?" 2 \
  "gnome|GNOME" \
  "plasma|KDE Plasma 6" \
  "cosmic|COSMIC" \
  "xfce|Xfce" \
  "cinnamon|Cinnamon" \
  "none|Keine (nur Konsole, z. B. Server)"
case $DESKTOP in gnome|plasma|cosmic|xfce|cinnamon|none) ;; *) die "Unbekannter Desktop: $DESKTOP" ;; esac
if [[ $DESKTOP != none ]]; then
  choose DESKTOP_MODE "Umfang der Desktop-Installation?" 1 \
    "minimal|Minimal: Desktop, Terminal, Dateimanager, Editor, Firefox (empfohlen)" \
    "full|Vollständig: alle Standard-Apps des Desktops"
  case $DESKTOP_MODE in minimal|full) ;; *) die "DESKTOP_MODE muss minimal oder full sein." ;; esac
else
  DESKTOP_MODE=none
fi

# ---------- Grafik ----------
GPU_FOUND=""; NV_DEV=""; NV_ID=""; IGPU_DEV=""; IGPU_VENDOR=""
for d in /sys/bus/pci/devices/*; do
  [[ -r $d/class ]] || continue
  [[ $(<"$d/class") == 0x03* ]] || continue
  case $(<"$d/vendor") in
    0x10de) NV_DEV=${d##*/}; NV_ID=$(<"$d/device"); GPU_FOUND+=" NVIDIA" ;;
    0x8086) IGPU_DEV=${d##*/}; IGPU_VENDOR=intel; GPU_FOUND+=" Intel" ;;
    0x1002) if [[ -z $IGPU_DEV ]]; then IGPU_DEV=${d##*/}; IGPU_VENDOR=amd; fi; GPU_FOUND+=" AMD" ;;
    *)      GPU_FOUND+=" andere" ;;
  esac
done
if [[ $DESKTOP != none ]]; then
  if [[ -n $NV_DEV && -n $IGPU_DEV ]]; then gdef=4
  elif [[ -n $NV_DEV ]]; then gdef=3
  elif [[ $IGPU_VENDOR == amd ]]; then gdef=2
  elif [[ $IGPU_VENDOR == intel ]]; then gdef=1
  else gdef=6; fi
  choose GPU "Grafiktreiber? (erkannt:${GPU_FOUND:- nichts})" "$gdef" \
    "intel|Intel (Mesa, mit Video-Beschleunigung)" \
    "amd|AMD (Mesa)" \
    "nvidia|NVIDIA, proprietärer Treiber" \
    "nvidia-prime|NVIDIA + Intel/AMD im Laptop (proprietär, PRIME-Offload)" \
    "nouveau|NVIDIA, freier Treiber nouveau" \
    "generic|Andere oder virtuelle Maschine (Mesa)"
  case $GPU in intel|amd|nvidia|nvidia-prime|nouveau|generic) ;; *) die "Unbekannter Grafiktreiber: $GPU" ;; esac
else
  GPU=none
fi

NV_OPEN=${NV_OPEN:-}
if [[ $GPU == nvidia* ]]; then
  # Offene Kernelmodule gibt es ab Turing (GTX 16xx/RTX 20xx), PCI-Gerätenummer ab 0x1e00
  if [[ -n $NV_ID ]] && (( NV_ID >= 0x1e00 )); then odef=j; else odef=n; fi
  ask_yn NV_OPEN "Offene NVIDIA-Kernelmodule? (ab GTX 16xx/RTX 20xx ja; GTX 9xx/10xx nein, dann Treiber 580)" "$odef"
  if [[ -z $KERNEL_PRESET ]]; then
    ask_yn NV_LTS "Mit NVIDIA den LTS-Kernel nehmen? (proprietäre Treiber hinken neuen Kerneln oft hinterher)" j
    if (( NV_LTS )); then KERNEL=lts; fi
  fi
  if [[ $GPU == nvidia-prime && ( -z $NV_DEV || -z $IGPU_DEV ) ]]; then
    note "Für PRIME wurden nicht beide GPUs gefunden, nehme den normalen NVIDIA-Treiber."
    GPU=nvidia
  fi
fi

# ---------- Hardware-Profil (nixos-hardware) ----------
NH_DIR=${NH_DIR:-/nix/var/nix/profiles/per-user/root/channels/nixos-hardware}
DMI_DIR=${DMI_DIR:-/sys/class/dmi/id}
NH_URL=https://github.com/NixOS/nixos-hardware/archive/master.tar.gz
HW_MODEL=$(cat "$DMI_DIR"/sys_vendor "$DMI_DIR"/product_version "$DMI_DIR"/product_name 2>/dev/null | tr '\n' ' ' | tr -s ' ' || true)
if [[ -z ${HW_PROFILE-} ]]; then
  HW_PROFILE=none
  if (( ! IS_VM )) && [[ -n ${HW_MODEL// } ]] && add_channel nixos-hardware "$NH_URL" && [[ -r $NH_DIR/README.md ]]; then
    dmi=$HW_MODEL$(cat "$DMI_DIR"/product_family "$DMI_DIR"/board_name 2>/dev/null | tr '\n' ' ' || true)
    HW_OPTS=(); hw_top=0
    while IFS=$'\t' read -r score _ path name; do
      if (( ${#HW_OPTS[@]} == 0 )); then hw_top=$score; fi
      HW_OPTS+=("$path|$name ($path)")
    done < <(hw_candidates "$dmi" "$NH_DIR/README.md" | head -n 6)
    if (( ${#HW_OPTS[@]} > 0 )); then
      HW_OPTS+=("none|Kein Profil" "custom|Anderes Profil (Pfad aus nixos-hardware eingeben)")
      # Vorschlag nur bei eindeutigem Treffer, sonst „Kein Profil“
      if awk -v s="$hw_top" 'BEGIN { exit !(s >= 0.95) }'; then hdef=1; else hdef=$(( ${#HW_OPTS[@]} - 1 )); fi
      unset HW_PROFILE
      choose HW_PROFILE "Hardware-Profil aus nixos-hardware für ${HW_MODEL}? (Anpassungen speziell für dieses Modell)" "$hdef" "${HW_OPTS[@]}"
      if [[ $HW_PROFILE == custom ]]; then
        unset HW_PROFILE
        ask HW_PROFILE "Profil-Pfad, z. B. lenovo/thinkpad/t480 (Liste: github.com/NixOS/nixos-hardware)" "" \
          '^[a-z0-9][a-z0-9/_.-]*$' "Ungültiger Pfad"
      fi
    fi
  fi
fi
if [[ $HW_PROFILE != none ]]; then
  add_channel nixos-hardware "$NH_URL" || die "nixos-hardware ist nicht erreichbar. Netzwerk prüfen oder HW_PROFILE=none setzen."
  [[ -f $NH_DIR/$HW_PROFILE/default.nix ]] || die "Unbekanntes nixos-hardware-Profil: $HW_PROFILE"
fi

# ---------- Fingerabdruckleser ----------
if [[ -z ${FINGERPRINT-} ]]; then
  FINGERPRINT=0
  if (( ! IS_VM )); then
    detect_fingerprint
    case $FP_STATUS in
      supported)
        unset FINGERPRINT
        ask_yn FINGERPRINT "Fingerabdruckleser erkannt ($FP_DEV). Für sudo, Admin-Abfragen und den Sperrbildschirm einrichten?" j ;;
      unsupported)
        note "Fingerabdruckleser $FP_DEV erkannt, er wird von libfprint aber nicht unterstützt." ;;
    esac
  fi
elif is_yes "$FINGERPRINT"; then FINGERPRINT=1; else FINGERPRINT=0; fi

# ---------- Desktop-Extras ----------
if [[ $DESKTOP != none ]]; then
  ask_multi "Desktop-Extras" \
    PRINTING  "Drucker (CUPS, Netzwerkdrucker automatisch finden)" j \
    BLUETOOTH "Bluetooth" j \
    STEAM     "Steam und Gamemode" n \
    FLATPAK   "Flatpak mit Flathub" j
else
  PRINTING=0; BLUETOOTH=0; STEAM=0
  FLATPAK=0   # Flatpak braucht XDG-Portale, die erst ein Desktop mitbringt
fi

# ---------- Samba ----------
if [[ $DESKTOP != none ]]; then sdef=2; else sdef=1; fi
choose SAMBA "Samba (Windows- und NAS-Freigaben)?" "$sdef" \
  "none|Nein" \
  "client|Netzlaufwerke nutzen (Client)" \
  "server|Netzlaufwerke nutzen und ~/Freigabe im Netz freigeben (Server)"
case $SAMBA in none|client|server) ;; *) die "SAMBA muss none, client oder server sein." ;; esac

# ---------- Virtualisierung und Container ----------
echo
ask_yn LIBVIRT "Virtuelle Maschinen (libvirt/QEMU$(if [[ $DESKTOP != none ]]; then echo " mit virt-manager"; fi))?" n
choose CONTAINERS "Container?" 1 \
  "none|Keine" \
  "podman|Podman (ohne Daemon, auch per docker-Befehl nutzbar)" \
  "docker|Docker"
case $CONTAINERS in none|podman|docker) ;; *) die "CONTAINERS muss none, podman oder docker sein." ;; esac

# ---------- 5. Audio ----------
echo
echo "Audio: PipeWire mit ALSA (inkl. 32 bit), PulseAudio- und JACK-Unterstützung wird eingerichtet."

# ---------- Verschlüsselung und Bootloader ----------
echo
ask_yn ENCRYPT    "Datenträger mit LUKS verschlüsseln?" n
if [[ $BOOT_MODE == uefi ]]; then
  ask_yn UKI      "UKI (Unified Kernel Image) über lanzaboote? Bereitet Secure Boot vor" n
else
  if is_yes "${UKI:-n}"; then note "UKI und Secure Boot gibt es nur mit UEFI, wird übersprungen."; fi
  UKI=0
fi
TPM2=${TPM2:-}
if (( ENCRYPT && UKI )) && [[ $(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null) == 2 ]]; then
  ask_yn TPM2 "LUKS per TPM2 entsperren vorbereiten? (nach Secure Boot kein Passwort mehr, Passwort bleibt als Rückfall)" j
else
  TPM2=0
fi

# ---------- YubiKey/FIDO2 ----------
if (( ENCRYPT )); then
  ask_yn FIDO2_LUKS "YubiKey/FIDO2-Schlüssel zum Entsperren der Verschlüsselung? (wird am Ende eingerichtet, Passwort bleibt als Rückfall)" n
else
  FIDO2_LUKS=0
fi
ask_yn FIDO2_SUDO "YubiKey/FIDO2-Schlüssel für sudo$(if [[ $DESKTOP != none ]]; then echo " und Admin-Abfragen"; fi) (antippen statt Passwort)?" n

# ---------- Weitere Optionen ----------
if (( UKI )) || [[ $(uname -m) != x86_64 ]]; then
  RESCUE=0   # Memtest86+ und netboot.xyz gibt es nur mit systemd-boot bzw. GRUB auf x86_64
  ask_multi "Weitere Optionen" \
    UNFREE  "Unfreie Pakete erlauben (z. B. NVIDIA-Treiber, Steam)" j \
    SILENT  "Silent Boot (Plymouth-Startbildschirm, minimale Meldungen)" j \
    SNAPPER "Automatische Snapshots für /home (snapper, stündlich, wird ausgedünnt)" j
else
  ask_multi "Weitere Optionen" \
    UNFREE  "Unfreie Pakete erlauben (z. B. NVIDIA-Treiber, Steam)" j \
    SILENT  "Silent Boot (Plymouth-Startbildschirm, minimale Meldungen)" j \
    SNAPPER "Automatische Snapshots für /home (snapper, stündlich, wird ausgedünnt)" j \
    RESCUE  "$(if [[ $BOOT_MODE == uefi ]]; then echo "Rettungseinträge im Bootmenü (Memtest86+, netboot.xyz)"; else echo "Memtest86+ im Bootmenü (Arbeitsspeicher testen)"; fi)" j
fi
if (( ! UNFREE )) && { [[ $GPU == nvidia || $GPU == nvidia-prime ]] || (( STEAM )); }; then
  note "NVIDIA-Treiber und Steam brauchen unfreie Pakete, Unfree wird aktiviert."
  UNFREE=1
fi

# ---------- Backup ----------
ask_yn BACKUP "Backup von /home auf einen anderen Rechner (restic, täglich)?" n
BACKUP_PASS=""
if (( BACKUP )); then
  ask BACKUP_REPO "Backup-Ziel, z. B. sftp:benutzer@nas:/backup/laptop oder rest:http://server:8000/" ""
  [[ $BACKUP_REPO =~ ^(sftp:|rest:|s3:|b2:|azure:|gs:|rclone:|/) ]] || die "Unbekanntes restic-Ziel: $BACKUP_REPO"
  [[ $BACKUP_REPO != *[\"\$\\]* ]] || die "Das Backup-Ziel darf keine Anführungszeichen, \$ oder \\ enthalten."
  ask_pass BACKUP_PASS "Passwort für das Backup (verschlüsselt die Daten, unbedingt aufheben)"
fi

ask_yn AUTOUPDATE "Automatische Updates (nachts, ohne Neustart)?" n

# ---------- Laptop ----------
if (( LAPTOP )); then
  echo
  ask_yn HIBERNATE "Laptop erkannt. Ruhezustand (Hibernate) ermöglichen? Das Swapfile wird dafür mindestens so groß wie der RAM (${RAM_GIB} GiB)" j
  if (( HIBERNATE )); then
    choose LID "Beim Zuklappen des Deckels?" 2 \
      "suspend|Standby" \
      "hibernate|Standby, nach 1 Stunde Ruhezustand" \
      "ignore|Nichts tun"
  else
    choose LID "Beim Zuklappen des Deckels?" 1 \
      "suspend|Standby" \
      "ignore|Nichts tun"
  fi
  case $LID in suspend|hibernate|ignore) ;; *) die "LID muss suspend, hibernate oder ignore sein." ;; esac
  if [[ $LID == hibernate ]] && (( ! HIBERNATE )); then LID=suspend; fi
else
  if is_yes "${HIBERNATE:-n}"; then HIBERNATE=1; else HIBERNATE=0; fi
  LID=none
fi

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

ask_yn HOME_MANAGER "Benutzer-Einstellungen (Shell, Aliase, Git) mit home-manager verwalten? Sie stehen dann in /etc/nixos/home.nix" j
if (( HOME_MANAGER )); then
  ask GIT_NAME "Git: Name für Commits (leer = später)" "" '^[^"\\$]*$' "Name ohne Anführungszeichen, \\ und \$"
  ask GIT_EMAIL "Git: E-Mail für Commits (leer = später)" "" '^([^@[:space:]"\\$]+@[^@[:space:]"\\$]+)?$' "Ungültige E-Mail-Adresse"
else
  GIT_NAME=${GIT_NAME-}; GIT_EMAIL=${GIT_EMAIL-}
fi

ask_yn SSHD "SSH-Zugang einrichten (nur mit Schlüssel, kein Passwort)?" n
SSH_KEYS_NIX=""
if (( SSHD )); then
  ask SSH_KEYS "Öffentlichen Schlüssel einfügen oder gh:<GitHub-Name> (leer = später)" ""
  if [[ -n ${SSH_KEYS:-} ]]; then SSH_KEYS_NIX=$(ssh_keys_nix "$SSH_KEYS"); fi
  if [[ -z $SSH_KEYS_NIX ]]; then
    note "Ohne Schlüssel ist kein SSH-Login möglich. Später unter users.users.<name>.openssh.authorizedKeys.keys eintragen."
  fi
fi

# ---------- Weitere Angaben ----------
echo
ask NIX_HOSTNAME "Hostname" "nixos" '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$' "Ungültiger Hostname (Buchstaben, Ziffern, -)"
[[ $NIX_HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Ungültiger Hostname."

ask NIX_USER "Benutzername" "" '^[a-z_][a-z0-9_-]{0,31}$' "Ungültiger Benutzername (klein, a-z 0-9 _ -)"
[[ $NIX_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Ungültiger Benutzername (klein, a-z 0-9 _ -)."

ask EXTRA_USERS "Weitere Benutzer ohne Admin-Rechte, durch Leerzeichen getrennt (leer = keine)" ""
for u in $EXTRA_USERS; do
  [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Ungültiger Benutzername: $u"
  [[ $u != "$NIX_USER" && $u != root ]] || die "Benutzer $u ist schon vergeben."
done

if (( HIBERNATE )); then swapdef=$RAM_GIB; else swapdef=8; fi
ask SWAP_GB "Swapfile in GiB (0 = kein Swap)" "$swapdef" '^[0-9]+$' "Bitte eine ganze Zahl eingeben"
[[ $SWAP_GB =~ ^[0-9]+$ ]] || die "Swap-Größe muss eine ganze Zahl sein."
if (( HIBERNATE && SWAP_GB == 0 )); then die "Der Ruhezustand braucht ein Swapfile."; fi
if (( HIBERNATE && SWAP_GB < RAM_GIB )); then
  note "Für einen sicheren Ruhezustand sollte das Swapfile mindestens ${RAM_GIB} GiB groß sein."
fi

# nvme0n1 -> nvme0n1p1, sda -> sda1
if [[ $DISK =~ [0-9]$ ]]; then P="${DISK}p"; else P="$DISK"; fi
if [[ $BOOT_MODE == uefi ]]; then
  BOOTPART="${P}1"; ROOTPART="${P}2"; BOOT_START_MIB=1
else
  BIOSPART="${P}1"; BOOTPART="${P}2"; ROOTPART="${P}3"; BOOT_START_MIB=2   # 1 MiB BIOS-Boot davor
fi
BOOT_END_MIB=$(( BOOT_START_MIB + ESP_GB * 1024 ))   # /boot bekommt volle ESP_GB GiB

# GRUB-Ziel: stabiler Name unter /dev/disk/by-id, bevorzugt Modell/Seriennummer statt WWN
GRUB_DEV=$DISK
for l in /dev/disk/by-id/*; do
  [[ -e $l && $l != *-part* ]] || continue
  if [[ $(readlink -f "$l") == "$(readlink -f "$DISK")" ]]; then
    GRUB_DEV=$l
    if [[ $l != */wwn-* && $l != */nvme-eui.* ]]; then break; fi
  fi
done

case $KERNEL in
  latest) KERNEL_ATTR=linuxPackages_latest ;;
  lts)    KERNEL_ATTR=linuxPackages ;;
  *)      die "KERNEL muss latest oder lts sein." ;;
esac

# =====================================================================
#  Paketquelle und Vorabprüfung (es wurde noch nichts gelöscht)
# =====================================================================

if (( USE_DIALOG )); then clear >/dev/tty 2>/dev/null || true; fi
info "Setze Paketquelle auf $CHANNEL_NAME"
nix-channel --add "https://channels.nixos.org/$CHANNEL_NAME" nixos
nix-channel --update nixos || die "Paketquelle nicht erreichbar. Netzwerk prüfen. Es wurde nichts gelöscht."
# Release der gewählten Quelle, z. B. 26.05 oder bei unstable 26.11
TARGET_RELEASE=$(nix-instantiate --eval -E '(import <nixpkgs/lib>).trivial.release' 2>/dev/null | tr -d '"' || true)
echo "  NixOS-Release: ${TARGET_RELEASE:-unbekannt}"
if [[ $TARGET_RELEASE =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then
  STATE_VERSION=$TARGET_RELEASE
else
  STATE_VERSION=$(nixos-version 2>/dev/null | grep -oE '^[0-9]{2}\.[0-9]{2}' || echo "26.05")
fi
if (( HOME_MANAGER )); then
  if [[ $CHANNEL == unstable ]]; then hm_branch=master; else hm_branch=release-$LATEST_REL; fi
  if ! add_channel home-manager "https://github.com/nix-community/home-manager/archive/$hm_branch.tar.gz"; then
    if [[ $hm_branch == master ]]; then die "home-manager ist nicht erreichbar. Es wurde nichts gelöscht."; fi
    warn "home-manager hat (noch) keinen Zweig $hm_branch, nehme master."
    add_channel home-manager "https://github.com/nix-community/home-manager/archive/master.tar.gz" \
      || die "home-manager ist nicht erreichbar. Es wurde nichts gelöscht."
  fi
fi
# Avahi-Optionen wurden umbenannt; prüfen, welche Form die gewählte Quelle kennt
if [[ $SAMBA == server ]] && [[ $(nix-instantiate --eval -E '(import <nixpkgs/nixos> { configuration = {}; }).options.services.avahi ? settings' 2>/dev/null) == true ]]; then
  AVAHI_SETTINGS=1
fi

info "Prüfe die Konfiguration, bevor etwas gelöscht wird (dauert etwas)"
PRE=$(mktemp -d /tmp/nixos-vorab.XXXXXX)
write_mock_hw > "$PRE/hardware-configuration.nix"
LUKS_UUID=00000000-0000-0000-0000-000000000000
RESUME_UUID=00000000-0000-0000-0000-000000000000
RESUME_OFFSET=0
build_config "$PRE/configuration.nix"
while ! nix-instantiate '<nixpkgs/nixos>' -A system -I "nixos-config=$PRE/configuration.nix" > "$PRE/ergebnis.txt" 2>&1; do
  tail -n 30 "$PRE/ergebnis.txt" >&2
  if [[ $HW_PROFILE == none ]]; then
    die "Die erzeugte Konfiguration ist fehlerhaft (siehe oben, Datei: $PRE/configuration.nix). Es wurde nichts gelöscht."
  fi
  unset HW_RETRY
  ask_yn HW_RETRY "Die Konfiguration mit dem Hardware-Profil $HW_PROFILE ist fehlerhaft (Details im Protokoll). Ohne Profil erneut prüfen?" j
  if (( ! HW_RETRY )); then die "Abgebrochen, nichts verändert. Datei: $PRE/configuration.nix"; fi
  HW_PROFILE=none
  build_config "$PRE/configuration.nix"
done
if grep -qi 'evaluation warning' "$PRE/ergebnis.txt"; then grep -i -A1 'evaluation warning' "$PRE/ergebnis.txt" | head -n 10; fi
echo "  Konfiguration ist gültig."

# ---------- Zusammenfassung ----------
SUMMARY=$(cat <<EOF
  Datenträger:    $DISK
$(if [[ $BOOT_MODE == uefi ]]; then
    echo "    ${BOOTPART}  ${ESP_GB} GiB FAT32 -> /boot (EFI)"
  else
    echo "    ${BIOSPART}  1 MiB BIOS-Boot (für GRUB)"
    echo "    ${BOOTPART}  ${ESP_GB} GiB ext4 -> /boot"
  fi)
    ${ROOTPART}  Rest, $( if (( ENCRYPT )); then echo "LUKS2 -> btrfs"; else echo "btrfs"; fi ) ($COMPRESS)
  Version:        $CHANNEL_NAME
  Bootloader:     $( if [[ $BOOT_MODE == bios ]]; then echo "GRUB, Legacy-BIOS ($GRUB_DEV)"; elif (( UKI )); then echo "UKI via lanzaboote (Secure-Boot-Schlüssel werden erzeugt)"; else echo "systemd-boot (UEFI)"; fi )
  Kernel:         $(if [[ $KERNEL == latest ]]; then echo "neuester stabiler (linuxPackages_latest)"; else echo "Standard des Releases (linuxPackages)"; fi)
  Silent Boot:    $(yn "$SILENT")$(if (( SILENT )); then echo " (Plymouth)"; fi)
  Tastatur:       $XKB_LAYOUT${XKB_VARIANT:+ ($XKB_VARIANT)}
  Sprache:        $LANG_LOCALE${FORMAT_LOCALE:+, Formate $FORMAT_LOCALE}
  Zeitzone:       $TIMEZONE
  Desktop:        $DESKTOP$(if [[ $DESKTOP != none ]]; then echo " ($DESKTOP_MODE)"; fi)
  Grafik:         $GPU$(if [[ $GPU == nvidia* ]]; then echo " (offene Module: $(yn "$NV_OPEN"))"; fi)
  HW-Profil:      $(if [[ $HW_PROFILE != none ]]; then echo "nixos-hardware $HW_PROFILE"; else echo keins; fi)
  Fingerabdruck:  $(yn "$FINGERPRINT")
  Extras:         Drucken $(yn "$PRINTING"), Bluetooth $(yn "$BLUETOOTH"), Steam $(yn "$STEAM")
  Samba:          $(case $SAMBA in none) echo nein ;; client) echo "Client (Netzlaufwerke nutzen)" ;; server) echo "Client + Freigabe ~/Freigabe" ;; esac)
  VMs/Container:  libvirt $(yn "$LIBVIRT"), Container: $CONTAINERS
  Schriften:      $(if [[ $DESKTOP != none ]]; then echo "Noto inkl. Emoji/CJK, JetBrains Mono Nerd Font"; else echo "Standard"; fi)
  Plattenwarnung: $(if (( IS_VM )); then echo "nein (virtuelle Maschine)"; else echo "smartd"; fi)
  Audio:          PipeWire (ALSA + 32 bit, Pulse, JACK)
  Flatpak:        $(yn "$FLATPAK")$(if (( FLATPAK )); then echo " (Flathub)"; fi)
  Unfree:         $(yn "$UNFREE")
  Verschlüsselt:  $(yn "$ENCRYPT")$(if (( TPM2 )); then echo " (TPM2 vorbereitet)"; fi)
  YubiKey/FIDO2:  Verschlüsselung $(yn "$FIDO2_LUKS"), sudo $(yn "$FIDO2_SUDO")
  Bootmenü:       $(if (( RESCUE )) && [[ $BOOT_MODE == bios ]]; then echo "mit Memtest86+"; elif (( RESCUE )); then echo "mit Memtest86+ und netboot.xyz"; elif (( UKI )); then echo "UKI (ohne Rettungseinträge)"; else echo "ohne Rettungseinträge"; fi)
  Snapshots:      $(yn "$SNAPPER")$(if (( SNAPPER )); then echo " (/home, snapper)"; fi)
  Backup:         $(if (( BACKUP )); then echo "restic täglich nach $BACKUP_REPO"; else echo nein; fi)
  Laptop:         $(if (( LAPTOP )); then echo "ja, Ruhezustand $(yn "$HIBERNATE"), Deckel: $LID$(if (( CPU_INTEL )); then echo ", thermald"; fi)"; else echo nein; fi)
  Auto-Updates:   $(yn "$AUTOUPDATE")
  Aufräumen:      wöchentlich (nh clean, letzte 10 Generationen bleiben)
  Shell:          $LOGIN_SHELL$(if [[ $LOGIN_SHELL == zsh ]]; then echo " (oh-my-zsh: $(yn "$OHMYZSH"))"; fi)
  home-manager:   $(if (( HOME_MANAGER )); then echo "ja, /etc/nixos/home.nix${GIT_NAME:+, Git: $GIT_NAME}${GIT_EMAIL:+ <$GIT_EMAIL>}"; else echo nein; fi)
  Hostname:       $NIX_HOSTNAME
  Benutzer:       $NIX_USER (Admin)${EXTRA_USERS:+, $EXTRA_USERS}
  Swap:           ${SWAP_GB} GiB Swapfile$(if (( ZRAM )); then echo " + zram"; fi)
  SSH:            $(yn "$SSHD")$(if (( SSHD )); then if [[ -n $SSH_KEYS_NIX ]]; then echo " ($(grep -c . <<<"$SSH_KEYS_NIX") Schlüssel)"; else echo " (noch ohne Schlüssel)"; fi; fi)
EOF
)
info "Zusammenfassung"
printf '%s\n\n' "$SUMMARY"
DISK_INFO=$(lsblk -po NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$DISK")
if (( USE_DIALOG )); then
  dlg --title "Zusammenfassung (Pfeiltasten blättern)" --cr-wrap --no-collapse \
      --yes-label "Weiter" --no-label "Abbrechen" --yesno "$SUMMARY" 0 0 || dlg_abort
  confirm=$(dlg --title "Letzte Sicherheitsabfrage" --cr-wrap --no-collapse --inputbox \
    "ALLE Daten auf $DISK werden gelöscht:"$'\n\n'"$DISK_INFO"$'\n\n'"Eingehängtes, Swap, LVM, RAID und LUKS werden vorher gelöst."$'\n'"Zum Fortfahren den Gerätenamen ($DISK) eingeben:" 0 0) || dlg_abort
  clear >/dev/tty 2>/dev/null || true
else
  warn "ALLE Daten auf $DISK werden gelöscht:"
  printf '%s\n' "$DISK_INFO"
  echo "Eingehängte Partitionen, Swap, LVM, RAID und LUKS auf $DISK werden vorher automatisch gelöst."
  read -rp "Zum Fortfahren den Gerätenamen ($DISK) erneut eingeben: " confirm
fi
[[ $confirm == "$DISK" ]] || die "Abgebrochen, nichts verändert."
WIPED=1

# =====================================================================
#  Platte vorbereiten
# =====================================================================

info "Gebe $DISK frei"
release_disk "$DISK"
if lsblk -nro MOUNTPOINTS "$DISK" | grep -q . || [[ $(lsblk -lnpo NAME "$DISK" | grep -c /dev/mapper/ || true) -gt 0 ]]; then
  lsblk -po NAME,TYPE,MOUNTPOINTS "$DISK" >&2
  die "$DISK ist noch belegt und ließ sich nicht freigeben."
fi

info "Partitioniere $DISK"
# alte Signaturen der Partitionen und der Platte entfernen
while read -r part; do
  wipefs -af "$part" >/dev/null
done < <(lsblk -lnpo NAME "$DISK" | tail -n +2)
wipefs -af "$DISK" >/dev/null
udevadm settle

if [[ $BOOT_MODE == uefi ]]; then
  parted_ok=1
  parted -s "$DISK" -- \
    mklabel gpt \
    mkpart ESP fat32 "${BOOT_START_MIB}MiB" "${BOOT_END_MIB}MiB" \
    set 1 esp on \
    mkpart nixos btrfs "${BOOT_END_MIB}MiB" 100% || parted_ok=0
else
  # GPT mit BIOS-Boot-Partition für GRUB; pmbr_boot hilft älteren BIOS, die sonst nicht von GPT starten
  parted_ok=1
  parted -s "$DISK" -- \
    mklabel gpt \
    mkpart biosboot 1MiB 2MiB \
    set 1 bios_grub on \
    mkpart boot ext4 "${BOOT_START_MIB}MiB" "${BOOT_END_MIB}MiB" \
    mkpart nixos btrfs "${BOOT_END_MIB}MiB" 100% \
    disk_set pmbr_boot on || parted_ok=0
fi
if (( ! parted_ok )); then warn "parted meldet einen Fehler, lese die Partitionstabelle erneut ein."; fi
reread_partitions "$DISK"

if [[ $BOOT_MODE == uefi ]]; then
  info "Formatiere EFI-Partition"
  mkfs.fat -F 32 -n boot "$BOOTPART" >/dev/null
else
  info "Formatiere /boot"
  mkfs.ext4 -q -F -L boot "$BOOTPART"
fi

if (( ENCRYPT )); then
  info "Richte LUKS2 ein – Passphrase zweimal eingeben, danach zum Öffnen ein drittes Mal"
  cryptsetup luksFormat --type luks2 --batch-mode --verify-passphrase "$ROOTPART"
  cryptsetup open "$ROOTPART" cryptroot
  LUKS_UUID=$(cryptsetup luksUUID "$ROOTPART")
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
if [[ $BOOT_MODE == uefi ]]; then
  mount -o umask=077 "$BOOTPART" /mnt/boot
else
  mount "$BOOTPART" /mnt/boot
fi
if (( SNAPPER )); then
  btrfs subvolume create /mnt/home/.snapshots >/dev/null
  chmod 750 /mnt/home/.snapshots
  echo "  @home/.snapshots für snapper"
fi
findmnt -R /mnt

# =====================================================================
#  Konfiguration
# =====================================================================

if (( HIBERNATE )); then
  info "Lege das Swapfile für den Ruhezustand an"
  btrfs filesystem mkswapfile --size "${SWAP_GB}g" --uuid clear /mnt/swap/swapfile >/dev/null
  RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
  RESUME_UUID=$(blkid -s UUID -o value "$BTRFS_DEV")
  echo "  resume_offset=$RESUME_OFFSET auf UUID $RESUME_UUID"
fi

info "Erzeuge Konfiguration"
nixos-generate-config --root /mnt >/dev/null
HW=/mnt/etc/nixos/hardware-configuration.nix
CFG=/mnt/etc/nixos/configuration.nix

grep -q 'subvol=@"' "$HW" || warn "subvol=@ fehlt in hardware-configuration.nix – bitte prüfen."
if (( ENCRYPT )) && ! grep -q 'luks.devices."cryptroot"' "$HW"; then
  warn "LUKS-Eintrag für cryptroot fehlt in hardware-configuration.nix – bitte vor der Installation prüfen."
fi

mv "$CFG" "$CFG.generated"
build_config "$CFG"


echo "  $CFG geschrieben (Original: configuration.nix.generated)"
unset EDIT_CFG
ask_yn EDIT_CFG "configuration.nix vor der Installation ansehen/bearbeiten?" n
if (( EDIT_CFG )); then "${EDITOR:-nano}" "$CFG" </dev/tty >/dev/tty 2>&1; fi

# =====================================================================
#  Installation
# =====================================================================

if (( UKI )); then
  info "Erzeuge Secure-Boot-Schlüssel für lanzaboote"
  rm -rf /var/lib/sbctl
  nix-shell -p sbctl --run "sbctl create-keys"
  mkdir -p /mnt/var/lib
  cp -a /var/lib/sbctl /mnt/var/lib/
  [[ -f /mnt/var/lib/sbctl/keys/db/db.key ]] || die "Schlüssel fehlen unter /mnt/var/lib/sbctl."
fi

if (( UKI )); then
  info "Installiere NixOS (lanzaboote wird aus dem Quellcode gebaut, rechne mit 20–40 Minuten)"
else
  info "Installiere NixOS (je nach Desktop und Leitung 10–30 Minuten)"
fi
# Alle Kanäle (nixos, ggf. home-manager und nixos-hardware) ins neue System übernehmen
CHANNELS_PATH=$(readlink -f /nix/var/nix/profiles/per-user/root/channels)
while ! nixos-install --no-root-passwd --channel "$CHANNELS_PATH"; do
  warn "nixos-install ist fehlgeschlagen. Die Ursache steht oben und im Protokoll."
  unset RETRY
  choose RETRY "Wie weiter?" 1 \
    "edit|configuration.nix bearbeiten und erneut versuchen" \
    "again|Ohne Änderung erneut versuchen (z. B. nach einem Netzwerkfehler)" \
    "abort|Abbrechen"
  case $RETRY in
    edit)  "${EDITOR:-nano}" "$CFG" </dev/tty >/dev/tty 2>&1 ;;
    again) ;;
    *)     die "Installation abgebrochen. Konfiguration: $CFG, eingehängt unter /mnt." ;;
  esac
done

# Kanal-Liste für spätere Updates (nix-channel --update) im neuen System
install -d -m 700 /mnt/root
nix-channel --list | awk 'NF == 2 { print $2, $1 }' > /mnt/root/.nix-channels

info "root-Passwort setzen"
until nixos-enter --root /mnt -c 'passwd root'; do warn "Nochmal versuchen."; done

info "Passwort für $NIX_USER setzen"
until nixos-enter --root /mnt -c "passwd $NIX_USER"; do warn "Nochmal versuchen."; done

for u in $EXTRA_USERS; do
  info "Passwort für $u setzen"
  until nixos-enter --root /mnt -c "passwd $u"; do warn "Nochmal versuchen."; done
done

if [[ $LOGIN_SHELL == zsh ]] && (( ! HOME_MANAGER )); then
  for u in $NIX_USER $EXTRA_USERS; do
    info "Lege ~/.zshrc für $u an"
    # Ohne ~/.zshrc startet zsh beim ersten Login den Einrichtungsassistenten
    nixos-enter --root /mnt -c "install -d -m 700 -o $u -g users /home/$u"
    if (( OHMYZSH )); then
      write_zshrc_ohmyzsh > "/mnt/home/$u/.zshrc"
    else
      write_zshrc_plain > "/mnt/home/$u/.zshrc"
    fi
    nixos-enter --root /mnt -c "chown $u:users /home/$u/.zshrc && chmod 644 /home/$u/.zshrc"
  done
fi

if (( BACKUP )); then
  info "Richte das Backup ein"
  install -d -m 700 /mnt/root
  ( umask 077; printf '%s' "$BACKUP_PASS" > /mnt/root/.restic-passwort )
  if [[ $BACKUP_REPO == sftp:* ]]; then
    if nixos-enter --root /mnt -c "install -d -m 700 /root/.ssh && ssh-keygen -q -t ed25519 -N '' -C backup@$NIX_HOSTNAME -f /root/.ssh/id_ed25519"; then
      BACKUP_PUBKEY=$(cat /mnt/root/.ssh/id_ed25519.pub)
    else
      warn "SSH-Schlüssel für das Backup konnte nicht erzeugt werden. Später: sudo ssh-keygen -t ed25519"
    fi
  fi
fi

# Fragt bei einem fehlgeschlagenen Schritt mit Sicherheitsschlüssel nach; 0 = nochmal, 1 = überspringen
key_retry() {
  unset KEY_RETRY
  choose KEY_RETRY "$1 hat nicht geklappt. Wie weiter?" 1 \
    "again|Nochmal versuchen (Schlüssel eingesteckt?)" \
    "skip|Überspringen, später einrichten"
  [[ $KEY_RETRY == again ]]
}

if (( FIDO2_LUKS )); then
  info "YubiKey/FIDO2 für die Verschlüsselung: Schlüssel einstecken. Erst das LUKS-Passwort, dann ggf. die PIN des Schlüssels, dann antippen"
  until systemd-cryptenroll --fido2-device=auto "$ROOTPART" </dev/tty; do
    if ! key_retry "Das Einrichten des Schlüssels für die Verschlüsselung"; then
      FIDO2_LUKS_LATER=1
      break
    fi
  done
fi

if (( FIDO2_SUDO )); then
  info "YubiKey/FIDO2 für sudo: Schlüssel einstecken, ggf. PIN eingeben und antippen, wenn er blinkt"
  until U2F_LINE=$(nix-shell -p pam_u2f --run "pamu2fcfg -u $NIX_USER -o pam://$NIX_HOSTNAME -i pam://$NIX_HOSTNAME" </dev/tty) \
        && [[ $U2F_LINE == "$NIX_USER:"* ]]; do
    if ! key_retry "Das Einrichten des Schlüssels für sudo"; then
      U2F_LINE=""
      break
    fi
  done
  if [[ -n ${U2F_LINE-} ]]; then
    nixos-enter --root /mnt -c "install -d -m 700 -o $NIX_USER -g users /home/$NIX_USER/.config /home/$NIX_USER/.config/Yubico"
    printf '%s\n' "$U2F_LINE" > "/mnt/home/$NIX_USER/.config/Yubico/u2f_keys"
    nixos-enter --root /mnt -c "chown $NIX_USER:users /home/$NIX_USER/.config/Yubico/u2f_keys && chmod 600 /home/$NIX_USER/.config/Yubico/u2f_keys"
  fi
fi

save_answers /mnt/etc/nixos/install-antworten.env

if [[ $SAMBA == server ]]; then
  info "Lege ~/Freigabe an und setze das Samba-Passwort für $NIX_USER"
  nixos-enter --root /mnt -c "install -d -m 700 -o $NIX_USER -g users /home/$NIX_USER/Freigabe"
  echo "  Das Samba-Passwort ist getrennt vom Login-Passwort, darf aber gleich sein."
  if ! nixos-enter --root /mnt -c "mkdir -p /var/lib/samba/private /var/lock/samba /var/cache/samba /run/samba && smbpasswd -a $NIX_USER"; then
    warn "Samba-Passwort nicht gesetzt. Nach dem Start: sudo smbpasswd -a $NIX_USER"
  fi
fi

info "Installation abgeschlossen."
if (( UKI )); then
  cat <<'EOF'
  Secure Boot ist vorbereitet, aber noch nicht aktiv. Nach dem ersten Start:
    1. sudo sbctl verify
       ✓ bei BOOTX64.EFI, systemd-bootx64.efi und /EFI/Linux/nixos-generation-*.efi
       ✗ bei /EFI/nixos/kernel-*.efi ist richtig so: Die signierte UKI prüft den Kernel
         über seine Prüfsumme. Den Kernel NICHT mit sbctl signieren, sonst startet die
         Generation nicht mehr ("Kernel hash does not match").
    2. Im Firmware-Setup Secure Boot einschalten und in den "Setup Mode" setzen
       (nicht "alle Schlüssel löschen")
    3. sudo sbctl enroll-keys --microsoft
    4. Neu starten, prüfen mit: bootctl status
EOF
  if (( TPM2 )); then
    cat <<'EOF'
    5. sudo luks-tpm2-enroll       -> LUKS-Passwort einmal eingeben, danach entsperrt der TPM
       Nach Firmware-Updates oder geänderten Secure-Boot-Schlüsseln fragt der Start wieder
       nach dem Passwort; dann luks-tpm2-enroll erneut ausführen.
EOF
  fi
fi
if [[ $GPU == nvidia-prime ]]; then
  echo "  NVIDIA-GPU für ein Programm nutzen: nvidia-offload <programm>"
fi
if (( BACKUP )); then
  echo "  Backup: täglich nach $BACKUP_REPO. Erster Lauf von Hand: sudo systemctl start restic-backups-home"
  if [[ -n ${BACKUP_PUBKEY:-} ]]; then
    echo "  Diesen Schlüssel auf dem Backup-Ziel in ~/.ssh/authorized_keys eintragen:"
    echo "    $BACKUP_PUBKEY"
  fi
  echo "  Das Backup-Passwort gut aufheben, ohne es ist keine Wiederherstellung möglich."
fi
if (( FINGERPRINT )); then
  echo "  Fingerabdruck einlernen: fprintd-enroll (oder Systemeinstellungen -> Benutzer)"
fi
if (( ${FIDO2_LUKS_LATER:-0} )); then
  echo "  YubiKey für die Verschlüsselung später: sudo systemd-cryptenroll --fido2-device=auto /dev/disk/by-uuid/$LUKS_UUID"
fi
if (( FIDO2_SUDO )) && [[ -z ${U2F_LINE-} ]]; then
  echo "  YubiKey für sudo später: mkdir -p ~/.config/Yubico && pamu2fcfg -o pam://$NIX_HOSTNAME -i pam://$NIX_HOSTNAME > ~/.config/Yubico/u2f_keys"
  echo "    (pamu2fcfg mit: nix-shell -p pam_u2f)"
fi
if (( FIDO2_SUDO )); then
  echo "  Zweiten YubiKey als Ersatz anmelden: pamu2fcfg -n -o pam://$NIX_HOSTNAME -i pam://$NIX_HOSTNAME >> ~/.config/Yubico/u2f_keys"
fi
if (( HOME_MANAGER )); then
  echo "  Benutzer-Einstellungen (Shell, Aliase, Git): /etc/nixos/home.nix, danach: sudo nixos-rebuild switch"
fi
if [[ $HW_PROFILE != none ]]; then
  echo "  Hardware-Profil: nixos-hardware $HW_PROFILE (Updates mit: sudo nix-channel --update)"
fi
echo "  Antworten für weitere Installationen: /etc/nixos/install-antworten.env"
if [[ $SAMBA == server ]]; then
  echo "  Samba-Freigabe: Windows \\\\$NIX_HOSTNAME\\freigabe, macOS/Linux smb://$NIX_HOSTNAME/freigabe"
fi
install -m 600 "$LOG" /mnt/var/log/nixos-install.log
echo "  Protokoll gespeichert unter /var/log/nixos-install.log"
unset REBOOT
ask_yn REBOOT "Jetzt aushängen und neu starten?" j
if (( REBOOT )); then
  umount -R /mnt
  if (( ENCRYPT )); then cryptsetup close cryptroot; fi
  reboot
else
  echo "System bleibt unter /mnt eingehängt. Später: umount -R /mnt && reboot"
fi
