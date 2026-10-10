#!/usr/bin/env bash
# Delete the lab cluster and everything in it.
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
kind delete cluster --name pulse-lab --kubeconfig "$KUBECONFIG"
