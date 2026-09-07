#!/bin/bash
# Run the watchdog's decisions against a fake HOME and fake /usr/bin commands.
# Nothing on the real machine is read or written, so this runs anywhere.
#
# Two values are kept apart, the way the real machine keeps them:
#   $WORK/sd      what the preferences plist returns (plutil reads it; it lags)
#   $WORK/sd_live what powerd returns (pmset -g; immediate)
# Writing a number of seconds into $WORK/lag delays only the plist side.
set -u

BASE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$BASE/.logic-check"
FAKE_HOME="$WORK/home"
STATE="$FAKE_HOME/Library/Application Support/awake-mode"
LOG="$FAKE_HOME/Library/Logs/awake-mode.log"
MODE_FILE="$STATE/mode"
STATUS="$STATE/status.json"
CONFIG="$STATE/config"
BATTERY_FILE="$STATE/test-battery"

rm -rf "$WORK"
mkdir -p "$STATE" "$FAKE_HOME/Library/Logs" "$WORK/stub"

SD="$WORK/sd"; echo false >"$SD"
LIVE="$WORK/sd_live"; echo 0 >"$LIVE"
LPM="$WORK/lpm"; echo 0 >"$LPM"
echo ok >"$WORK/sudo_mode"           # ok | fail
: >"$WORK/sudo_calls"
: >"$WORK/lpm_calls"
: >"$WORK/dsn_calls"
cat >"$WORK/batt" <<'EOF'
Now drawing from 'AC Power'
 -InternalBattery-0 (id=1)	100%; charged; 0:00 remaining present: true
EOF

cat >"$WORK/stub/sudo" <<EOF
#!/bin/bash
[ "\$(cat "$WORK/sudo_mode")" = fail ] && exit 1
what=""; value=""
for a in "\$@"; do
  case "\$a" in
    disablesleep) what=sd ;;
    lowpowermode) what=lpm ;;
    0|1)          value="\$a" ;;
  esac
done
[ -z "\$what" ] && exit 0
if [ "\$what" = lpm ]; then
  echo "\$value" >"$LPM"; echo call >>"$WORK/lpm_calls"; exit 0
fi
echo call >>"$WORK/sudo_calls"
echo "\$value" >"$LIVE"
[ "\$value" = 1 ] && plist=true || plist=false
lag=\$(cat "$WORK/lag" 2>/dev/null || echo 0)
if [ "\$lag" != 0 ]; then ( sleep "\$lag"; echo "\$plist" >"$SD" ) & else echo "\$plist" >"$SD"; fi
exit 0
EOF

cat >"$WORK/stub/plutil" <<EOF
#!/bin/bash
cat "$SD"
EOF

# pmset -g omits SleepDisabled when it is 0, exactly like the real one.
cat >"$WORK/stub/pmset" <<EOF
#!/bin/bash
case "\$*" in
  *displaysleepnow*) echo dsn >>"$WORK/dsn_calls" ;;
  *"-g custom"*)
    printf 'Battery Power:\n lowpowermode         %s\n displaysleep         5\nAC Power:\n lowpowermode         0\n displaysleep         0\n' "\$(cat "$LPM")" ;;
  *assertions*) pgrep -f 'logic-caffeinate' >/dev/null && echo "   caffeinate 1 (PreventUserIdleSystemSleep)" ;;
  *batt*)       cat "$WORK/batt" ;;
  *)            [ "\$(cat "$LIVE")" = 1 ] && printf ' SleepDisabled\t\t1\n'; echo "Currently in use:" ;;
esac
exit 0
EOF

printf '#!/bin/bash\nexec -a logic-caffeinate sleep 100000\n' >"$WORK/stub/caffeinate"
printf '#!/bin/bash\necho "NOTIFY: $*" >>"%s/notify.log"\n' "$WORK" >"$WORK/stub/osascript"
printf '#!/bin/bash\necho "(en)"\n' >"$WORK/stub/defaults"     # force the English strings
chmod +x "$WORK/stub/"*

sed -e "s#/usr/bin/sudo#$WORK/stub/sudo#g" \
    -e "s#/usr/bin/plutil#$WORK/stub/plutil#g" \
    -e "s#/usr/bin/pmset#$WORK/stub/pmset#g" \
    -e "s#/usr/bin/caffeinate#$WORK/stub/caffeinate#g" \
    -e "s#/usr/bin/osascript#$WORK/stub/osascript#g" \
    -e "s#/usr/bin/defaults#$WORK/stub/defaults#g" \
    "$BASE/bin/awake-mode-daemon" >"$WORK/daemon.sh"

PASS=0; FAIL=0
field() { /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['$1'])" "$STATUS" 2>/dev/null; }
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1 ($2)"; PASS=$((PASS+1))
  else echo "  NG   $1: expected $3, got $2"; FAIL=$((FAIL+1)); fi
}
settle() { sleep 3; }
# The outside world moving the value: powerd and the plist both change.
external_set() { echo "$1" >"$SD"; [ "$1" = true ] && echo 1 >"$LIVE" || echo 0 >"$LIVE"; }
write_config() { printf '%s\n' "$@" >"$CONFIG"; }

write_config "INTERVAL_SEC=1"
echo lid >"$MODE_FILE"
HOME="$FAKE_HOME" bash "$WORK/daemon.sh" &
DAEMON=$!
trap 'kill $DAEMON 2>/dev/null; pkill -f logic-caffeinate 2>/dev/null' EXIT
settle

echo "[1] lid"
check "SleepDisabled" "$(cat "$SD")" true
check "caffeinate" "$(field caffeinate)" True
check "ok" "$(field ok)" True

echo "[2] lock: the display may sleep, the machine may not"
echo lock >"$MODE_FILE"; settle
check "SleepDisabled" "$(cat "$SD")" false
check "caffeinate" "$(field caffeinate)" True
check "ok" "$(field ok)" True

echo "[3] normal"
echo normal >"$MODE_FILE"; settle
check "SleepDisabled" "$(cat "$SD")" false
check "caffeinate" "$(field caffeinate)" False
check "ok" "$(field ok)" True

echo "[4] the value is knocked down from outside while lid runs"
echo lid >"$MODE_FILE"; settle; external_set false; settle
check "put back" "$(cat "$SD")" true

echo "[5] the caffeinate child is killed"
old=$(pgrep -P "$DAEMON" -f logic-caffeinate | head -1); kill "$old" 2>/dev/null; settle
new=$(pgrep -P "$DAEMON" -f logic-caffeinate | head -1)
check "new pid appears" "$([ -n "$new" ] && [ "$new" != "$old" ] && echo yes || echo no)" yes

echo "[6] the mode file is gone"
rm -f "$MODE_FILE"; settle
check "treated as normal" "$(field mode)" normal
check "SleepDisabled" "$(cat "$SD")" false
check "reason code" "$(field reason)" no_mode_file

echo "[7] an unknown word"
echo gorilla >"$MODE_FILE"; settle
check "treated as normal" "$(field mode)" normal
check "reason code" "$(field reason)" invalid_mode
check "the word is kept" "$(field detail)" gorilla

echo "[8] battery guard releases everything, not just the lid setting"
echo lid >"$MODE_FILE"; settle
printf '5,battery\n' >"$BATTERY_FILE"; settle
check "guard on" "$(field battery_guard)" True
check "SleepDisabled released" "$(cat "$SD")" false
check "caffeinate released" "$(field caffeinate)" False
check "the mode is kept" "$(field mode)" lid
check "percentage reported" "$(field battery_percent)" 5
check "notified once" "$(grep -c 'sleep prevention released' "$WORK/notify.log" 2>/dev/null)" 1

echo "[9] power comes back"
printf '80,ac\n' >"$BATTERY_FILE"; settle
check "guard off" "$(field battery_guard)" False
check "SleepDisabled" "$(cat "$SD")" true
check "caffeinate" "$(field caffeinate)" True
check "notified once" "$(grep -c 'sleep prevention resumed' "$WORK/notify.log" 2>/dev/null)" 1
rm -f "$BATTERY_FILE"; settle

echo "[10] the guard does not fire in normal mode"
echo normal >"$MODE_FILE"; printf '3,battery\n' >"$BATTERY_FILE"; settle
check "no guard" "$(field battery_guard)" False
check "no reason" "$(field reason)" ""
rm -f "$BATTERY_FILE"; echo lid >"$MODE_FILE"; settle

echo "[11] sudo is refused"
echo fail >"$WORK/sudo_mode"; external_set false; settle
check "ok is false" "$(field ok)" False
check "reason code" "$(field reason)" sudo_denied
echo ok >"$WORK/sudo_mode"; settle
check "recovers" "$(field ok)" True

echo "[12] the log only grows when something changes"
before=$(wc -l <"$LOG"); sleep 6; after=$(wc -l <"$LOG")
check "lines added over 6 cycles" "$((after-before))" 0

echo "[13] a second instance stands down"
HOME="$FAKE_HOME" bash "$WORK/daemon.sh" 2>/dev/null &
second=$!; sleep 3; kill "$second" 2>/dev/null; wait "$second" 2>/dev/null
check "stood down" "$(grep -c 'another instance' "$LOG")" 1

echo "[14] an 8 second plist lag neither turns it red nor repeats the call"
echo normal >"$MODE_FILE"; settle
echo 8 >"$WORK/lag"
log_mark=$(grep -c 'pmset_ineffective' "$LOG"); sudo_mark=$(wc -l <"$WORK/sudo_calls")
echo lid >"$MODE_FILE"
sleep 4
check "the plist is still behind" "$(cat "$SD")" false
check "powerd already has it" "$(cat "$LIVE")" 1
check "ok is not dropped" "$(field ok)" True
check "the reported value follows powerd" "$(field sleep_disabled)" 1
sleep 8
check "the plist catches up" "$(cat "$SD")" true
check "no ineffective claim logged" "$(( $(grep -c 'pmset_ineffective' "$LOG") - log_mark ))" 0
check "pmset called once" "$(( $(wc -l <"$WORK/sudo_calls") - sudo_mark ))" 1
rm -f "$WORK/lag"

echo "[15] low power mode follows mode and power source"
echo 0 >"$LPM"; write_config "INTERVAL_SEC=1" "LOW_POWER_ON_BATTERY=1"; settle
echo lid >"$MODE_FILE"; printf '90,battery\n' >"$BATTERY_FILE"; settle
check "lid on battery turns it on" "$(cat "$LPM")" 1
check "reported" "$(field low_power)" 1
calls=$(wc -l <"$WORK/lpm_calls"); sleep 4
check "it is not set again every cycle" "$(( $(wc -l <"$WORK/lpm_calls") - calls ))" 0
printf '90,ac\n' >"$BATTERY_FILE"; settle
check "on AC it goes off" "$(cat "$LPM")" 0
printf '90,battery\n' >"$BATTERY_FILE"; settle
check "back on battery" "$(cat "$LPM")" 1
echo normal >"$MODE_FILE"; settle
check "normal turns it off" "$(cat "$LPM")" 0
echo lock >"$MODE_FILE"; settle
check "lock turns it on too" "$(cat "$LPM")" 1

echo "[16] the guard keeps low power on while it releases the rest"
printf '4,battery\n' >"$BATTERY_FILE"; echo lid >"$MODE_FILE"; settle
check "guard on" "$(field battery_guard)" True
check "low power stays on" "$(cat "$LPM")" 1
check "SleepDisabled released" "$(cat "$SD")" false
rm -f "$BATTERY_FILE"; settle

echo "[17] LOW_POWER_ON_BATTERY=0 never touches the setting"
# The config has to land first, or the still-owning daemon resets the value we
# are about to plant.
write_config "INTERVAL_SEC=1" "LOW_POWER_ON_BATTERY=0"; settle
echo 1 >"$LPM"                       # as if the owner had turned it on themselves
echo lid >"$MODE_FILE"; printf '90,battery\n' >"$BATTERY_FILE"; settle
calls=$(wc -l <"$WORK/lpm_calls")
sleep 4
check "left alone" "$(cat "$LPM")" 1
check "not written" "$(( $(wc -l <"$WORK/lpm_calls") - calls ))" 0
check "reported as off, since we do not manage it" "$(field low_power)" 0
rm -f "$BATTERY_FILE"

echo "[18] the config file is read while running"
write_config "INTERVAL_SEC=1" "LOW_POWER_ON_BATTERY=0" "BATTERY_SLEEP_PERCENT=50" "BATTERY_RESUME_PERCENT=60"
printf '40,battery\n' >"$BATTERY_FILE"; settle
check "40% is below the new threshold" "$(field battery_guard)" True
printf '55,battery\n' >"$BATTERY_FILE"; settle
check "55% is still below resume" "$(field battery_guard)" True
printf '65,battery\n' >"$BATTERY_FILE"; settle
check "65% resumes" "$(field battery_guard)" False
check "the change was logged" "$(grep -c 'config: .*battery_sleep=50' "$LOG")" 1
rm -f "$BATTERY_FILE"

echo "[19] a broken config falls back to the defaults"
write_config "INTERVAL_SEC=1" "BATTERY_SLEEP_PERCENT=abc" "NONSENSE=1" "no equals sign" "# comment"
printf '12,battery\n' >"$BATTERY_FILE"; echo lid >"$MODE_FILE"; settle
check "12% is above the default 10" "$(field battery_guard)" False
printf '8,battery\n' >"$BATTERY_FILE"; settle
check "8% is below the default 10" "$(field battery_guard)" True
rm -f "$BATTERY_FILE"; write_config "INTERVAL_SEC=1"; settle

echo "[20] SIGTERM cleans up"
echo 1 >"$LPM"; write_config "INTERVAL_SEC=1" "LOW_POWER_ON_BATTERY=1"
echo lid >"$MODE_FILE"; printf '90,battery\n' >"$BATTERY_FILE"; settle
check "low power is on before the stop" "$(cat "$LPM")" 1
kill -TERM "$DAEMON"; sleep 2
check "SleepDisabled back to 0" "$(cat "$SD")" false
check "low power back to 0" "$(cat "$LPM")" 0
check "no caffeinate left" "$(pgrep -f logic-caffeinate | wc -l | tr -d ' ')" 0
check "the lock is released" "$([ -d "$STATE/lock" ] && echo left || echo gone)" gone
rm -f "$BATTERY_FILE"

echo "[21] SIGTERM lands at once even with a long interval"
# launchctl bootout sends SIGKILL a few seconds after SIGTERM: a foreground
# sleep would swallow the trap and leave SleepDisabled=1 behind.
write_config "INTERVAL_SEC=30"
echo lid >"$MODE_FILE"
HOME="$FAKE_HOME" bash "$WORK/daemon.sh" &
long=$!; sleep 3
check "lid took effect" "$(cat "$SD")" true
started=$(date +%s); kill -TERM "$long"
waited=0
while kill -0 "$long" 2>/dev/null && [ "$waited" -lt 16 ]; do sleep 0.5; waited=$((waited+1)); done
elapsed=$(( $(date +%s) - started ))
check "time to exit" "$([ "$elapsed" -le 3 ] && echo "3s or less" || echo "${elapsed}s")" "3s or less"
check "cleanup ran" "$(cat "$SD")" false

echo "[22] only entering lock blanks the screen"
count_dsn() { wc -l <"$WORK/dsn_calls" | tr -d ' '; }
log_mark=$(grep -c 'lock: displaysleepnow' "$LOG")
write_config "INTERVAL_SEC=1"
echo lock >"$MODE_FILE"                    # already in lock when it starts
: >"$WORK/dsn_calls"
HOME="$FAKE_HOME" bash "$WORK/daemon.sh" &
last=$!; sleep 3
check "starting in lock does not blank" "$(count_dsn)" 0
echo normal >"$MODE_FILE"; sleep 3; : >"$WORK/dsn_calls"
echo lock >"$MODE_FILE"; sleep 3
check "normal to lock blanks once" "$(count_dsn)" 1
: >"$WORK/dsn_calls"; sleep 4
check "staying in lock does not blank" "$(count_dsn)" 0
echo lid >"$MODE_FILE"; sleep 3; : >"$WORK/dsn_calls"
echo lock >"$MODE_FILE"; sleep 3
check "lid to lock blanks once" "$(count_dsn)" 1
: >"$WORK/dsn_calls"
echo lid >"$MODE_FILE"; sleep 3
check "leaving lock does not blank" "$(count_dsn)" 0
check "one log line per blank" "$(( $(grep -c 'lock: displaysleepnow' "$LOG") - log_mark ))" 2
kill -TERM "$last" 2>/dev/null; sleep 2

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
