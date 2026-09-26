#!/bin/bash
# Runs install.sh and uninstall.sh against a throwaway HOME and checks every
# branch that decides whether your files are kept, restored or removed.
#
# Nothing on the real system is touched: XDG_CONFIG_HOME and XDG_STATE_HOME are
# redirected into a temp dir, and the copies under test have the audio commands
# replaced with no-ops so no sink is switched and audio is never restarted.
set -uo pipefail

repo=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(/usr/bin/mktemp -d) || exit 1
trap '/usr/bin/rm -rf "$tmp"' EXIT

mkdir -p "$tmp/plugin/setup" "$tmp/plugin/pipewire"
cp "$repo/pipewire/10-all-outputs.conf" "$tmp/plugin/pipewire/"
for s in install uninstall; do
  sed -e 's|/usr/bin/omarchy-restart-audio|true|' \
      -e 's|"$here/../bin/all-outputs"|true|' \
      -e 's|/usr/bin/pactl|echo combine_all_outputs|' \
      "$repo/setup/$s.sh" > "$tmp/plugin/setup/$s.sh"
  chmod +x "$tmp/plugin/setup/$s.sh"
done

export XDG_CONFIG_HOME=$tmp/config XDG_STATE_HOME=$tmp/state
DEST=$XDG_CONFIG_HOME/pipewire/pipewire.conf.d/10-all-outputs.conf
STATE=$XDG_STATE_HOME/io.github.zeeshan-origin.all-outputs
install() { "$tmp/plugin/setup/install.sh" --yes "$@" >/dev/null 2>&1; }
uninstall() { "$tmp/plugin/setup/uninstall.sh" --yes >/dev/null 2>&1; }
reset() { /usr/bin/rm -rf "$tmp/config" "$tmp/state"; mkdir -p "$(dirname "$DEST")"; }

fails=0
check() { # check <description> <condition...>
  local what=$1; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails + 1)); fi
}
backups() { /usr/bin/ls -1 "$STATE"/backup/10-all-outputs.conf.* 2>/dev/null | wc -l; }
is() { [[ "$($1)" == "$2" ]]; }

echo "# fresh install, then uninstall"
reset
install; check "install wrote the conf" test -f "$DEST"
check "manifest recorded" test -s "$STATE/manifest"
uninstall
check "conf removed" test ! -e "$DEST"
check "state dropped" test ! -d "$STATE"

echo "# foreign conf is refused without --replace-existing"
reset; echo original > "$DEST"
install; check "foreign conf untouched" is "cat $DEST" original
check "no state created" test ! -f "$STATE/manifest"

echo "# --replace-existing backs the original up and uninstall restores it"
reset; echo original > "$DEST"
install --replace-existing
check "conf replaced" test "$(cat "$DEST")" != original
check "one backup kept" is backups 1
uninstall
check "original restored" is "cat $DEST" original
check "state dropped" test ! -d "$STATE"

echo "# a conf modified after install is kept, and so is the backup"
reset; echo original > "$DEST"
install --replace-existing
echo "# my own edit" >> "$DEST"
uninstall; check "uninstall refused" test $? -ne 0
check "modified conf kept" test -f "$DEST"
check "manifest kept" test -s "$STATE/manifest"
check "backup kept" is backups 1
check "backup is the original" grep -qx original "$STATE"/backup/10-all-outputs.conf.*

echo "# a symlinked target is kept, and so is the backup"
reset; echo original > "$DEST"
install --replace-existing
mv "$DEST" "$tmp/elsewhere.conf"; ln -s "$tmp/elsewhere.conf" "$DEST"
uninstall
check "symlink kept" test -L "$DEST"
check "backup kept" is backups 1

echo "# a foreign conf that replaced ours is kept, and so is the backup"
reset; echo original > "$DEST"
install --replace-existing
echo someone-elses > "$DEST"
/usr/bin/rm -f "$STATE/manifest"
uninstall
check "foreign conf kept" is "cat $DEST" someone-elses
check "backup kept" is backups 1

echo "# target deleted by hand: the backup is restored, not discarded"
reset; echo original > "$DEST"
install --replace-existing
/usr/bin/rm -f "$DEST"
uninstall
check "original restored" is "cat $DEST" original
check "state dropped" test ! -d "$STATE"

echo "# a duplicated manifest line from an older version still matches"
reset
install
head -1 "$STATE/manifest" | sed 's/\t[0-9a-f]*$/\tstale/' > "$STATE/m2"
cat "$STATE/manifest" >> "$STATE/m2"; mv "$STATE/m2" "$STATE/manifest"
uninstall
check "conf removed despite stale first line" test ! -e "$DEST"

echo
(( fails == 0 )) && { echo "all checks passed"; exit 0; }
echo "$fails check(s) failed"; exit 1
