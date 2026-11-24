#!/usr/bin/env bash
# install-hp-plugin.sh — install HP's proprietary HPLIP plugin when `hp-plugin` fails with
#   "error: Unable to load pkit...is HPLIP installed?"
#   "error: Python gobject/dbus may be not installed"
# (seen on Linux Mint 22 / Ubuntu 24.04 with distro-packaged HPLIP).
#
# What it does:
#   1. Reads your installed HPLIP version.
#   2. Looks up the matching plugin in HP's index (hplip.sourceforge.net/plugin.conf).
#   3. Downloads it from HP's mirror (openprinting.org) and verifies the checksum from that index.
#   4. Unpacks it WITHOUT running HP's self-extracting installer.
#   5. Shows HP's license and asks you to accept it.
#   6. Installs the files with HPLIP's own copy routine (installer/pluginhandler.py: copyFiles),
#      i.e. the same code hp-plugin runs — minus the broken PolicyKit step.
#
# Usage:
#   sudo ./install-hp-plugin.sh                 # interactive
#   sudo ./install-hp-plugin.sh --yes           # accept HP's license non-interactively
#   ./install-hp-plugin.sh --dry-run            # download + verify + unpack only (no root needed)
#   sudo ./install-hp-plugin.sh --version 3.23.12   # force a plugin version (must match HPLIP)
set -euo pipefail

INDEX_URL="https://hplip.sourceforge.net/plugin.conf"
HPLIP_HOME="/usr/share/hplip"
STATE_FILE="/var/lib/hp/hplip.state"
ACCEPT=0; DRY_RUN=0; VERSION=""; KEEP=0

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ACCEPT=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -k|--keep) KEEP=1 ;;
    -v|--version) VERSION="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

for cmd in curl tar python3 sha1sum sha256sum; do
  command -v "$cmd" >/dev/null || die "missing required command: $cmd"
done
[ -f /etc/hp/hplip.conf ] && [ -d "$HPLIP_HOME" ] || die "HPLIP not found (install the 'hplip' package first)"
[ "$DRY_RUN" = 1 ] || [ "$(id -u)" = 0 ] || die "run with sudo (or use --dry-run)"

# 1. Installed HPLIP version
if [ -z "$VERSION" ]; then
  VERSION=$(awk -F= '/^\[hplip\]/{s=1;next} /^\[/{s=0} s&&$1~/^version/{gsub(/[ \t]/,"",$2); print $2; exit}' /etc/hp/hplip.conf)
  [ -n "$VERSION" ] || die "could not read HPLIP version from /etc/hp/hplip.conf"
fi
info "HPLIP version: $VERSION"

WORK=$(mktemp -d -t hp-plugin.XXXXXX)
cleanup() { [ "$KEEP" = 1 ] && echo "Kept work dir: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

# 2. Look up plugin URL + checksum in HP's index
info "Fetching HP plugin index"
curl -fsSL "$INDEX_URL" | tr -d '\r' > "$WORK/plugin.conf" || die "could not download $INDEX_URL"
read -r URL SUM < <(awk -v sec="[$VERSION]" '
  $0==sec {s=1; next} /^\[/ {s=0}
  s && $1=="url" {u=$3} s && $1=="checksum" {c=$3}
  END {print u, c}' "$WORK/plugin.conf")
[ -n "${URL:-}" ] && [ -n "${SUM:-}" ] || die "no plugin listed for HPLIP $VERSION in $INDEX_URL"
URL="${URL/#http:/https:}"

# 3. Download + verify
RUN="$WORK/$(basename "$URL")"
info "Downloading $URL"
curl -fL --progress-bar "$URL" -o "$RUN" || die "download failed"
case ${#SUM} in
  40) GOT=$(sha1sum "$RUN" | cut -d' ' -f1) ;;
  64) GOT=$(sha256sum "$RUN" | cut -d' ' -f1) ;;
  *)  die "unexpected checksum format in index: $SUM" ;;
esac
[ "$GOT" = "$SUM" ] || die "checksum mismatch (expected $SUM, got $GOT)"
info "Checksum OK ($SUM)"

# 4. Unpack the makeself archive without executing it
HEADER_LINES=$(grep -a -m1 -oE 'head -n [0-9]+ "\$0"' "$RUN" | awk '{print $3}') \
  || die "could not find archive offset in $RUN"
SRC="$WORK/plugin"; mkdir -p "$SRC"
tail -n +"$((HEADER_LINES + 1))" "$RUN" | tar -xz -C "$SRC" || die "could not unpack plugin archive"
[ -f "$SRC/plugin.spec" ] || die "plugin.spec missing from archive"
info "Unpacked $(ls "$SRC" | wc -l) files"

if [ "$DRY_RUN" = 1 ]; then
  KEEP=1; info "Dry run: stopping before install."; exit 0
fi

# 5. HP license
if [ "$ACCEPT" != 1 ]; then
  LIC="$SRC/license.txt"
  if [ -f "$LIC" ]; then ${PAGER:-less} "$LIC" </dev/tty || cat "$LIC"; fi
  read -r -p "Do you accept HP's license agreement? [y/N] " ans </dev/tty
  [[ "$ans" =~ ^[Yy] ]] || die "license not accepted"
fi

# 6. Install with HPLIP's own copy routine.
#    copyFiles() resolves source files relative to the CURRENT directory — so run it from $SRC.
info "Installing plugin files"
cd "$SRC"
python3 - "$SRC" "$HPLIP_HOME" <<'EOF'
import sys
src, home = sys.argv[1], sys.argv[2]
sys.path.insert(0, home)
from installer import pluginhandler
pluginhandler.PluginHandle().copyFiles(src)
EOF
cd /

# Verify: copyFiles skips missing sources silently and still marks the plugin installed,
# so check that files actually landed.
n=$(find "$HPLIP_HOME/prnt/plugins" -name '*.so' 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || die "no driver files in $HPLIP_HOME/prnt/plugins — install failed"
grep -q "installed *= *1" "$STATE_FILE" 2>/dev/null || die "$STATE_FILE not updated"
info "Installed $n driver libraries:"
ls -1 "$HPLIP_HOME/prnt/plugins"
echo "--- $STATE_FILE"; cat "$STATE_FILE"

udevadm control --reload-rules 2>/dev/null || true
systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || true

cat <<'EOF'

Done. Power-cycle the printer, then print a test page:
  lp /usr/share/cups/data/testprint
If the printer isn't set up yet:  hp-setup -i
EOF
