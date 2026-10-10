# Adapting the chart to Azure Kubernetes Service (AKS)

> **Status:** not performed. Everything in this repo was executed on a local **kind** cluster. This page describes what would change on AKS. It is not a record of an AKS deployment.

| Concern | kind (this lab) | AKS |
|---|---|---|
| Cluster creation | `kind create cluster --config kind/cluster.yaml` | Terraform (`azurerm_kubernetes_cluster`, see azure-groundwork for the provider setup) or `az aks create`. Use a system node pool plus a user node pool. |
| Image source | `kind load docker-image`, `pullPolicy: Never` (`values-dev.yaml`) | Azure Container Registry. Attach it to the cluster (the kubelet identity gets the **AcrPull** role) so no `imagePullSecrets` are needed. Deploy by digest: `--set image.digest=sha256:…` |
| Values file | `values-dev.yaml` | `values-prod.yaml`: 3–6 replicas via HPA, PDB `minAvailable: 2`, NetworkPolicy, Ingress |
| Metrics for HPA | metrics-server not installed in this lab | metrics-server is built into AKS, so HPA works out of the box |
| NetworkPolicy | Enforced only if the CNI supports it | Enable a policy engine at cluster creation (Azure CNI with Azure Network Policy, or Cilium) |
| Ingress | NodePort 30080 on 127.0.0.1 | An Ingress or Gateway API controller (AKS application routing add-on or another controller). Set `ingress.className` accordingly. TLS via cert-manager or Key Vault certificates. |
| Secrets | `kubectl create secret` from a generated token | Azure Key Vault plus the **Secrets Store CSI driver** (or External Secrets Operator), using **workload identity**. The chart reads an existing Secret, so only `faultInjection.existingSecret` changes. |
| Who deploys | A person running Helm locally | CI with GitHub OIDC (federated credential, no stored secret) granted *Azure Kubernetes Service Cluster User* plus namespace-scoped Kubernetes RBAC. Or GitOps: Argo CD/Flux syncing the values from a repo, which is the pattern SELISE's public pipelines use. |
| Observability | Prometheus scraping via annotations (see pulse-observability) | Azure Monitor managed Prometheus + Managed Grafana, or a self-hosted kube-prometheus-stack |

## Minimal AKS deploy sequence (for reference)

```bash
az aks get-credentials -g <rg> -n <cluster>
kubectl create namespace pulse
helm upgrade --install pulse charts/pulse -n pulse -f charts/pulse/values-prod.yaml \
  --set image.repository=<acr>.azurecr.io/pulse-api --set image.digest=sha256:<digest> \
  --wait --timeout 5m --rollback-on-failure
helm test pulse -n pulse
```

`--rollback-on-failure` (Helm 4, replaces `--atomic`) restores the previous revision automatically if the release does not become ready. The lab deliberately does **not** use it, so that a failure can be investigated by hand.
