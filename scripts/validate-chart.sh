#!/usr/bin/env bash
# Static checks for the chart: lint, render each values set, validate rendered manifests against
# the Kubernetes OpenAPI schemas (kubeconform), scan them for misconfigurations (trivy), and
# confirm that unsafe or incomplete values are rejected.
set -euo pipefail
cd "$(dirname "$0")/.."
chart=charts/pulse
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
k8s_version=${K8S_VERSION:-1.33.0}

declare -A sets=(
  [default]="--set image.tag=1.0.0"
  [dev]="-f $chart/values-dev.yaml"
  [prod]="-f $chart/values-prod.yaml --set image.digest=sha256:$(printf '0%.0s' {1..64})"
  [faults]="-f $chart/values-dev.yaml --set faultInjection.enabled=true --set faultInjection.existingSecret=pulse-admin"
)

for name in default dev prod faults; do
  # shellcheck disable=SC2086  # option strings are intentionally word-split
  helm lint "$chart" ${sets[$name]} --quiet >/dev/null
  # shellcheck disable=SC2086
  helm template pulse "$chart" ${sets[$name]} > "$out/$name.yaml"
  kubeconform -strict -summary -kubernetes-version "$k8s_version" "$out/$name.yaml"
  kinds=$(grep -E '^kind:' "$out/$name.yaml" | awk '{print $2}' | sort | tr '\n' ' ')
  echo "ok  $name: helm lint + template + kubeconform ($kinds)"
done

echo "--- trivy config on rendered prod manifests (HIGH/CRITICAL)"
trivy config --quiet --severity HIGH,CRITICAL --exit-code 1 "$out/prod.yaml"
echo "ok  trivy: no HIGH/CRITICAL misconfigurations"

echo "--- values that must be rejected"
reject() {  # description, helm args...
  local why=$1; shift
  if helm template pulse "$chart" "$@" >/dev/null 2>&1; then
    echo "FAIL (accepted): $why"; return 1
  fi
  echo "ok  rejected: $why"
}
reject "no image tag or digest"                --set image.tag=
reject "image tag 'latest'"                    --set image.tag=latest
reject "malformed digest"                      --set image.digest=sha256:abc
reject "running as root allowed"               --set image.tag=1.0.0 --set podSecurityContext.runAsNonRoot=false
reject "privilege escalation allowed"          --set image.tag=1.0.0 --set securityContext.allowPrivilegeEscalation=true
reject "writable root filesystem"              --set image.tag=1.0.0 --set securityContext.readOnlyRootFilesystem=false
reject "fault injection without a Secret ref"  --set image.tag=1.0.0 --set faultInjection.enabled=true
reject "lowercase config key"                  --set image.tag=1.0.0 --set config.log_level=debug
echo "all chart checks passed"
