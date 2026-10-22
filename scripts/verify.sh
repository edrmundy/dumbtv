#!/usr/bin/env bash
# Proof that it worked: blocked hosts must answer 0.0.0.0, everyday hosts must
# still resolve, and HOME must land on dumbtv home unless the user kept Amazon's.
# Exit code 0 means every enabled check passed.
# Usage: ./scripts/verify.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$ROOT/scripts/accessibility.sh"
parse_flags "$@"
need_device
load_conf

fail=0
printf '\n%-10s %-38s %s\n' '' host result
printf '%-10s %-38s %s\n' '----------' '--------------------------------------' '----------------------'

if [[ $DNSFILTER == 0 ]]; then
  printf '%-10s %-38s %s\n' skip dns "DNSFILTER=0, not checked"
else
  while read -r h; do
    line=$(dev "ping -c1 -W2 $h" | head -1)
    case $line in
      *0.0.0.0*|*127.0.0.1*) printf '%-10s %-38s blocked\n' ok "$h" ;;
      *) printf '%-10s %-38s NOT BLOCKED\n' FAIL "$h"; fail=1 ;;
    esac
  done < <(expected_blocked)

  while read -r h; do
    line=$(dev "ping -c1 -W2 $h" | head -1)
    case $line in
      *0.0.0.0*|*127.0.0.1*) printf '%-10s %-38s WRONGLY BLOCKED\n' FAIL "$h"; fail=1 ;;
      *"unknown host"*|*"not known"*|*"cannot resolve"*|"")
        printf '%-10s %-38s no answer\n' FAIL "$h"; fail=1 ;;
      *) printf '%-10s %-38s resolves\n' ok "$h" ;;
    esac
  done < <(list_of "$DATA/blocklists/verify-allowed.txt")
fi

home=$(dev 'dumpsys activity activities' | grep -m1 mResumedActivity | sed 's/.*u0 //;s/}.*//')
wake=$(dev 'dumpsys power' | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)
alarms=$(dev 'settings get global alarm_manager_constants' | tr -d '\r')
if [[ $LAUNCHER == 0 ]]; then
  printf '%-10s %-38s %s\n' skip home "LAUNCHER=0, not checked"
elif [[ $SDK -lt 28 ]]; then
  # Fire OS 6: the Keeper, not the accessibility service, owns HOME.
  keeper=$(dev 'dumpsys activity services tv.dumbtv.home' | grep -c 'isForeground=true' || true)
  if [[ ${keeper:-0} -gt 0 ]]; then
    printf '%-10s %-38s %s\n' ok home "Keeper armed, front is ${home:-unknown}"
  else
    printf '%-10s %-38s %s\n' FAIL home "Keeper not running; re-run launcher.sh"; fail=1
  fi
else
  # An enabled setting can outlive the process/binding. Check the current user's
  # exact component AND the live bound-service section, without sending HOME.
  current_user=$(dev 'am get-current-user' | tr -d '\r')
  hook=unknown
  case $current_user in
    ''|*[!0-9]*) ;;
    *)
      a11y=$(dev "settings --user $current_user get secure enabled_accessibility_services" | tr -d '\r')
      enabled=$(dev "settings --user $current_user get secure accessibility_enabled" | tr -d '\r')
      case :$a11y: in
        *:tv.dumbtv.home/.Guard:*|*:tv.dumbtv.home/tv.dumbtv.home.Guard:*)
          if [[ $enabled == 1 ]]; then
            if dump=$(dev 'dumpsys accessibility'); then
              printf '%s\n' "$dump" | guard_bound "$current_user"
              case $? in 0) hook=bound ;; 1) hook=unbound ;; esac
            fi
          else
            hook=disabled
          fi ;;
        *) hook=disabled ;;
      esac ;;
  esac
  case $hook in
    bound) printf '%-10s %-38s %s\n' ok home "bound, front is ${home:-unknown}" ;;
    unbound)
      printf '%-10s %-38s %s\n' FAIL home "enabled but not bound; see docs/TROUBLESHOOTING.md"; fail=1 ;;
    disabled)
      printf '%-10s %-38s %s\n' FAIL home "hook disabled (front: ${home:-unknown}, wakefulness: ${wake:-?})"; fail=1 ;;
    *) printf '%-10s %-38s %s\n' FAIL home "cannot verify accessibility binding; inspect dumpsys accessibility"; fail=1 ;;
  esac
  if [[ $alarms != *min_futurity=0* ]]; then
    # Without it HOME still works, but Amazon's home shows for 5 s first.
    printf '%-10s %-38s %s\n' FAIL home-speed "min_futurity=0 missing; re-run launcher.sh"; fail=1
  fi
  # A bound accessibility service proves nothing about the swap: on Fire OS 8 the
  # launch can be refused by the background-activity-start rule even when the
  # service is enabled and bound. The only proof is the HOME key itself.
  # Leave the home screen first: a swap that starts while our own activity is
  # still resumed is allowed anyway, and that would hide a takeover that is
  # broken.
  [[ $wake == Awake ]] || { dev 'input keyevent KEYCODE_WAKEUP' >/dev/null 2>&1 || true; sleep 2; }
  dev 'am start -a android.intent.action.MAIN -c android.intent.category.LEANBACK_SETTINGS' >/dev/null 2>&1 || true
  sleep 4
  away=$(dev 'dumpsys activity activities' | grep -m1 mResumedActivity | sed 's/.*u0 //;s/}.*//')
  if [[ $away == tv.dumbtv.home/* ]]; then
    printf '%-10s %-38s %s\n' skip home-key "could not leave the home screen; press HOME to check"
  else
    dev 'input keyevent KEYCODE_HOME' >/dev/null 2>&1 || true
    sleep 5
    landed=$(dev 'dumpsys activity activities' | grep -m1 mResumedActivity | sed 's/.*u0 //;s/}.*//')
    case $landed in
      tv.dumbtv.home/*) printf '%-10s %-38s %s\n' ok home-key "HOME lands on $landed" ;;
      *) printf '%-10s %-38s %s\n' FAIL home-key "HOME lands on ${landed:-unknown}"; fail=1 ;;
    esac
  fi
fi

printf '%-10s %-38s %s\n' packages "" "$(dev 'pm list packages -d' | wc -l | tr -d ' ') disabled"

if [[ $DNSFILTER == 0 ]]; then
  printf '%-10s %-38s %s\n' skip filter "not installed by choice"
else
  n=$(dev 'grep -c . /sdcard/Android/data/dnsfilter.android/files/PersonalDNSFilter/FILTERHOSTS.TXT 2>/dev/null' | tr -d '\r')
  if [[ $SDK -ge 30 ]] && ! [[ ${n:-0} -gt 0 ]] 2>/dev/null; then
    # Android 11 hides Android/data from adb; the blocked-host lookups above are the proof.
    printf '%-10s %-38s %s\n' skip filter "list not readable over adb on $(fireos_name); see the DNS checks"
  elif [[ ${n:-0} -gt 0 ]] 2>/dev/null; then
    printf '%-10s %-38s %s entries\n' ok filter "$n"
  else
    printf '%-10s %-38s %s\n' FAIL filter "missing or empty"; fail=1
  fi
  vpn=$(dev 'settings get secure always_on_vpn_app' | tr -d '\r')
  if [[ $vpn == dnsfilter.android ]]; then
    printf '%-10s %-38s %s\n' ok vpn "$vpn"
  elif tunif=$(dev 'ip addr show' | sed -n 's/^[0-9]*: \(tun[0-9]*\):.*UP.*/\1/p' | head -1) && [[ -n $tunif ]]; then
    # Fire OS 6 always forgets always_on_vpn_app at boot; at least one Fire OS 7 build
    # (7.7.1.3 / PS7713) does too. Either way the app's own AUTOSTART boot receiver
    # brings the tunnel up on its own, so a live tunN is the real proof it is filtering.
    # The interface name is not stable across boots (seen tun0, then tun1 on the same
    # device), so match any tunN rather than hardcoding tun0.
    printf '%-10s %-38s %s\n' ok vpn "$tunif up (started by its boot receiver, not always-on)"
  else
    printf '%-10s %-38s %s\n' FAIL vpn "${vpn:-unset}; no tun interface up; open personalDNSfilter once, then reboot"; fail=1
  fi
fi

if [[ $LAUNCHER == 0 ]]; then
  printf '%-10s %-38s %s\n' skip alarm "LAUNCHER=0, not checked"
elif [[ $SDK -lt 28 ]]; then
  printf '%-10s %-38s %s\n' skip alarm "Fire OS 6 Keeper uses moveTaskToFront"
else
  # dumbtv home needs this to answer HOME immediately; an update can drop it.
  if dev 'settings get global alarm_manager_constants' | grep -q 'min_futurity=0'; then
    printf '%-10s %-38s %s\n' ok alarm "min_futurity=0"
  else
    printf '%-10s %-38s %s\n' warn alarm "missing min_futurity=0 (HOME is slower, still works)"
  fi
fi

if [[ $fail == 0 ]]; then
  printf '\nall checks passed\n'
else
  printf '\nfailures above. Recovery steps: docs/TROUBLESHOOTING.md\n'
fi
exit $fail
