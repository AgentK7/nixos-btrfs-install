#!/usr/bin/env bash
# Baut configuration.nix für Test-Szenarien und wertet sie gegen NixOS aus, ohne etwas zu installieren.
# Findet Fehler wie entfernte oder umbenannte Optionen, bevor sie bei einer Installation auffallen.
#
#   tests/eval.sh release              alle Szenarien gegen das neueste stabile Release
#   tests/eval.sh unstable server      nur tests/szenarien/server.env gegen nixos-unstable
#
# Szenarien sind Bash-Dateien mit Variablen wie nach den Abfragen (Ja/Nein als 1/0), siehe basis.env.
# shellcheck disable=SC2034  # viele Variablen liest erst build_config aus install.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
kanal=${1:?"Kanal angeben: release, unstable oder nixos-XX.YY"}; shift
JOBS=${JOBS:-3}

# shellcheck source=../install.sh
INSTALLER_LIB=1 source ./install.sh
set +eE; trap - ERR

case $kanal in
  release)  rel=$(detect_latest_release); [[ -n $rel ]] || { echo "Aktuelles Release nicht ermittelbar." >&2; exit 1; }; kanal=nixos-$rel ;;
  unstable) kanal=nixos-unstable ;;
esac
# Quellen lassen sich überschreiben, z. B. mit lokalen Checkouts: NIXPKGS=… HM=… NH=… tests/eval.sh …
export NIX_PATH="nixpkgs=${NIXPKGS:-channel:$kanal}"
STATE=$(nix-instantiate --eval -E '(import <nixpkgs/lib>).trivial.release' 2>/dev/null | tr -d '"')
[[ -n $STATE ]] || { echo "Kanal $kanal nicht ladbar." >&2; exit 1; }
hm=master
if [[ $kanal != nixos-unstable ]] && git ls-remote --exit-code --heads https://github.com/nix-community/home-manager "release-$STATE" >/dev/null 2>&1; then
  hm=release-$STATE
fi
NIX_PATH+=":home-manager=${HM:-https://github.com/nix-community/home-manager/archive/$hm.tar.gz}"
NIX_PATH+=":nixos-hardware=${NH:-https://github.com/NixOS/nixos-hardware/archive/master.tar.gz}"
echo "Kanal: $kanal, home-manager: $hm"

# Avahi-Optionen heißen je nach Version anders (wie im Installer geprüft)
if [[ $(nix-instantiate --eval -E '(import <nixpkgs/nixos> { configuration = {}; }).options.services.avahi ? settings' 2>/dev/null) == true ]]; then
  AVAHI=1
else
  AVAHI=0
fi

OUT=${OUT:-$(mktemp -d)}
files=()
if (( $# )); then
  for n in "$@"; do files+=("tests/szenarien/$n.env"); done
else
  for f in tests/szenarien/*.env; do [[ $f == */basis.env ]] || files+=("$f"); done
fi

pruefe() {
  local f=$1 name d
  name=$(basename "$f" .env); d=$OUT/$name
  mkdir -p "$d"
  if ! (
    set -u
    # shellcheck source=/dev/null
    source tests/szenarien/basis.env
    STATE_VERSION=$STATE AVAHI_SETTINGS=$AVAHI
    # shellcheck source=/dev/null
    source "$f"
    case $KERNEL in latest) KERNEL_ATTR=linuxPackages_latest ;; lts) KERNEL_ATTR=linuxPackages ;; *) KERNEL_ATTR=linuxPackages_$KERNEL ;; esac
    build_config "$d/configuration.nix"
    write_mock_hw > "$d/hardware-configuration.nix"
  ) > "$d/bau.txt" 2>&1; then
    echo "FEHLER $name: configuration.nix nicht erzeugt"; sed 's/^/  /' "$d/bau.txt"; return 1
  fi
  if nix-instantiate '<nixpkgs/nixos>' -A system -I "nixos-config=$d/configuration.nix" > "$d/ergebnis.txt" 2>&1; then
    echo "OK     $name"
    grep -i 'evaluation warning\|^trace: warning' "$d/ergebnis.txt" | sort -u | while read -r w; do
      echo "  Warnung: $w"
      if [[ -n ${GITHUB_ACTIONS-} ]]; then echo "::warning title=$name ($kanal)::$w"; fi
    done
    return 0
  else
    echo "FEHLER $name ($d/configuration.nix):"
    grep -v '^\s*$' "$d/ergebnis.txt" | grep -B2 -A8 'error:' | head -40 | sed 's/^/  /'
    if [[ -n ${GITHUB_ACTIONS-} ]]; then echo "::error title=$name ($kanal)::$(grep -m1 -A3 'error:' "$d/ergebnis.txt" | tr '\n' ' ')"; fi
    return 1
  fi
}

fehler=0
for f in "${files[@]}"; do
  [[ -r $f ]] || { echo "Szenario fehlt: $f"; fehler=1; continue; }
  while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n || true; done
  { pruefe "$f" || touch "$OUT/$(basename "$f" .env).fehler"; } &
done
wait
if compgen -G "$OUT/*.fehler" >/dev/null; then fehler=1; fi
if (( fehler )); then echo "Mindestens ein Szenario ist fehlgeschlagen (Dateien unter $OUT)."; exit 1; fi
echo "Alle Szenarien in Ordnung ($kanal)."
