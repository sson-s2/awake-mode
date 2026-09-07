#!/bin/bash
# Fault injection against the installed awake-mode, on this machine.
#   test.sh              run a through j
#   test.sh a d f        run only those
#
# It changes real power settings while it runs and puts them back at the end,
# including the mode that was selected before it started. Run it after install.sh.
set -u

STATE_DIR="$HOME/Library/Application Support/awake-mode"
MODE_FILE="$STATE_DIR/mode"
STATUS_FILE="$STATE_DIR/status.json"
CONFIG_FILE="$STATE_DIR/config"
BATTERY_FILE="$STATE_DIR/test-battery"
LOG_FILE="$HOME/Library/Logs/awake-mode.log"
AGENTS_DIR="$HOME/Library/LaunchAgents"
APP="$HOME/Applications/AwakeMode.app"
DAEMON_LABEL="io.github.sson-s2.awake-mode"
USER_ID=$(id -u)

RESULTS=()
PASSED=0; FAILED=0; SKIPPED=0

# powerd's value, not the preferences plist: the plist lags a pmset call by
# seconds, and a test that reads it fails while the daemon is right.
sleep_disabled() {
  local v
  v=$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2; exit}')
  case "$v" in 1|true) echo 1 ;; *) echo 0 ;; esac
}
low_power() {
  pmset -g custom 2>/dev/null | awk '
    /^Battery Power:/ { inbatt = 1; next }
    /^[A-Za-z].*:/    { inbatt = 0 }
    inbatt && $1 == "lowpowermode" { print ($2 == "1") ? 1 : 0; found = 1; exit }
    END { if (!found) print 0 }'
}
daemon_pid()     { pgrep -f 'awake-mode-daemon' | head -1; }
caffeinate_pid() { local p; p=$(daemon_pid); [ -n "$p" ] && pgrep -P "$p" caffeinate | head -1; }
field()          { /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('$1'))" "$STATUS_FILE" 2>/dev/null; }

sd_on()      { [ "$(sleep_disabled)" = 1 ]; }
sd_off()     { [ "$(sleep_disabled)" = 0 ]; }
caf_up()     { [ -n "$(caffeinate_pid)" ]; }
caf_down()   { [ -z "$(caffeinate_pid)" ]; }
daemon_up()  { [ -n "$(daemon_pid)" ]; }
status_ok()  { [ "$(field ok)" = True ]; }
mode_is()    { [ "$(field mode)" = "$1" ]; }
reason_is()  { [ "$(field reason)" = "$1" ]; }
guard_is()   { [ "$(field battery_guard)" = "$1" ]; }
lpm_is()     { [ "$(low_power)" = "$1" ]; }
set_mode()   { printf '%s\n' "$1" >"$MODE_FILE"; }

# wait_for <seconds> <predicate...>
wait_for() {
  local limit=$1; shift; local i=0
  while [ "$i" -lt "$limit" ]; do "$@" && return 0; sleep 1; i=$((i+1)); done
  return 1
}

record() {   # record <id> <what> <expected> <observed> <verdict>
  RESULTS+=("| $1 | $2 | $3 | $4 | $5 |")
  case "$5" in PASS) PASSED=$((PASSED+1));; FAIL) FAILED=$((FAILED+1));; *) SKIPPED=$((SKIPPED+1));; esac
  printf '  %-2s %-4s %s\n' "$1" "$5" "$4"
}
verdict() { [ "$1" = 0 ] && echo PASS || echo FAIL; }

run_a() {
  echo "[a] the watchdog is killed with SIGKILL"
  set_mode lid; wait_for 30 status_ok >/dev/null
  local old; old=$(daemon_pid); kill -9 "$old" 2>/dev/null
  local bad=0
  wait_for 40 daemon_up || bad=1
  wait_for 25 sd_on     || bad=1
  wait_for 25 caf_up    || bad=1
  record a "kill -9 the watchdog (pid=$old)" "launchd restarts it and both settings come back" \
         "new pid=$(daemon_pid) sd=$(sleep_disabled) caffeinate=$(caffeinate_pid)" "$(verdict $bad)"
}

run_b() {
  echo "[b] the setting is knocked down from outside"
  set_mode lid; wait_for 30 sd_on >/dev/null
  local before; before=$(wc -l <"$LOG_FILE")
  sudo -n /usr/bin/pmset disablesleep 0 >/dev/null 2>&1 || {
    record b "pmset disablesleep 0 from outside" "back to 1 within a cycle" "sudo -n refused, cannot inject" SKIP; return; }
  local bad=0
  wait_for 25 sd_on || bad=1
  record b "pmset disablesleep 0 from outside" "back to 1 within a cycle, one log line" \
         "sd=$(sleep_disabled) log lines added=$(( $(wc -l <"$LOG_FILE") - before ))" "$(verdict $bad)"
}

run_c() {
  echo "[c] the caffeinate child is killed"
  set_mode lid; wait_for 30 caf_up >/dev/null
  local old; old=$(caffeinate_pid); kill "$old" 2>/dev/null
  local bad=1
  if wait_for 25 caf_up && [ "$(caffeinate_pid)" != "$old" ]; then bad=0; fi
  record c "kill the caffeinate child (pid=$old)" "a new one appears within a cycle" \
         "old=$old new=$(caffeinate_pid)" "$(verdict $bad)"
}

run_d() {
  echo "[d] switching modes"
  local bad=0 seen=""
  for mode in lock normal lid; do
    set_mode "$mode"; wait_for 25 mode_is "$mode" >/dev/null; sleep 2
    local want_sd want_caf got_sd=off got_caf=no
    case "$mode" in
      lid)  want_sd=on;  want_caf=yes ;;
      lock) want_sd=off; want_caf=yes ;;
      *)    want_sd=off; want_caf=no  ;;
    esac
    sd_on && got_sd=on
    # pmset -g assertions would count every other program's caffeinate too, so
    # only the watchdog's own child counts here.
    caf_up && got_caf=yes
    { [ "$got_sd" = "$want_sd" ] && [ "$got_caf" = "$want_caf" ]; } || bad=1
    seen="$seen ${mode}:sd=${got_sd}/caffeinate=${got_caf}"
  done
  record d "lock, normal, lid" "lid=on/yes, lock=off/yes, normal=off/no" "$seen" "$(verdict $bad)"
}

run_e() {
  echo "[e] the mode file goes missing or holds nonsense"
  local bad=0
  # Waiting for mode=normal alone would pass on the previous cycle's value; the
  # reason code is the proof that this file was the one that got read.
  rm -f "$MODE_FILE"
  wait_for 25 reason_is no_mode_file || bad=1
  local first="missing: mode=$(field mode) sd=$(sleep_disabled) reason=$(field reason)"
  mode_is normal || bad=1
  sd_off || bad=1
  printf 'gorilla\n' >"$MODE_FILE"
  wait_for 25 reason_is invalid_mode || bad=1
  local second="nonsense: mode=$(field mode) detail=$(field detail)"
  mode_is normal || bad=1
  sd_off || bad=1
  set_mode lid
  record e "delete the mode file, then write an unknown word" \
         "both fall back to normal with SleepDisabled=0 and a reason code" \
         "$first / $second" "$(verdict $bad)"
}

run_f() {
  echo "[f] battery guard"
  local bad=0
  set_mode lid; wait_for 30 sd_on >/dev/null
  printf '5,battery\n' >"$BATTERY_FILE"
  wait_for 40 guard_is True || bad=1
  sleep 2
  local low="at 5%: guard=$(field battery_guard) sd=$(sleep_disabled) caffeinate=$(caffeinate_pid) mode=$(field mode)"
  sd_off    || bad=1
  caf_down  || bad=1            # the new part: idle sleep is released too
  mode_is lid || bad=1          # the selection survives the guard
  printf '80,ac\n' >"$BATTERY_FILE"
  wait_for 40 guard_is False || bad=1
  wait_for 25 sd_on          || bad=1
  wait_for 25 caf_up         || bad=1
  local back="back on power: guard=$(field battery_guard) sd=$(sleep_disabled) caffeinate=$(caffeinate_pid)"
  rm -f "$BATTERY_FILE"
  record f "inject 5% on battery, then 80% on AC" \
         "everything holding the machine up is released, the mode is kept, and it resumes" \
         "$low / $back" "$(verdict $bad)"
}

run_g() {
  echo "[g] a clean stop and restart"
  set_mode lid; wait_for 30 sd_on >/dev/null
  launchctl bootout "gui/$USER_ID/$DAEMON_LABEL" 2>/dev/null
  local bad=0
  wait_for 25 sd_off || bad=1
  local stopped="after bootout sd=$(sleep_disabled)"
  launchctl bootstrap "gui/$USER_ID" "$AGENTS_DIR/$DAEMON_LABEL.plist" 2>/dev/null
  wait_for 40 sd_on || bad=1
  record g "launchctl bootout, then bootstrap" "stopping restores 0, starting restores 1" \
         "$stopped / after bootstrap sd=$(sleep_disabled) caffeinate=$(caffeinate_pid)" "$(verdict $bad)"
}

run_h() {
  echo "[h] the menu bar app"
  local bad=0
  local app_pid; app_pid=$(pgrep -f "$APP/Contents/MacOS/AwakeMode" | head -1)
  [ -n "$app_pid" ] || bad=1
  # Clicking a menu item does exactly this: write one word. Driving the real
  # click needs accessibility permission, so the colour is checked by eye.
  set_mode lock; wait_for 25 mode_is lock >/dev/null || bad=1
  local locked="lock: mode=$(field mode) sd=$(sleep_disabled) caffeinate=$(caffeinate_pid)"
  set_mode lid;  wait_for 25 mode_is lid >/dev/null || bad=1
  status_ok || bad=1
  record h "the app runs and the state follows a selection" "alive, and the selection reaches status.json" \
         "pid=${app_pid:-none} / $locked / lid: ok=$(field ok) sd=$(sleep_disabled)" "$(verdict $bad)"
  echo "     (check the icon colour by eye: green in effect, red not, orange battery guard, grey normal)"
}

run_i() {
  echo "[i] low power mode follows the mode and the power source"
  local bad=0
  case "$(sed -n 's/^ *LOW_POWER_ON_BATTERY *= *//p' "$CONFIG_FILE" 2>/dev/null | tail -1)" in
    0) record i "low power mode transitions" "on for lid on battery, off otherwise" \
              "LOW_POWER_ON_BATTERY=0 in the config, so awake-mode does not manage it" SKIP; return ;;
  esac
  set_mode lid; wait_for 30 status_ok >/dev/null
  printf '90,battery\n' >"$BATTERY_FILE"
  wait_for 30 lpm_is 1 || bad=1
  local on="lid on battery: lowpowermode=$(low_power)"
  printf '90,ac\n' >"$BATTERY_FILE"
  wait_for 30 lpm_is 0 || bad=1
  local ac="on AC: lowpowermode=$(low_power)"
  printf '90,battery\n' >"$BATTERY_FILE"
  wait_for 30 lpm_is 1 || bad=1
  set_mode normal
  wait_for 30 lpm_is 0 || bad=1
  local normal="normal on battery: lowpowermode=$(low_power)"
  rm -f "$BATTERY_FILE"; set_mode lid
  wait_for 30 status_ok >/dev/null
  record i "lid on battery, on AC, then normal" "on only while a keep-awake mode runs on battery" \
         "$on / $ac / $normal" "$(verdict $bad)"
}

run_j() {
  echo "[j] the settings file is read while it runs"
  local bad=0
  local saved; saved=$(cat "$CONFIG_FILE" 2>/dev/null || true)
  set_mode lid; wait_for 30 sd_on >/dev/null
  printf 'INTERVAL_SEC=10\nBATTERY_SLEEP_PERCENT=50\nBATTERY_RESUME_PERCENT=60\nLOW_POWER_ON_BATTERY=0\n' >"$CONFIG_FILE"
  printf '40,battery\n' >"$BATTERY_FILE"
  wait_for 40 guard_is True || bad=1
  local below="at 40% with the threshold moved to 50: guard=$(field battery_guard)"
  printf '65,battery\n' >"$BATTERY_FILE"
  wait_for 40 guard_is False || bad=1
  local above="at 65%: guard=$(field battery_guard)"
  rm -f "$BATTERY_FILE"
  printf '%s\n' "$saved" >"$CONFIG_FILE"
  sleep 12
  record j "move BATTERY_SLEEP_PERCENT to 50 while it runs" "the new threshold takes effect without a restart" \
         "$below / $above" "$(verdict $bad)"
}

daemon_up || { echo "the watchdog is not running. Run install.sh first."; exit 1; }

STARTING_MODE=$(cat "$MODE_FILE" 2>/dev/null || echo normal)
STARTING_CONFIG=$(cat "$CONFIG_FILE" 2>/dev/null || true)
restore() {
  rm -f "$BATTERY_FILE"
  [ -n "$STARTING_CONFIG" ] && printf '%s\n' "$STARTING_CONFIG" >"$CONFIG_FILE"
  printf '%s\n' "$STARTING_MODE" >"$MODE_FILE"
  launchctl print "gui/$USER_ID/$DAEMON_LABEL" >/dev/null 2>&1 ||
    launchctl bootstrap "gui/$USER_ID" "$AGENTS_DIR/$DAEMON_LABEL.plist" 2>/dev/null
  wait_for 40 mode_is "$STARTING_MODE" >/dev/null
}
trap restore EXIT

TESTS=("$@")
[ ${#TESTS[@]} -eq 0 ] && TESTS=(a b c d e f g h i j)
for t in "${TESTS[@]}"; do "run_$t"; done

restore

echo
echo "| # | what | expected | observed | verdict |"
echo "|---|---|---|---|---|"
# bash 3.2, the one macOS ships, treats an empty array as unset under set -u.
[ "${#RESULTS[@]}" -gt 0 ] && printf '%s\n' "${RESULTS[@]}"
echo
echo "PASS=$PASSED FAIL=$FAILED SKIP=$SKIPPED"
echo "left as: mode=$(cat "$MODE_FILE") SleepDisabled=$(sleep_disabled) lowpowermode=$(low_power)"
[ "$FAILED" = 0 ]
