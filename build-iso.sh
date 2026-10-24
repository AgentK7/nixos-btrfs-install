#!/usr/bin/env bash
# Baut ein NixOS-Installer-ISO mit eingebautem nixos-btrfs-install.
# Braucht Nix (NixOS oder Nix auf einem anderen Linux, x86_64) und Internet.
#
#   bash build-iso.sh [Optionen]
#
#   --antworten DATEI     Antwortdatei einbauen (install-antworten.env einer früheren Installation)
#   --passwoerter DATEI   Passwortdatei einbauen (LUKS_PASS, USER_HASH …). Achtung: Jeder mit dem
#                         Stick kann sie lesen. Für Benutzer besser *_HASH statt Klartext verwenden.
#   --auto                Ohne Rückfragen installieren (AUTO=j). Zielplatte: die einzige interne Platte,
#                         vor dem Löschen läuft ein Countdown, jede Taste bricht ab.
#   --disk GERÄT          Feste Zielplatte statt automatischer Wahl, z. B. /dev/nvme0n1
#   --warten SEKUNDEN     Länge des Countdowns (Standard 30)
#   --wlan SSID PASSWORT  WLAN für das Live-System, wird auch ins neue System übernommen
#   --ssh-key SCHLÜSSEL   SSH-Zugang zum Live-System (Benutzer nixos): Datei, Schlüssel oder gh:<Name>
#   --tastatur LAYOUT     Konsolen-Tastatur des Live-Systems, z. B. de (Standard: aus der Antwortdatei, sonst us)
#   --proxy URL           HTTP-Proxy für Downloads, z. B. http://proxy.schule.local:3128 (gilt auch im neuen System)
#   --ca DATEI            zusätzliches CA-Zertifikat (PEM), z. B. für einen Proxy mit HTTPS-Prüfung
#   --kein-autostart      Installer nicht automatisch starten, nur als Befehl nixos-btrfs-install
#   --version VERSION     NixOS-Version des Live-Systems: release (Standard), unstable oder z. B. 26.05
#   --skript DATEI        anderes install.sh (Standard: neben diesem Skript, sonst von GitHub)
#   -o, --ausgabe ORDNER  Zielordner für das ISO (Standard: aktueller Ordner)
#
# Beispiel Schule, 30 gleiche Rechner:
#   bash build-iso.sh --antworten antworten.env --passwoerter geheim.env --auto --tastatur de
#   sudo dd if=nixos-btrfs-installer-*.iso of=/dev/sdX bs=4M status=progress oflag=sync

set -Eeuo pipefail

die() { printf '\e[31mFEHLER:\e[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\n\e[32m==>\e[0m \e[1m%s\e[0m\n' "$*"; }
warn() { printf '\e[33m!!\e[0m  %s\n' "$*" >&2; }

RAW=https://raw.githubusercontent.com/AgentK7/nixos-btrfs-install/main/install.sh
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ANTWORTEN="" PASSWOERTER="" AUTO=0 DISK="" WARTEN=30 WLAN_SSID="" WLAN_PSK="" SSH_KEY="" KEYMAP=""
AUTOSTART=1 VERSION=release SKRIPT="" OUT=$PWD PROXY="" CA=""

while (( $# )); do
  case $1 in
    --antworten)      ANTWORTEN=${2:?}; shift 2 ;;
    --passwoerter)    PASSWOERTER=${2:?}; shift 2 ;;
    --auto)           AUTO=1; shift ;;
    --disk)           DISK=${2:?}; shift 2 ;;
    --warten)         WARTEN=${2:?}; shift 2 ;;
    --wlan)           WLAN_SSID=${2:?}; WLAN_PSK=${3:?"--wlan braucht SSID und Passwort"}; shift 3 ;;
    --ssh-key)        SSH_KEY=${2:?}; shift 2 ;;
    --tastatur)       KEYMAP=${2:?}; shift 2 ;;
    --proxy)          PROXY=${2:?}; shift 2 ;;
    --ca)             CA=${2:?}; shift 2 ;;
    --kein-autostart) AUTOSTART=0; shift ;;
    --version)        VERSION=${2:?}; shift 2 ;;
    --skript)         SKRIPT=${2:?}; shift 2 ;;
    -o|--ausgabe)     OUT=${2:?}; shift 2 ;;
    -h|--help)        sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "Unbekannte Option: $1 (Hilfe: --help)" ;;
  esac
done

command -v nix-build >/dev/null || die "nix-build fehlt. Das ISO lässt sich nur mit Nix bauen (NixOS oder https://nixos.org/download)."
[[ $(uname -s) == Linux ]] || die "Das ISO lässt sich nur unter Linux bauen."
[[ $WARTEN =~ ^[0-9]+$ ]] || die "--warten braucht eine Zahl."
[[ -z $PROXY || $PROXY =~ ^https?://[A-Za-z0-9._:@%-]+/?$ ]] || die "Ungültiger Proxy: $PROXY (Form: http://host:port)"
[[ -z $CA ]] || grep -q 'BEGIN CERTIFICATE' "$CA" 2>/dev/null || die "Kein PEM-Zertifikat: $CA"
[[ -z $DISK || $DISK =~ ^/dev/[A-Za-z0-9/_.-]+$ ]] || die "Ungültige Platte: $DISK"
[[ -n $DISK ]] && (( ! AUTO )) && warn "--disk wirkt nur zusammen mit --auto."
(( AUTO && ! AUTOSTART )) && die "--auto und --kein-autostart passen nicht zusammen."
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)

# ---------- NixOS-Version ----------
case $VERSION in
  release)
    rel=$(curl -fsSL --max-time 15 'https://prometheus.nixos.org/api/v1/query?query=channel_revision' 2>/dev/null \
          | grep -o '"metric":{[^}]*}' | grep '"status":"stable"' \
          | grep -o '"channel":"nixos-[0-9][0-9]\.[0-9][0-9]"' | grep -o '[0-9][0-9]\.[0-9][0-9]' | sort -V | tail -n1 || true)
    [[ -n $rel ]] || die "Aktuelles Release nicht ermittelbar. Bitte --version 26.05 o. Ä. angeben."
    CHANNEL=nixos-$rel ;;
  unstable)        CHANNEL=nixos-unstable ;;
  [0-9][0-9].[0-9][0-9]) CHANNEL=nixos-$VERSION ;;
  *)               die "--version: release, unstable oder z. B. 26.05" ;;
esac
NIXPKGS=${ISO_NIXPKGS:-https://channels.nixos.org/$CHANNEL/nixexprs.tar.xz}   # ISO_NIXPKGS: eigener nixpkgs-Pfad

# ---------- Bauordner ----------
B=$(mktemp -d /tmp/nixos-iso.XXXXXX)
trap 'rm -rf "$B"' EXIT
chmod 700 "$B"

if [[ -n $SKRIPT ]]; then
  cp "$SKRIPT" "$B/install.sh"
elif [[ -f $SELF_DIR/install.sh ]]; then
  cp "$SELF_DIR/install.sh" "$B/install.sh"
else
  info "Lade install.sh von GitHub"
  curl -fsSL "$RAW" -o "$B/install.sh" || die "install.sh nicht abrufbar."
fi
bash -n "$B/install.sh" || die "install.sh enthält Syntaxfehler."
grep -q 'nixos-btrfs-install\|NixOS-Installer' "$B/install.sh" || die "$SKRIPT sieht nicht nach dem Installer aus."

check_env() {   # nur NAME='wert'-Zeilen und Kommentare
  local bad
  bad=$(grep -vnE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='([^']|'\\\\'')*'[[:space:]]*(#.*)?$" "$1" || true)
  [[ -z $bad ]] || die "$1: unerwartete Zeilen (erlaubt sind nur NAME='wert'):"$'\n'"$bad"
}
if [[ -n $ANTWORTEN ]]; then
  [[ -r $ANTWORTEN ]] || die "Antwortdatei nicht lesbar: $ANTWORTEN"
  check_env "$ANTWORTEN"
  cp "$ANTWORTEN" "$B/antworten.env"
  if [[ -z $KEYMAP ]]; then
    kb=$(sed -n "s/^KB='\([a-z]*\).*/\1/p" "$ANTWORTEN" | head -n1)
    case $kb in gb) KEYMAP=uk ;; ch) KEYMAP=de_CH-latin1 ;; at) KEYMAP=de ;; *) KEYMAP=$kb ;; esac
  fi
fi
if [[ -n $PASSWOERTER ]]; then
  [[ -r $PASSWOERTER ]] || die "Passwortdatei nicht lesbar: $PASSWOERTER"
  check_env "$PASSWOERTER"
  install -m 600 "$PASSWOERTER" "$B/geheim.env"
  warn "Die Passwortdatei landet lesbar auf dem ISO. Den Stick wie einen Schlüssel behandeln."
fi
if (( AUTO )); then
  : > "$B/auto"
  [[ -n $DISK ]] && printf '%s' "$DISK" > "$B/disk"
  printf '%s' "$WARTEN" > "$B/warten"
  [[ -n $PASSWOERTER ]] || warn "--auto ohne --passwoerter: Die Installation bricht ab, weil das Benutzerpasswort fehlt."
  grep -q "^NIX_USER=" "${ANTWORTEN:-/dev/null}" 2>/dev/null || warn "--auto: In der Antwortdatei fehlt NIX_USER, die Installation bricht dann ab."
fi
(( AUTOSTART )) || : > "$B/kein-autostart"
if [[ -n $WLAN_SSID ]]; then
  printf '%s' "$WLAN_SSID" > "$B/wlan-ssid"
  printf '%s' "$WLAN_PSK" > "$B/wlan-psk"
  warn "Das WLAN-Passwort landet lesbar auf dem ISO."
fi
if [[ -n $SSH_KEY ]]; then
  if [[ $SSH_KEY == gh:* ]]; then
    curl -fsSL "https://github.com/${SSH_KEY#gh:}.keys" -o "$B/ssh-keys" || die "Schlüssel von GitHub nicht abrufbar: $SSH_KEY"
  elif [[ -f $SSH_KEY ]]; then
    cp "$SSH_KEY" "$B/ssh-keys"
  else
    printf '%s\n' "$SSH_KEY" > "$B/ssh-keys"
  fi
  grep -qE '^(ssh-|ecdsa-|sk-)' "$B/ssh-keys" || die "Kein gültiger öffentlicher SSH-Schlüssel: $SSH_KEY"
fi
if [[ -n $PROXY ]]; then printf '%s' "$PROXY" > "$B/proxy"; fi
if [[ -n $CA ]]; then cp "$CA" "$B/ca.pem"; fi
if [[ -n $KEYMAP ]]; then
  [[ $KEYMAP =~ ^[A-Za-z0-9_-]+$ ]] || die "Ungültiges Tastaturlayout: $KEYMAP"
  printf '%s' "$KEYMAP" > "$B/keymap"
fi

cat > "$B/iso.nix" <<'NIX'
# NixOS-Installer-ISO mit nixos-btrfs-install, erzeugt von build-iso.sh
{ config, lib, pkgs, modulesPath, ... }:
let
  has = f: builtins.pathExists (./. + "/${f}");
  read = f: lib.fileContents (./. + "/${f}");
  auto = has "auto";
  # Umgebung für den Installer: Antworten und Passwörter immer, Automatik nur beim Autostart
  baseEnv = lib.optional (has "antworten.env") "ANTWORTEN=/etc/nixos-installer/antworten.env"
    ++ lib.optional (has "geheim.env") "PASSWORT_DATEI=/etc/nixos-installer/geheim.env"
    ++ lib.optional (has "ca.pem") "EXTRA_CA=/etc/nixos-installer/ca.pem";
  autoEnv = baseEnv ++ lib.optionals auto [
    "AUTO=j"
    "DISK=${if has "disk" then read "disk" else "auto"}"
    "CONFIRM_DISK=auto"
    "AUTO_WARTEN=${read "warten"}"
  ];
  envArgs = l: lib.escapeShellArgs l;
  installer = pkgs.writeShellScriptBin "nixos-btrfs-install" ''
    exec sudo -E env ${envArgs baseEnv} bash /etc/nixos-installer/install.sh "$@"
  '';
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal-new-kernel-no-zfs.nix" ];

  image.baseName = lib.mkForce "nixos-btrfs-installer-${config.system.nixos.release}-${pkgs.stdenv.hostPlatform.system}";

  environment.etc."nixos-installer/install.sh".source = ./install.sh;
  environment.etc."nixos-installer/antworten.env" = lib.mkIf (has "antworten.env") {
    source = ./antworten.env;
    mode = "0600";
  };
  environment.etc."nixos-installer/geheim.env" = lib.mkIf (has "geheim.env") {
    source = ./geheim.env;
    mode = "0600";
  };

  environment.etc."nixos-installer/ca.pem" = lib.mkIf (has "ca.pem") { source = ./ca.pem; };

  # Werkzeuge, die der Installer sonst erst herunterlädt
  environment.systemPackages = [ installer ] ++ (with pkgs; [
    dialog smartmontools sbctl sbsigntool pam_u2f git curl
  ]);

  console.keyMap = lib.mkIf (has "keymap") (read "keymap");

  # Proxy und eigene CA (z. B. Schulnetz); sudo reicht die Proxy-Variablen an den Installer weiter
  networking.proxy.default = lib.mkIf (has "proxy") (read "proxy");
  networking.proxy.noProxy = lib.mkIf (has "proxy") "127.0.0.1,localhost";
  security.pki.certificateFiles = lib.optional (has "ca.pem") ./ca.pem;
  security.sudo.extraConfig = ''
    Defaults env_keep += "http_proxy https_proxy ftp_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"
  '';

  # WLAN für das Live-System; der Installer übernimmt es ins neue System
  networking.networkmanager.ensureProfiles.profiles = lib.mkIf (has "wlan-ssid") {
    installer-wlan = {
      connection = { id = read "wlan-ssid"; type = "wifi"; };
      wifi = { mode = "infrastructure"; ssid = read "wlan-ssid"; };
      wifi-security = { key-mgmt = "wpa-psk"; psk = read "wlan-psk"; };
      ipv4.method = "auto";
      ipv6.method = "auto";
    };
  };

  # Fernzugriff auf das Live-System: ssh nixos@<rechner>
  users.users.nixos.openssh.authorizedKeys.keys =
    lib.mkIf (has "ssh-keys") (lib.filter (k: k != "") (lib.splitString "\n" (read "ssh-keys")));

  # Installer auf der ersten Konsole automatisch starten (sobald Netz da ist)
  programs.bash.interactiveShellInit = lib.mkIf (!has "kein-autostart") ''
    if [ "$(tty)" = /dev/tty1 ] && [ ! -e /tmp/.nixos-installer-gestartet ]; then
      touch /tmp/.nixos-installer-gestartet
      echo "Warte auf das Netzwerk ..."
      online() { curl -fsI --max-time 5 https://cache.nixos.org/nix-cache-info >/dev/null 2>&1; }
      for i in $(seq 1 ${if auto then "60" else "12"}); do
        if online; then break; fi
        sleep 5
      done
      if ! online && ${if auto then "false" else "true"}; then
        echo "Kein Netzwerk. WLAN auswählen (Esc beendet) ..."
        sleep 2
        nmtui connect || true
      fi
      sudo env ${envArgs autoEnv} bash /etc/nixos-installer/install.sh
      echo
      echo "Installer beendet. Erneut starten mit: nixos-btrfs-install"
    fi
  '';
}
NIX

if [[ -n ${ISO_NUR_PRUEFEN-} ]]; then   # nur auswerten, nichts bauen (für Tests)
  nix-instantiate '<nixpkgs/nixos>' -A config.system.build.isoImage -I "nixos-config=$B/iso.nix" -I "nixpkgs=$NIXPKGS"
  rm -rf "$OUT/iso-pruefung"; cp -r "$B" "$OUT/iso-pruefung"
  exit 0
fi
info "Baue das ISO ($CHANNEL) – beim ersten Mal 10–30 Minuten"
nix-build '<nixpkgs/nixos>' -A config.system.build.isoImage \
  -I "nixos-config=$B/iso.nix" -I "nixpkgs=$NIXPKGS" -o "$B/result"
iso=$(find -L "$B/result/iso" -name '*.iso' | head -n1)
[[ -n $iso ]] || die "Kein ISO gebaut."
install -m 644 "$iso" "$OUT/"
f=$OUT/$(basename "$iso")
info "Fertig: $f ($(du -h "$f" | cut -f1))"
echo "  Auf einen USB-Stick schreiben (sdX = Stick, ALLES darauf wird gelöscht):"
echo "    sudo dd if=$f of=/dev/sdX bs=4M status=progress oflag=sync"
if (( AUTO )); then
  echo "  Achtung: Dieses ISO installiert ohne Rückfrage auf $(if [[ -n $DISK ]]; then echo "$DISK"; else echo "die einzige interne Platte"; fi) (Countdown ${WARTEN} s)."
fi
