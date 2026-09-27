#!/usr/bin/env bash
# =====================================================================
# demo-breaker.sh - watch the circuit breaker change state, call by call
#
#   ./demo-breaker.sh          make 8 calls
#   ./demo-breaker.sh 12       make 12 calls
#   ./demo-breaker.sh state    show current state only, call nothing
#   ./demo-breaker.sh events   print the state-transition log
#
# Git Bash only. From PowerShell or cmd use demo-breaker.ps1 instead.
# =====================================================================
BASE=http://127.0.0.1:8090
CB=QUESTION-SERVICE

state() {
  curl -s -m 5 "$BASE/actuator/circuitbreakers" | python -c "
import sys, json
try:
    cbs = json.load(sys.stdin)['circuitBreakers']
except Exception:
    print('      [!] cannot read /actuator/circuitbreakers'); raise SystemExit
d = cbs.get('$CB')
if d is None:
    print('      [!] no breaker named $CB. Present: ' + ', '.join(cbs))
    print('          -> CircuitBreakerNameResolver is not being picked up')
    raise SystemExit
print('      state=%-10s buffered=%-3s failed=%-3s notPermitted=%-3s rate=%s'
      % (d['state'], d['bufferedCalls'], d['failedCalls'], d['notPermittedCalls'], d['failureRate']))
"
}

events() {
  echo ""
  echo "=== State transition log ==="
  curl -s -m 5 "$BASE/actuator/circuitbreakerevents" | python -c "
import sys, json
evs = json.load(sys.stdin)['circuitBreakerEvents']
shown = False
for e in evs:
    if e.get('stateTransition'):
        print('  %s  %s' % (e['creationTime'][11:19], e['stateTransition'])); shown = True
if not shown:
    print('  (no state transition yet)')
print('  total events: %d' % len(evs))
"
}

call() {
  local out
  out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 30 \
        -X POST "$BASE/quiz/create" \
        -H 'Content-Type: application/json' \
        -d '{"category":"java","numQ":2,"title":"demo"}')
  printf "  call %-2s http=%s  %ss\n" "$1" "${out% *}" "${out#* }"
}

case "${1:-}" in
  events)       events; exit 0 ;;
  state|reset)  echo "Current state:"; state; events; exit 0 ;;
esac

N=${1:-8}
echo "POST /quiz/create x $N"
echo "-----------------------------------------------------------"
for i in $(seq 1 "$N"); do
  call "$i"
  state
done
echo "-----------------------------------------------------------"
events
