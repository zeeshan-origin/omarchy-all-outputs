#!/bin/bash
# Removes what install.sh created and nothing else: the PipeWire config is
# deleted only if it is still the exact file we installed (recorded checksum),
# your backed-up original is put back if there was one, then audio is restarted.
#
# The state directory holds the manifest and that backup, so it is dropped only
# once nothing in it is needed any more: either there was no backup, or the
# backup has been put back at the target. Every path that refuses to remove the
# target keeps the whole state directory and prints where the backup is.
#
# Exit codes: 0 done, 4 consent not given, 5 target kept (state kept too), 6 failed
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
# Last record for the path wins, same rule as install.sh, so a manifest left by
# an older version with more than one line for this path still matches.
recorded=$([[ -f $MANIFEST ]] && /usr/bin/awk -F'\t' -v p="$DEST" '$1=="file" && $2==p {s=$3} END {if (s) print s}' "$MANIFEST")
# Newest backup is the file that was at the target when we last replaced it.
backup=$(/usr/bin/ls -1t "$BACKUP"/10-all-outputs.conf.* 2>/dev/null | /usr/bin/head -1)

# Keep the target: leave the manifest and the backup alone as well, they are the
# only way back to your original file.
keep() {
  echo "all-outputs uninstall: $*" >&2
  [[ -n $backup ]] && echo "Your original $DEST is still backed up at $backup" >&2
  exit 5
}

# Leave broadcast mode first so the default does not point at a sink about to vanish.
"$here/../bin/all-outputs" off >/dev/null 2>&1 || true

if [[ -L $DEST ]]; then
  keep "$DEST is a symlink; not touching it"
elif [[ -e $DEST && -z $recorded ]]; then
  keep "$DEST was not installed by this plugin; leaving it"
elif [[ -e $DEST && $(sha "$DEST") != "$recorded" ]]; then
  keep "$DEST was modified after install; leaving it"
fi

if [[ -e $DEST ]]; then
  /usr/bin/rm -f "$DEST" || exit 6
  echo "Removed $DEST"
else
  echo "$DEST already absent"
fi

# Put your original back before the state that holds it goes away. If the copy
# fails the backup stays where it is, so it is never the last copy lost.
if [[ -n $backup ]]; then
  /usr/bin/cp -p "$backup" "$DEST" || keep "could not restore $backup to $DEST"
  echo "Restored your previous $DEST"
fi

/usr/bin/rm -rf "$STATE"
/usr/bin/timeout --kill-after=5 60 /usr/bin/omarchy-restart-audio >/dev/null 2>&1 || true
echo "Done. Remove the plugin itself with: omarchy plugin remove $ID"
