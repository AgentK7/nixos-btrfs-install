#!/usr/bin/env bash
# RiftLinux (Oculus-Rift-CV1-Treiber, https://github.com/AIIX/RiftLinux) auf NixOS installieren.
#
# Stellt /etc/nixos auf Flakes um und baut das System neu. Channel-Importe werden dabei automatisch zu
# Flake-Inputs: <home-manager/nixos>, <nixos-hardware/…>, <nixos-unstable>, <nixpkgs/…>, builtins.fetchTarball-URLs.
# Vorher wird /etc/nixos gesichert; scheitert der Build, wird automatisch zurückgesetzt.
#
# Aufruf:   curl -L is.gd/nixosrift -o rift.sh && sudo bash rift.sh
# Optional: NIXOS_DIR=/etc/nixos HOST=meinrechner sudo -E bash rift.sh
set -euo pipefail

NIXOS_DIR=${NIXOS_DIR:-/etc/nixos}
HOST=${HOST:-$(hostname)}
RIFT_VERSION=0.1.0
RIFT_URL="https://github.com/AIIX/RiftLinux/releases/download/v${RIFT_VERSION}/riftlinux-${RIFT_VERSION}-x86_64.tar.gz"
export NIX_CONFIG="experimental-features = nix-command flakes"

die()  { echo "Fehler: $*" >&2; exit 1; }
warn() { echo "Warnung: $*" >&2; }
[[ $EUID -eq 0 ]]                     || die "bitte mit sudo ausführen"
[[ $(uname -m) == x86_64 ]]           || die "RiftLinux gibt es nur für x86_64"
[[ -f $NIXOS_DIR/configuration.nix ]] || die "$NIXOS_DIR/configuration.nix fehlt"
cd "$NIXOS_DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Channels von root (die nutzt nixos-rebuild) – Name -> URL
declare -A CHANNELS=() INPUTS=() LOOKUP=() FETCH=()
while read -r name url; do [[ -n ${name:-} ]] && CHANNELS[$name]=$url; done < <(HOME=/root nix-channel --list 2>/dev/null || true)

# nixpkgs-Zweig: wie der nixos-Channel, sonst aus nixos-version (*pre* = unstable)
if [[ ${CHANNELS[nixos]:-} =~ /(nixos-[^/]+)/?$ ]]; then
    BRANCH=${BASH_REMATCH[1]}
else
    REL=$(nixos-version | cut -d. -f1,2)
    if [[ $REL == *pre* ]]; then BRANCH=nixos-unstable; else BRANCH="nixos-$REL"; fi
fi

# Git: Flakes sehen nur getrackte Dateien; Befehle als Besitzer des Repos ausführen
GIT_OWNER=""
if command -v git >/dev/null && top=$(git -c safe.directory='*' rev-parse --show-toplevel 2>/dev/null); then
    GIT_OWNER=$(stat -c %U "$top")
fi
git_do() {
    [[ -n $GIT_OWNER ]] || return 0
    if [[ $GIT_OWNER == root ]]; then git -c safe.directory='*' "$@"; else runuser -u "$GIT_OWNER" -- git "$@"; fi
}

# ---------------------------------------------------------------------------------------------------------------
# Helfer für die Umstellung
# ---------------------------------------------------------------------------------------------------------------
nixattr() { if [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_\'-]*$ ]]; then echo "$1"; else echo "\"$1\""; fi; }
reesc()   { sed -E 's,[][\.*^$+?(){}|#/],\\&,g' <<<"$1"; }

# Channel-/Tarball-URL -> Flake-Referenz
to_flakeref() {
    local u=${1%/}
    if [[ $u =~ ^https?://(nixos\.org/channels|channels\.nixos\.org)/([^/]+)$ ]]; then
        echo "github:NixOS/nixpkgs/${BASH_REMATCH[2]}"
    elif [[ $u =~ ^https?://github\.com/([^/]+)/([^/]+)/archive/(refs/(heads|tags)/)?(.+)\.tar\.gz$ ]]; then
        echo "github:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[5]}"
    else
        echo "$u"
    fi
}

# Datei ist ein Modul mit Argument "inputs"?
has_inputs_arg() {
    [[ $(nix eval --impure --expr "let f = import (/. + \"$(realpath "$1")\"); in
        builtins.isFunction f && (builtins.functionArgs f) ? inputs" 2>/dev/null) == true ]]
}
# Argumentnamen des Original-Moduls ("ATTRSET" = keine Funktion)
module_args() {
    nix eval --impure --raw --expr "let f = import (/. + \"$(realpath "$1")\"); in
        if builtins.isFunction f then builtins.concatStringsSep \" \" (builtins.attrNames (builtins.functionArgs f))
        else \"ATTRSET\"" 2>/dev/null
}

restore() {
    local f
    for f in flake.nix flake.lock riftlinux.nix; do
        [[ -e $BACKUP/$f ]] || { rm -f "$f"; git_do rm -q --cached --ignore-unmatch -- "$f" >/dev/null 2>&1 || true; }
    done
    cp -a "$BACKUP/." .
    echo "$NIXOS_DIR wurde aus $BACKUP wiederhergestellt." >&2
}
fail() { restore; die "$@"; }

# "inputs" als Modul-Argument ergänzen: $1 Originaldatei, $2 umgeschriebener Inhalt -> Ergebnis nach $1
add_inputs_arg() {
    local f=$1 conv=$2 try=$TMP/try.nix args ln
    cp "$conv" "$try"
    if ! has_inputs_arg "$try"; then
        args=$(module_args "$f") || fail "$f lässt sich nicht auswerten"
        if [[ $args == ATTRSET ]]; then                     # reines Attrset-Modul -> zur Funktion machen
            { echo "{ inputs, ... }:"; cat "$conv"; } > "$try"
        else                                                # Funktionskopf { … }: um inputs erweitern
            ln=$(awk '!/^[[:space:]]*(#.*)?$/ { print NR; exit }' "$conv")
            sed -E "${ln}s/^([[:space:]]*([A-Za-z_][A-Za-z0-9_'-]*@)?)\{/\1{ inputs,/" "$conv" > "$try"
            if ! has_inputs_arg "$try"; then                # z. B. "let … in" vor dem Kopf -> Original einpacken
                { echo "# Für Flakes umgestellt: Original eingepackt, damit \"inputs\" überall verfügbar ist."
                  echo "{ inputs${args:+, ${args// /, }}, ... }@args:"
                  echo "let orig ="
                  cat "$conv"
                  echo ";"
                  echo "in orig (if builtins.functionArgs orig == { } then args"
                  echo "         else builtins.intersectAttrs (builtins.functionArgs orig) args)"
                } > "$try"
            fi
        fi
        has_inputs_arg "$try" || fail "$f konnte nicht automatisch umgestellt werden"
    fi
    cat "$try" > "$f"    # Inhalt ersetzen, Besitzer/Rechte bleiben
}

# Channel-Lookups und fetchTarball-URLs in allen .nix-Dateien durch Flake-Inputs ersetzen
convert_channels() {
    local -a files names sedargs=() unknown=() changed=()
    local n m url ref name A f
    mapfile -t files < <(find . -name '*.nix' -not -path './.git/*' -not -name flake.nix -not -name riftlinux.nix | sort)
    ((${#files[@]})) || return 0

    # <name> und <name/pfad>; Kommentarzeilen und "<…>"/'<…>' in Anführungszeichen (Text, kein Import) bleiben
    mapfile -t names < <(sed -E '/^[[:space:]]*#/d; s/[[:space:]]#.*$//' "${files[@]}" \
                         | grep -oE "(^|[^\"'])<[A-Za-z0-9._-]+(/[^<>[:space:]\"]*)?>" \
                         | sed -E 's|^[^<]*<([^/>]+).*|\1|' | sort -u || true)
    for n in "${names[@]}"; do
        if [[ $n == nixpkgs || $n == nixos ]]; then
            LOOKUP[$n]=nixpkgs
        elif [[ -n ${CHANNELS[$n]:-} ]]; then
            INPUTS[$n]=$(to_flakeref "${CHANNELS[$n]}"); LOOKUP[$n]=$n
        elif [[ $n =~ ^[a-z0-9._-]+$ ]]; then
            unknown+=("<$n>")
        fi
    done

    # builtins.fetchTarball mit nackter URL (ohne sha256 in Flakes nicht erlaubt)
    while IFS= read -r m; do
        [[ -n $m ]] || continue
        url=$(grep -oE 'https?://[^"[:space:];)]+' <<<"$m"); ref=$(to_flakeref "$url")
        if [[ $ref =~ ^github:[^/]+/([^/]+)/(.+)$ ]]; then
            name=${BASH_REMATCH[1]}
            [[ $name == nixpkgs ]] && name="nixpkgs-${BASH_REMATCH[2]//[^A-Za-z0-9_-]/-}"
        else
            name=$(basename "$url"); name=${name%%.tar*}; name=${name//[^A-Za-z0-9_-]/-}
        fi
        [[ -n ${INPUTS[$name]:-} && ${INPUTS[$name]} != "$ref" ]] && name="$name-$(sha256sum <<<"$ref" | cut -c1-6)"
        INPUTS[$name]=$ref; FETCH[$m]=$name
    done < <(grep -hv '^[[:space:]]*#' "${files[@]}" \
             | grep -oE '(builtins\.)?fetchTarball[[:space:]]+"?https?://[^"[:space:];)]+"?' | sort -u || true)

    for n in "${!LOOKUP[@]}"; do
        A="inputs.$(nixattr "${LOOKUP[$n]}")"; m=$(reesc "$n")
        sedargs+=(-e "/^[[:space:]]*#/!s#(^|[^\"'])<$m/([^<>[:space:]\"]*)>#\\1\"\${$A}/\\2\"#g"
                  -e "/^[[:space:]]*#/!s#(^|[^\"'])<$m>#\\1\"\${$A}\"#g")
    done
    for m in "${!FETCH[@]}"; do
        A="inputs.$(nixattr "${FETCH[$m]}")"
        sedargs+=(-e "/^[[:space:]]*#/!s#$(reesc "$m")#\"\${$A}\"#g")
    done
    # import <nixpkgs> { … } braucht in Flakes ein explizites system (kein builtins.currentSystem)
    for name in nixpkgs "${!INPUTS[@]}"; do
        [[ $name == nixpkgs || ${INPUTS[$name],,} == github:nixos/nixpkgs/* ]] || continue
        A=$(reesc "\"\${inputs.$(nixattr "$name")}\"")
        sedargs+=(-e "s#import[[:space:]]+\\(?($A)\\)?[[:space:]]*\\{#import \\1 { system = \"x86_64-linux\";#g")
    done

    if ((${#sedargs[@]})); then
        for f in "${files[@]}"; do
            sed -E "${sedargs[@]}" "$f" > "$TMP/conv"
            cmp -s "$f" "$TMP/conv" && continue
            add_inputs_arg "$f" "$TMP/conv"
            changed+=("${f#./}")
        done
    fi
    ((${#changed[@]})) && echo "Auf Flake-Inputs umgestellt: ${changed[*]}"
    ((${#unknown[@]})) && warn "kein Channel für ${unknown[*]} gefunden – falls das Importe sind, bitte von Hand umstellen."
    return 0
}

write_flake() {
    local extra="" mods="" i
    for i in $(printf '%s\n' "${!INPUTS[@]}" | sort); do
        extra+="    $(nixattr "$i") = { url = \"${INPUTS[$i]}\"; flake = false; };"$'\n'
    done
    if printf '%s\n' "${INPUTS[@]}" | grep -q home-manager; then
        mods+="        { home-manager.extraSpecialArgs = { inherit inputs; }; }  # inputs auch in Home-Manager-Modulen"$'\n'
    fi
    cat > flake.nix <<EOF
{
  description = "NixOS-Konfiguration ${HOST}";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/${BRANCH}";
    riftlinux = { url = "${RIFT_URL}"; flake = false; };
${extra}  };

  outputs = { nixpkgs, ... }@inputs: {
    nixosConfigurations."${HOST}" = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        {
          nixpkgs.hostPlatform = "x86_64-linux";
          nix.settings.experimental-features = [ "nix-command" "flakes" ];
        }
${mods}        ./configuration.nix
        ./riftlinux.nix
      ];
    };
  };
}
EOF
    echo "flake.nix angelegt (nixpkgs: ${BRANCH})."
}

# ---------------------------------------------------------------------------------------------------------------
# 1) Modus bestimmen, ggf. Backup
# ---------------------------------------------------------------------------------------------------------------
CONVERT=0
if [[ ! -f flake.nix ]]; then
    CONVERT=1
    BACKUP="${NIXOS_DIR%/}.bak-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP" && cp -a . "$BACKUP/"
    echo "Backup: $BACKUP"
fi

# ---------------------------------------------------------------------------------------------------------------
# 2) NixOS-Modul: paketiert das offizielle Release (SteamVR-Treiber + eigene OpenXR-Runtime) und richtet alles ein
# ---------------------------------------------------------------------------------------------------------------
cat > riftlinux.nix <<'EOF'
# RiftLinux – Oculus-Rift-CV1-Treiber für SteamVR und OpenXR (https://github.com/AIIX/RiftLinux)
# Paketiert das Release-Tarball aus dem Flake-Input "riftlinux". Der SteamVR-Treiber muss laut Upstream
# aus deren Steam-Runtime-Build stammen (läuft in Steams Container), deshalb kein Bau aus den Quellen.
{ lib, pkgs, inputs, ... }:

let
  riftlinux = pkgs.stdenv.mkDerivation {
    pname = "riftlinux";
    version = "0.1.0";
    src = inputs.riftlinux;

    nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper ];
    buildInputs = with pkgs; [
      python3 systemd libusb1 libdrm vulkan-loader SDL2 dbus libglvnd wayland
      (pkgs.libx11 or pkgs.xorg.libX11)
      (pkgs.libxcb or pkgs.xorg.libxcb)
    ];

    # SteamVR-Treiber unverändert lassen (kein strip/patchelf/Shebang-Patch) – nur native/ und bin/ anpassen
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    dontPatchELF = true;
    dontPatchShebangs = true;
    dontAutoPatchelf = true;

    installPhase = ''
      runHook preInstall
      cp -r root/usr $out
      # Paket-Hooks anderer Distros; auf NixOS übernimmt das Modul unten
      rm $out/lib/riftlinux/{after-install,before-remove,users}.sh
      runHook postInstall
    '';

    postFixup = ''
      # eigene OpenXR-Runtime (monado-service) gegen Nix-Bibliotheken linken
      autoPatchelf $out/lib/riftlinux/native

      substituteInPlace $out/bin/riftlinux-{setup,run,runtime} \
        --replace-quiet /usr/lib/riftlinux $out/lib/riftlinux
      substituteInPlace $out/lib/systemd/user/riftlinux-register.service \
        --replace-fail /usr/bin/riftlinux-setup $out/bin/riftlinux-setup

      # Kopie aus dem read-only Nix-Store beschreibbar machen, sonst scheitert die Registrierung
      substituteInPlace $out/bin/riftlinux-setup \
        --replace-fail 'shutil.copytree(system_dir, tmp, symlinks=False)' \
                       'shutil.copytree(system_dir, tmp, symlinks=False); subprocess.run(["chmod", "-R", "u+w", tmp], check=True)' \
        --replace-fail '"/usr/libexec/rtkit-daemon"' '"${pkgs.rtkit}/libexec/rtkit-daemon"'  # rtkit-Erkennung (FHS-Pfade)

      patchShebangs --host $out/bin
      wrapProgram $out/bin/riftlinux-setup \
        --prefix PATH : ${lib.makeBinPath [ pkgs.coreutils pkgs.usbutils pkgs.libcap ]}
    '';
  };
in
{
  environment.systemPackages = [ riftlinux pkgs.usbutils ];

  # Gerätezugriff (uaccess) + Registrierung bei SteamVR, sobald das Headset eingesteckt wird
  services.udev.packages = [ riftlinux ];
  systemd.packages = [ riftlinux ];
  systemd.user.services.riftlinux-register.wantedBy = [ "default.target" ];  # und bei jedem Login

  security.rtkit.enable = true;   # Echtzeit-Priorität für Tracking und Compositor
  hardware.graphics.enable = true;

  programs.steam = {
    enable = true;
    extraPackages = [ pkgs.usbutils ];  # SteamVR erkennt das Headset per lsusb
  };
  nixpkgs.config.allowUnfreePredicate = lib.mkDefault (pkg:
    builtins.elem (lib.getName pkg) [ "steam" "steam-unwrapped" "steam-original" "steam-run" ]);

  # NVIDIA + Wayland + VRR-Monitor: Bild im Headset reißt -> VRR verstecken (Monitore verlieren dann VRR)
  # boot.extraModprobeConfig = "options nvidia-modeset conceal_vrr_caps=1";
}
EOF

# ---------------------------------------------------------------------------------------------------------------
# 3) Auf Flakes umstellen (nur wenn noch keine flake.nix existiert)
# ---------------------------------------------------------------------------------------------------------------
if ((CONVERT)); then
    convert_channels
    write_flake
elif ! grep -q riftlinux flake.nix; then
    cat >&2 <<EOF
Es gibt schon eine flake.nix – riftlinux.nix wurde angelegt, bitte die flake.nix von Hand ergänzen:

  inputs.riftlinux = { url = "${RIFT_URL}"; flake = false; };
  # in nixosSystem:
  specialArgs = { inherit inputs; };
  modules = [ ... ./riftlinux.nix ];

Danach: sudo nixos-rebuild switch --flake ${NIXOS_DIR}#${HOST}
EOF
    exit 1
fi
git_do add -- '*.nix' || warn "git add fehlgeschlagen – ungetrackte Dateien sieht das Flake nicht"

# ---------------------------------------------------------------------------------------------------------------
# 4) Bauen und aktivieren
# ---------------------------------------------------------------------------------------------------------------
OLD_SYSTEM=$(readlink -f /run/current-system || true)
if ! nixos-rebuild switch --flake "${NIXOS_DIR}#${HOST}"; then
    # Nur zurücksetzen, wenn nichts aktiviert wurde (sonst passt /etc/nixos nicht mehr zum laufenden System)
    if ((CONVERT)) && [[ $(readlink -f /run/current-system || true) == "$OLD_SYSTEM" ]]; then
        restore
    fi
    die "nixos-rebuild fehlgeschlagen. Häufige Ursachen bei Flakes: absolute Pfade außerhalb von ${NIXOS_DIR}
       (z. B. import /home/…), in Git ignorierte Dateien oder übrige <…>-Importe."
fi
[[ -f flake.lock ]] && git_do add -- flake.lock
chown --reference=configuration.nix flake.nix riftlinux.nix flake.lock 2>/dev/null || true

# Wie das Original-Paket nach der Installation: udev-Regeln laden und schon eingesteckte Rift-Geräte neu auslösen,
# sonst bekommen sie die Zugriffsrechte (uaccess) erst nach erneutem Einstecken
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=usb --attr-match=idVendor=2833 2>/dev/null || true
udevadm trigger --subsystem-match=hidraw 2>/dev/null || true

# Treiber gleich für den aufrufenden User bei SteamVR registrieren (sonst beim nächsten Login/Einstecken).
# daemon-reload, damit der laufende User-Manager die neue Unit kennt.
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    if ! { systemctl --user --machine="${SUDO_USER}@.host" daemon-reload &&
           systemctl --user --machine="${SUDO_USER}@.host" start riftlinux-register.service; } 2>/dev/null; then
        runuser -u "$SUDO_USER" -- /run/current-system/sw/bin/riftlinux-setup register --quiet || true
    fi
fi

# NVIDIA mit VRR-Monitor: Bild im Headset reißt unter Wayland (riftlinux-setup nvidia-vrr conceal geht auf NixOS nicht)
if [[ -e /proc/driver/nvidia/version ]] &&
   /run/current-system/sw/bin/riftlinux-setup nvidia-vrr status 2>/dev/null | grep -q "offer(s) adaptive sync"; then
    echo
    echo "Hinweis: Ein Monitor bietet VRR an. Unter Wayland reißt das Bild im Headset (NVIDIA-Fehler)."
    echo "         Abhilfe (Monitore verlieren VRR): in ${NIXOS_DIR}/riftlinux.nix die Zeile"
    echo "         boot.extraModprobeConfig = … einkommentieren, neu bauen und neu starten."
fi

echo
echo "Fertig. Steam einmal als dein Benutzer starten und SteamVR installieren (Bibliothek → Tools),"
echo "dann Rift anstecken (HDMI + USB, Sensoren an USB) und SteamVR starten."
echo "Prüfen:     riftlinux-setup check   (als normaler Benutzer in der Desktop-Sitzung, ohne sudo)"
echo "Update:     in flake.nix die Version in der riftlinux-URL ändern, dann"
echo "            sudo nixos-rebuild switch --flake ${NIXOS_DIR}#${HOST}"
if ((CONVERT)); then
    echo "Backup:     ${BACKUP}"
    ((${#CHANNELS[@]})) && echo "Channels:   werden nicht mehr gebraucht – nach einem Test entfernen mit sudo nix-channel --remove <name>"
fi
exit 0
