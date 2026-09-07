#!/bin/bash
# Install awake-mode. Safe to run again: it converges on the same state and
# stops at the first step it cannot complete.
set -uo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_ID=$(id -u)
USER_NAME=$(id -un)
BIN_DIR="$HOME/.local/bin"
APP="$HOME/Applications/AwakeMode.app"
AGENTS_DIR="$HOME/Library/LaunchAgents"
STATE_DIR="$HOME/Library/Application Support/awake-mode"
STATUS_FILE="$STATE_DIR/status.json"
MODE_FILE="$STATE_DIR/mode"
LOG_DIR="$HOME/Library/Logs"
SUDOERS_FILE="/etc/sudoers.d/awake-mode"   # no dot in the name: sudo skips those
DAEMON_LABEL="io.github.sson-s2.awake-mode"
MENU_LABEL="io.github.sson-s2.awake-mode.menu"

die() { echo "stopped: $*" >&2; exit 1; }

# powerd's own value. The preferences plist lags a pmset call by seconds, so it
# is useless for confirming anything.
sleep_disabled() {
  local v
  v=$(/usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '/SleepDisabled/{print $2; exit}')
  case "$v" in 1|true) echo 1 ;; *) echo 0 ;; esac
}
status_field() { sed -n 's/.*"'"$1"'":"\{0,1\}\([^,"}]*\)"\{0,1\}.*/\1/p' "$STATUS_FILE" 2>/dev/null | head -1; }

echo "== 1. requirements =="
[ "$(uname -s)" = Darwin ] || die "macOS only"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "${major:-0}" -ge 13 ] || die "macOS 13 or newer is required (found $(sw_vers -productVersion))"
[ "$USER_ID" != 0 ] || die "run this as your normal user, not with sudo"
xcrun -f swiftc >/dev/null 2>&1 ||
  die "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install"
echo "   macOS $(sw_vers -productVersion), swiftc present"

echo "== 2. password-free access to two pmset settings =="
# The lid can only be kept awake by pmset disablesleep, and that is root-only.
# Nothing else is granted: four exact command lines, no wildcards.
# Probe with the value the selected mode already wants, so re-running this on a
# machine that is holding its lid awake does not drop that for a moment.
# The readability test comes first: the shell prints its own redirection error
# for a missing file, and no 2>/dev/null on the command can suppress that.
current_mode=""
[ -r "$MODE_FILE" ] && current_mode=$(tr -d ' \t\r\n' <"$MODE_FILE")
case "$current_mode" in lid) probe=1 ;; *) probe=0 ;; esac
sudo -k
if sudo -n /usr/bin/pmset disablesleep "$probe" >/dev/null 2>&1; then
  echo "   already granted ($SUDOERS_FILE)"
else
  draft=$(mktemp -t awake-mode.sudoers) || die "could not create a temporary file"
  cat >"$draft" <<EOF
# Installed by awake-mode. Remove with uninstall.sh.
# Lets the awake-mode watchdog toggle exactly these settings without a password.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1, /usr/bin/pmset -b lowpowermode 0, /usr/bin/pmset -b lowpowermode 1
EOF
  /usr/sbin/visudo -cf "$draft" >/dev/null ||
    { rm -f "$draft"; die "the generated sudoers file did not validate"; }
  echo "   macOS will ask for your login password once, to write $SUDOERS_FILE"
  sudo install -m 0440 -o root -g wheel "$draft" "$SUDOERS_FILE" ||
    { rm -f "$draft"; die "could not write $SUDOERS_FILE"; }
  rm -f "$draft"
  # Drop the credential just cached, so this really tests the new rule.
  sudo -k
  sudo -n /usr/bin/pmset disablesleep "$probe" >/dev/null 2>&1 ||
    die "$SUDOERS_FILE was written but sudo still refuses pmset"
  echo "   granted and verified"
fi

echo "== 3. install the watchdog and the CLI =="
mkdir -p "$BIN_DIR" "$HOME/Applications" "$AGENTS_DIR" "$STATE_DIR" "$LOG_DIR" ||
  die "could not create the install directories"
install -m 0755 "$SOURCE_DIR/bin/awake-mode-daemon" "$BIN_DIR/awake-mode-daemon" || die "could not install the watchdog"
install -m 0755 "$SOURCE_DIR/bin/awake-mode" "$BIN_DIR/awake-mode" || die "could not install the CLI"
echo "   $BIN_DIR/awake-mode-daemon"
echo "   $BIN_DIR/awake-mode"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "   note: $BIN_DIR is not on your PATH. Add this line to ~/.zshrc:"
     echo "         export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo "== 4. settings file =="
if [ -s "$STATE_DIR/config" ]; then
  echo "   kept: $STATE_DIR/config"
else
  cat >"$STATE_DIR/config" <<'EOF'
# awake-mode settings. Edited values take effect within one interval.

# Below this percentage on battery, everything that keeps the machine up is
# released so it sleeps on your normal macOS settings. The mode is kept.
BATTERY_SLEEP_PERCENT=10

# Charged back to this percentage (or plugged in), the mode resumes.
BATTERY_RESUME_PERCENT=15

# 1 = while lid or lock runs on battery, turn on macOS Low Power Mode for the
# battery profile and turn it off again otherwise. awake-mode owns that setting
# while this is 1; set it to 0 to manage Low Power Mode yourself.
LOW_POWER_ON_BATTERY=1

# How often the watchdog compares the wish with the machine, in seconds.
INTERVAL_SEC=10
EOF
  echo "   wrote defaults: $STATE_DIR/config"
fi

echo "== 5. starting mode =="
if [ -s "$MODE_FILE" ]; then
  echo "   kept: $(cat "$MODE_FILE")"
else
  # normal, so installing this never changes how a machine sleeps by surprise.
  echo normal >"$MODE_FILE"
  echo "   normal"
fi

echo "== 6. build the menu bar app =="
bash "$SOURCE_DIR/menu/build.sh" "$APP" >/dev/null || die "the menu bar app did not build"
echo "   $APP"

echo "== 7. register both launch agents =="
cat >"$AGENTS_DIR/$DAEMON_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$DAEMON_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$BIN_DIR/awake-mode-daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG_DIR/awake-mode.out.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/awake-mode.err.log</string>
</dict>
</plist>
EOF
cat >"$AGENTS_DIR/$MENU_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$MENU_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/AwakeMode</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
plutil -lint "$AGENTS_DIR/$DAEMON_LABEL.plist" >/dev/null || die "the watchdog plist is malformed"
plutil -lint "$AGENTS_DIR/$MENU_LABEL.plist" >/dev/null || die "the menu plist is malformed"

for label in "$DAEMON_LABEL" "$MENU_LABEL"; do
  launchctl bootout "gui/$USER_ID/$label" 2>/dev/null
  # bootout is asynchronous; bootstrapping the same label before it finishes
  # fails, which would leave no watchdog running at all.
  for _ in $(seq 1 20); do
    launchctl print "gui/$USER_ID/$label" >/dev/null 2>&1 || break
    sleep 0.5
  done
  booted=no
  for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$USER_ID" "$AGENTS_DIR/$label.plist" 2>/dev/null; then booted=yes; break; fi
    echo "   bootstrap $label failed (attempt $attempt), retrying in 2s"
    sleep 2
  done
  if [ "$booted" != yes ]; then
    # Leaving without a watchdog would leave the machine in whatever state the
    # last one died in, so put the selected mode's value in by hand first.
    want=0; [ "$(cat "$MODE_FILE" 2>/dev/null)" = lid ] && want=1
    sudo -n /usr/bin/pmset disablesleep "$want" >/dev/null 2>&1 &&
      echo "   fallback: set SleepDisabled=$want directly (no watchdog running)"
    die "could not bootstrap $label. Inspect it with: launchctl print gui/$USER_ID/$label"
  fi
  echo "   $label"
done

wanted_mode=$(cat "$MODE_FILE")
echo "== 8. confirm '$wanted_mode' is in effect (up to 40s) =="
confirmed=no
for _ in $(seq 1 20); do
  sleep 2
  if [ "$(status_field ok)" = true ] && [ "$(status_field mode)" = "$wanted_mode" ]; then confirmed=yes; break; fi
done
[ "$confirmed" = yes ] ||
  die "'$wanted_mode' is still not in effect: $(cat "$STATUS_FILE" 2>/dev/null || echo 'no status file')"

echo
echo "== done =="
echo "mode          : $wanted_mode"
echo "SleepDisabled : $(sleep_disabled)"
echo "menu bar      : the icon appears within a few seconds; pick a mode there"
echo "from a shell  : awake-mode lid | lock | normal | status"
echo "settings      : $STATE_DIR/config"
echo "log           : $LOG_DIR/awake-mode.log"
