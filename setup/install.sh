#!/bin/bash
# Copies the PipeWire config for the All Outputs sink into the user's config
# and restarts audio so it loads. That is the only file written outside the
# plugin folder.
#
# Runs only with consent: the panel's Set up button passes --yes, a terminal
# run asks y/N. If a different file is already at the target it is left alone
# unless you pass --replace-existing, which backs it up first. What gets
# installed is recorded so uninstall.sh only removes that.
#
# Exit codes:
#   0  installed (or already current with --check)
#   1  --check only: not installed or out of date
#   4  consent not given
#   5  a different file already exists at the target, see --replace-existing
#   6  failed, nothing left half written
set -uo pipefail

here=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd)
ID=io.github.zeeshan-origin.all-outputs
SRC=$here/../pipewire/10-all-outputs.conf
DEST_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d
DEST=$DEST_DIR/10-all-outputs.conf
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/$ID
MANIFEST=$STATE/manifest
BACKUP=$STATE/backup

consent=0 check_only=0 replace=0
for arg in "$@"; do
  case "$arg" in
    --yes) consent=1 ;;
    --check) check_only=1 ;;
    --replace-existing) replace=1 ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "all-outputs setup: unknown option $arg" >&2; exit 6 ;;
  esac
done

fail() { echo "all-outputs setup: $*" >&2; exit 6; }
sha() { /usr/bin/sha256sum "$1" 2>/dev/null | /usr/bin/cut -d' ' -f1; }
# Last record for the path wins, so an older line can never shadow a newer one.
recorded_sha() { [[ -f $MANIFEST ]] && /usr/bin/awk -F'\t' -v p="$DEST" '$1=="file" && $2==p {s=$3} END {if (s) print s}' "$MANIFEST"; }

# Refuse to look through a symlink anywhere on the path we write to.
refuse_symlink() { [[ -L $1 ]] && fail "refusing to operate through symlink $1"; return 0; }

is_current() { [[ -f $DEST && ! -L $DEST && $(sha "$DEST") == $(sha "$SRC") ]]; }

if (( check_only )); then
  is_current && { echo "installed and current"; exit 0; }
  echo "not installed or out of date"; exit 1
fi

is_current && { echo "already installed and current"; exit 0; }

if [[ -e $DEST ]]; then
  refuse_symlink "$DEST"
  if [[ -n $(recorded_sha) && $(recorded_sha) == $(sha "$DEST") ]]; then
    : # ours from an earlier version; safe to update
  elif (( ! replace )); then
    echo "all-outputs setup: $DEST already exists and is not ours." >&2
    echo "Re-run with --replace-existing to back it up and replace it." >&2
    exit 5
  fi
fi

if (( ! consent )); then
  [[ -t 0 ]] || { echo "all-outputs setup: no consent given (pass --yes)" >&2; exit 4; }
  echo "This installs $DEST and restarts audio (playback pauses for a moment)."
  read -r -p "Continue? [y/N] " answer
  [[ $answer == [yY] ]] || exit 4
fi

refuse_symlink "$DEST_DIR"; refuse_symlink "$STATE"
/usr/bin/mkdir -p "$DEST_DIR" "$STATE" || fail "cannot create $DEST_DIR or $STATE"

# Only a file that was not ours gets backed up. Our own earlier version is
# just replaced, otherwise uninstall would "restore" it later.
if [[ -e $DEST ]] && (( replace )) && [[ $(recorded_sha) != $(sha "$DEST") ]]; then
  /usr/bin/mkdir -p "$BACKUP" && /usr/bin/cp -p "$DEST" "$BACKUP/10-all-outputs.conf.$(/usr/bin/date +%s)" || fail "backup failed"
fi

tmp=$(/usr/bin/mktemp "$DEST_DIR/.10-all-outputs.XXXXXX") || fail "mktemp failed"
/usr/bin/cp "$SRC" "$tmp" && /usr/bin/chmod 0644 "$tmp" && /usr/bin/mv -f "$tmp" "$DEST" || { /usr/bin/rm -f "$tmp"; fail "write failed"; }

# Drop any earlier record for this path by field, then add the current one.
{ [[ -f $MANIFEST ]] && /usr/bin/awk -F'\t' -v p="$DEST" '!($1=="file" && $2==p)' "$MANIFEST"; printf 'file\t%s\t%s\n' "$DEST" "$(sha "$DEST")"; } > "$MANIFEST.new" \
  && /usr/bin/mv -f "$MANIFEST.new" "$MANIFEST" || fail "cannot record install"

echo "Installed $DEST"
echo "Restarting audio so the sink loads..."
/usr/bin/timeout --kill-after=5 60 /usr/bin/omarchy-restart-audio >/dev/null 2>&1 || echo "all-outputs setup: audio restart did not finish cleanly; run 'omarchy restart audio'" >&2

# Wait for the sink, then make it the default so setup ends in a working state.
for _ in $(/usr/bin/seq 1 20); do
  /usr/bin/timeout 2 /usr/bin/pactl list short sinks 2>/dev/null | /usr/bin/grep -q combine_all_outputs && break
  /usr/bin/sleep 0.5
done
"$here/../bin/all-outputs" on >/dev/null 2>&1 || true
echo "Done."
