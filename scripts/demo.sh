#!/usr/bin/env bash
# Full lab run against the kind cluster; prints a transcript (pipe through tee to keep evidence).
# Steps: install -> verify -> scale -> rolling update under traffic -> broken image -> investigate
#        -> helm rollback -> crash-looping config -> rollback -> readiness failure on one pod.
# Expects scripts/cluster-up.sh to have run. Failing steps are intentional, so no `set -e`.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
ns=pulse
rel=pulse
chart=charts/pulse
url=http://127.0.0.1:30080

# Flags repeated on every upgrade: explicit values instead of --reuse-values, so each revision
# is fully described by its command line.
base=(-n "$ns" -f "$chart/values-dev.yaml" --set faultInjection.enabled=true --set faultInjection.existingSecret=pulse-admin)

step() { printf '\n========== %s ==========\n' "$*"; }
run() {
  printf '$ %s\n' "$*"
  "$@"
  local rc=$?
  ((rc == 0)) || printf '(exit code %d)\n' "$rc"
  return "$rc"
}

# Sample requests through the NodePort and count which version/pod answered.
versions() {
  for _ in $(seq "${1:-10}"); do curl -s --max-time 2 "$url/api/v1/info"; echo; done | python3 -c '
import collections, json, sys
seen = collections.Counter()
for line in filter(None, map(str.strip, sys.stdin)):
    try:
        d = json.loads(line); seen[(d["version"], d["hostname"])] += 1
    except (ValueError, KeyError):
        seen[("error", line[:40])] += 1
for (version, pod), n in sorted(seen.items()):
    print(f"  version={version}  pod={pod}  responses={n}")'
}

# Run a command while sending continuous traffic; report how many requests failed.
under_traffic() {
  local log stop pid rc
  log=$(mktemp); stop="$log.stop"
  (while [[ ! -e $stop ]]; do
     curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 "$url/api/v1/primes/1000" >>"$log"
     sleep 0.05
   done) &
  pid=$!
  run "$@"; rc=$?
  touch "$stop"; wait "$pid"
  echo "traffic during the operation: $(wc -l <"$log") requests, $(grep -vc '^200$' "$log") non-200"
  rm -f "$log" "$stop"
  return "$rc"
}

pods() { kubectl -n "$ns" get pods -l "app.kubernetes.io/instance=$rel" -o wide; }
revision() { helm status "$rel" -n "$ns" -o json | jq -r .version; }

step "0. Cluster"
run kubectl get nodes

step "1. Namespace and Secret (token generated here, never printed, never in git or values)"
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
token=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
kubectl -n "$ns" create secret generic pulse-admin --from-literal=admin-token="$token" \
  --dry-run=client -o yaml | kubectl apply -f -
run kubectl -n "$ns" get secret pulse-admin

step "2. Install release with image 1.0.0"
run helm upgrade --install "$rel" "$chart" "${base[@]}" --set image.tag=1.0.0 --wait --timeout 120s
run kubectl -n "$ns" get deploy,rs,svc,cm,sa
pods
run helm test "$rel" -n "$ns" --logs

step "3. Verify readiness, endpoints and Secret wiring"
run kubectl -n "$ns" get endpointslices -l kubernetes.io/service-name=pulse
pod=$(kubectl -n "$ns" get pod -l "app.kubernetes.io/instance=$rel" -o jsonpath='{.items[0].metadata.name}')
run kubectl -n "$ns" exec "$pod" -- python -c 'import os; print("ADMIN_TOKEN injected from Secret, length", len(os.environ["ADMIN_TOKEN"]))'
echo "admin API without token -> HTTP $(curl -s -o /dev/null -w '%{http_code}' "$url/admin/faults")"
echo "admin API with Secret token -> HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "X-Admin-Token: $token" "$url/admin/faults")"
versions 4

step "4. Scale to 3 replicas through Helm"
run helm upgrade "$rel" "$chart" "${base[@]}" --set image.tag=1.0.0 --set replicaCount=3 --wait --timeout 120s
pods
echo "requests are load-balanced across pods:"
versions 15

step "5. Rolling update 1.0.0 -> 1.1.0 under continuous traffic"
under_traffic helm upgrade "$rel" "$chart" "${base[@]}" --set image.tag=1.1.0 --set replicaCount=3 --wait --timeout 180s
good=$(revision)
echo "last good revision: $good"
run kubectl -n "$ns" rollout history deploy/pulse
versions 9

step "6. Deliberately broken release: image tag that does not exist"
under_traffic helm upgrade "$rel" "$chart" "${base[@]}" --set image.tag=9.9.9-does-not-exist \
  --set image.pullPolicy=IfNotPresent --set replicaCount=3 --wait --timeout 60s

step "7. Investigate the failed rollout"
pods
bad=$(kubectl -n "$ns" get pods --no-headers | awk '$3 ~ /ImagePull|ErrImage/ {print $1; exit}')
echo "\$ kubectl -n $ns describe pod $bad   (Events section)"
kubectl -n "$ns" describe pod "$bad" | sed -n '/^Events:/,$p'
run kubectl -n "$ns" rollout status deploy/pulse --timeout=5s
run helm history "$rel" -n "$ns"
echo "old pods still serve because maxUnavailable=0:"
versions 6

step "8. Restore: helm rollback to revision $good"
run helm rollback "$rel" "$good" -n "$ns" --wait --timeout 120s
pods
versions 6

step "9. Deliberately broken configuration: MAX_PRIME_LIMIT=oops (container exits at startup)"
run helm upgrade "$rel" "$chart" "${base[@]}" --set image.tag=1.1.0 --set replicaCount=3 \
  --set config.MAX_PRIME_LIMIT=oops --wait --timeout 60s
pods
crash=$(kubectl -n "$ns" get pods --no-headers | awk '$3 ~ /CrashLoopBackOff|Error/ {print $1; exit}')
run kubectl -n "$ns" logs "$crash" --previous --tail=2
kubectl -n "$ns" get events --field-selector "involvedObject.name=$crash" --sort-by=.lastTimestamp | tail -4

step "10. Roll back again and verify"
run helm rollback "$rel" "$good" -n "$ns" --wait --timeout 120s
pods
run helm test "$rel" -n "$ns" --logs

step "11. Readiness failure on one pod: removed from endpoints, NOT restarted"
pod=$(kubectl -n "$ns" get pod -l "app.kubernetes.io/instance=$rel" -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$ns" port-forward "pod/$pod" 18000:8000 >/dev/null 2>&1 &
pf=$!
sleep 3
echo "force $pod not-ready: HTTP $(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "X-Admin-Token: $token" \
  -H 'Content-Type: application/json' -d '{"force_not_ready": true}' http://127.0.0.1:18000/admin/faults)"
sleep 20
pods
echo "\$ endpoint conditions"
kubectl -n "$ns" get endpointslices -l kubernetes.io/service-name=pulse \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"  ready="}{.conditions.ready}{"\n"}{end}'
echo "clear fault: HTTP $(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "X-Admin-Token: $token" http://127.0.0.1:18000/admin/faults)"
kill "$pf" 2>/dev/null
sleep 12
pods

step "12. Final state"
run helm history "$rel" -n "$ns"
run kubectl -n "$ns" get deploy pulse -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
