#!/usr/bin/env bash
# Create the kind cluster (idempotent) and side-load the pulse-api images.
# Images are built from ../pulse when it exists next to this repo.
# Env: KUBECONFIG (default ~/.kube/config), IMAGE_TAGS (default "1.0.0 1.1.0")
set -euo pipefail
cd "$(dirname "$0")/.."
cluster=pulse-lab
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
tags=${IMAGE_TAGS:-1.0.0 1.1.0}

if kind get clusters | grep -qx "$cluster"; then
  echo "cluster $cluster already exists"
else
  kind create cluster --config kind/cluster.yaml --kubeconfig "$KUBECONFIG" --wait 120s
fi
kubectl get nodes -o wide

for tag in $tags; do
  if ! docker image inspect "pulse-api:$tag" >/dev/null 2>&1; then
    [[ -d ../pulse ]] || { echo "pulse-api:$tag missing and ../pulse not found" >&2; exit 1; }
    docker build -q --build-arg "APP_VERSION=$tag" -t "pulse-api:$tag" ../pulse
  fi
  kind load docker-image "pulse-api:$tag" --name "$cluster"
done
