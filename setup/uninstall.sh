#!/bin/bash
# Removes what install.sh created and nothing else: the PipeWire config is
# deleted only if it is still the exact file we installed (recorded checksum),
# a backed-up original is restored if there was one, then audio is restarted.
#
# Exit codes: 0 done, 4 consent not given, 5 target changed since install (kept), 6 failed
set -uo pipefail

here=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd)
ID=io.github.zeeshan-origin.all-outputs
DEST=${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/10-all-outputs.conf
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/$ID
MANIFEST=$STATE/manifest
BACKUP=$STATE/backup

consent=0
[[ ${1:-} == "--yes" ]] && consent=1
if (( ! consent )); then
  [[ -t 0 ]] || { echo "all-outputs uninstall: no consent given (pass --yes)" >&2; exit 4; }
  read -r -p "Remove $DEST and restart audio? [y/N] " answer
  [[ $answer == [yY] ]] || exit 4
fi

sha() { /usr/bin/sha256sum "$1" 2>/dev/null | /usr/bin/cut -d' ' -f1; }
recorded=$([[ -f $MANIFEST ]] && /usr/bin/awk -F'\t' -v p="$DEST" '$1=="file" && $2==p {print $3; exit}' "$MANIFEST")

# Leave broadcast mode first so the default does not point at a sink about to vanish.
"$here/../bin/all-outputs" off >/dev/null 2>&1 || true

if [[ -L $DEST ]]; then
  echo "all-outputs uninstall: $DEST is a symlink; not touching it" >&2; exit 5
elif [[ ! -e $DEST ]]; then
  echo "$DEST already absent"
elif [[ -z $recorded ]]; then
  echo "all-outputs uninstall: $DEST was not installed by this plugin; leaving it" >&2; exit 5
elif [[ $(sha "$DEST") != "$recorded" ]]; then
  echo "all-outputs uninstall: $DEST was modified after install; leaving it" >&2; exit 5
else
  /usr/bin/rm -f "$DEST" || exit 6
  latest=$(/usr/bin/ls -1t "$BACKUP"/10-all-outputs.conf.* 2>/dev/null | /usr/bin/head -1)
  if [[ -n $latest ]]; then
    /usr/bin/cp -p "$latest" "$DEST" && echo "Restored your previous $DEST"
  fi
  echo "Removed $DEST"
fi

/usr/bin/rm -rf "$STATE"
/usr/bin/timeout --kill-after=5 60 /usr/bin/omarchy-restart-audio >/dev/null 2>&1 || true
echo "Done. Remove the plugin itself with: omarchy plugin remove $ID"
