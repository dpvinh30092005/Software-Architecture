#!/usr/bin/env bash
# =====================================================================
# demo-breaker.sh - quan sat circuit breaker doi trang thai theo tung loi goi
#
#   ./demo-breaker.sh          goi 8 lan
#   ./demo-breaker.sh 12       goi 12 lan
#   ./demo-breaker.sh events   in nhat ky chuyen trang thai
#   ./demo-breaker.sh reset    xem trang thai hien tai, khong goi gi
# =====================================================================
BASE=http://127.0.0.1:8090
CB=QUESTION-SERVICE

state() {
  curl -s -m 5 "$BASE/actuator/circuitbreakers" | python -c "
import sys, json
try:
    cbs = json.load(sys.stdin)['circuitBreakers']
except Exception:
    print('      [!] khong doc duoc /actuator/circuitbreakers'); raise SystemExit
d = cbs.get('$CB')
if d is None:
    print('      [!] chua co breaker ten $CB. Dang co: ' + ', '.join(cbs) )
    print('          -> CircuitBreakerNameResolver chua duoc nap')
    raise SystemExit
print('      state=%-9s buffered=%-3s failed=%-3s notPermitted=%-3s rate=%s'
      % (d['state'], d['bufferedCalls'], d['failedCalls'], d['notPermittedCalls'], d['failureRate']))
"
}

events() {
  echo "=== Nhat ky chuyen trang thai ==="
  curl -s -m 5 "$BASE/actuator/circuitbreakerevents" | python -c "
import sys, json
evs = json.load(sys.stdin)['circuitBreakerEvents']
for e in evs:
    if e.get('stateTransition'):
        print('  %s  %-22s %s' % (e['creationTime'][11:19], e['type'], e['stateTransition']))
if not any(e.get('stateTransition') for e in evs):
    print('  (chua co lan chuyen trang thai nao)')
print('  tong so su kien: %d' % len(evs))
"
}

call() {
  local out
  out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 30 \
        -X POST "$BASE/quiz/create" \
        -H 'Content-Type: application/json' \
        -d '{"category":"java","numQ":2,"title":"demo"}')
  printf "  lan %-2s  http=%s  %ss\n" "$1" "${out% *}" "${out#* }"
}

case "${1:-}" in
  events) events; exit 0 ;;
  reset)  echo "Trang thai hien tai:"; state; events; exit 0 ;;
esac

N=${1:-8}
echo "Goi POST /quiz/create $N lan"
echo "-----------------------------------------------------------"
for i in $(seq 1 "$N"); do
  call "$i"
  state
done
echo "-----------------------------------------------------------"
events
