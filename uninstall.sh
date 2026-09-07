#!/bin/bash
# Remove awake-mode and put the machine's power settings back the way macOS
# ships them. Safe to run twice.
#   uninstall.sh              remove everything, including the settings and log
#   uninstall.sh --keep-state keep the settings, the log and the selected mode
set -uo pipefail

USER_ID=$(id -u)
BIN_DIR="$HOME/.local/bin"
APP="$HOME/Applications/AwakeMode.app"
AGENTS_DIR="$HOME/Library/LaunchAgents"
STATE_DIR="$HOME/Library/Application Support/awake-mode"
LOG_DIR="$HOME/Library/Logs"
SUDOERS_FILE="/etc/sudoers.d/awake-mode"
DAEMON_LABEL="io.github.sson-s2.awake-mode"
MENU_LABEL="io.github.sson-s2.awake-mode.menu"

KEEP_STATE=no
[ "${1:-}" = --keep-state ] && KEEP_STATE=yes

echo "== 1. stop both launch agents =="
for label in "$DAEMON_LABEL" "$MENU_LABEL"; do
  launchctl bootout "gui/$USER_ID/$label" 2>/dev/null
  for _ in $(seq 1 20); do
    launchctl print "gui/$USER_ID/$label" >/dev/null 2>&1 || break
    sleep 0.5
  done
  echo "   $label"
done
pkill -f "$APP/Contents/MacOS/AwakeMode" 2>/dev/null
# The watchdog starts caffeinate with -w on its own pid, so its child is gone
# with it; anything left here belongs to someone else and is not ours to kill.

echo "== 2. put the power settings back =="
# Before the sudo rule goes away, while it can still be done without a password.
if sudo -n /usr/bin/pmset disablesleep 0 >/dev/null 2>&1; then
  echo "   SleepDisabled=0"
else
  echo "   note: could not reset SleepDisabled without a password; run"
  echo "         sudo pmset disablesleep 0"
fi
if sudo -n /usr/bin/pmset -b lowpowermode 0 >/dev/null 2>&1; then
  echo "   Low Power Mode off for the battery profile"
else
  echo "   note: could not reset Low Power Mode; run"
  echo "         sudo pmset -b lowpowermode 0"
fi

echo "== 3. remove the installed files =="
rm -f "$AGENTS_DIR/$DAEMON_LABEL.plist" "$AGENTS_DIR/$MENU_LABEL.plist"
rm -f "$BIN_DIR/awake-mode-daemon" "$BIN_DIR/awake-mode"
rm -rf "$APP"
echo "   launch agents, $BIN_DIR/awake-mode*, $APP"

echo "== 4. remove the sudo rule =="
if [ -e "$SUDOERS_FILE" ]; then
  echo "   macOS will ask for your login password once, to remove $SUDOERS_FILE"
  sudo rm -f "$SUDOERS_FILE" && echo "   removed" || echo "   could not remove $SUDOERS_FILE"
else
  echo "   already gone"
fi

echo "== 5. settings, mode and log =="
if [ "$KEEP_STATE" = yes ]; then
  echo "   kept: $STATE_DIR and $LOG_DIR/awake-mode*.log"
else
  rm -rf "$STATE_DIR"
  rm -f "$LOG_DIR/awake-mode.log" "$LOG_DIR/awake-mode.out.log" "$LOG_DIR/awake-mode.err.log"
  echo "   removed: $STATE_DIR and $LOG_DIR/awake-mode*.log"
fi

# pmset omits the SleepDisabled line entirely when it is off, so no line means 0.
sleep_disabled() {
  local v
  v=$(/usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '/SleepDisabled/{print $2; exit}')
  case "$v" in 1|true) echo 1 ;; *) echo 0 ;; esac
}

echo
echo "== done =="
echo "SleepDisabled : $(sleep_disabled)   (0 = macOS decides again)"
