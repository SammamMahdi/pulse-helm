# Verification evidence

- **Environment:** Windows 11, WSL2 Ubuntu 24.04, Docker Engine 29.8.1, kind v0.33.0 (node image `kindest/node:v1.37.0`), kubectl v1.37.1, Helm v4.3.0, kubeconform v0.8.0, Trivy 0.74.0.
- **Date:** 2026-10-10 (UTC 14:44–14:52).
- **Full transcript:** `evidence/execution-logs/demo-transcript.log` in the portfolio.

## Summary

| Requirement | Status |
|---|---|
| Chart lint and template rendering (default, dev, prod, fault-injection values) | Executed successfully |
| Rendered manifests valid against Kubernetes schemas (kubeconform `-strict`) | Executed successfully |
| Rendered prod manifests free of HIGH/CRITICAL misconfigurations (Trivy) | Executed successfully |
| Unsafe/incomplete values rejected (8 cases) | Executed successfully |
| Start local cluster; deploy; verify readiness | Executed successfully |
| Secret integration (reference to an existing Secret) | Executed successfully |
| Scale replicas | Executed successfully |
| Rolling update | Executed successfully (0 failed requests out of 227) |
| Deliberately broken image; investigate; restore | Executed successfully |
| Helm rollback | Executed successfully (twice) |
| Crash-looping release diagnosis | Executed successfully |
| Readiness failure handling | Executed successfully |
| HPA, PDB, NetworkPolicy, Ingress | Statically validated only (kubeconform, Trivy). Not exercised on kind. |
| CI workflow (static checks + kind install + helm test) | Executed successfully on GitHub-hosted runners ([run 38067586638](https://github.com/SammamMahdi/pulse-helm/actions/runs/38067586638)): both jobs green, including a fresh kind install and `helm test` |
| AKS deployment | Not performed (documented in docs/aks.md) |

## Static checks (`scripts/validate-chart.sh`)

```
Summary: 5 resources found in 1 file - Valid: 5, Invalid: 0, Errors: 0, Skipped: 0
ok  default: helm lint + template + kubeconform (ConfigMap Deployment Pod Service ServiceAccount )
ok  dev: helm lint + template + kubeconform (ConfigMap Deployment Pod Service ServiceAccount )
Summary: 9 resources found in 1 file - Valid: 9, Invalid: 0, Errors: 0, Skipped: 0
ok  prod: helm lint + template + kubeconform (ConfigMap Deployment HorizontalPodAutoscaler Ingress NetworkPolicy Pod PodDisruptionBudget Service ServiceAccount )
ok  faults: helm lint + template + kubeconform (ConfigMap Deployment Pod Service ServiceAccount )
ok  trivy: no HIGH/CRITICAL misconfigurations
ok  rejected: no image tag or digest
ok  rejected: image tag 'latest'
ok  rejected: malformed digest
ok  rejected: running as root allowed
ok  rejected: privilege escalation allowed
ok  rejected: writable root filesystem
ok  rejected: fault injection without a Secret ref
ok  rejected: lowercase config key
all chart checks passed
```

## Lab transcript excerpts (`scripts/demo.sh`)

**Cluster**

```
NAME                      STATUS   ROLES           AGE   VERSION
pulse-lab-control-plane   Ready    control-plane   36s   v1.37.0
pulse-lab-worker          Ready    <none>          22s   v1.37.0
pulse-lab-worker2         Ready    <none>          22s   v1.37.0
```

**Install + helm test + Secret wiring**

```
STATUS: deployed
REVISION: 1
pulse-6c9d745684-jm6v7   1/1     Running   0          5s    10.244.2.2   pulse-lab-worker2
helm test passed: {'n': 100, 'prime_count': 25, 'largest_prime': 97}
ADMIN_TOKEN injected from Secret, length 48
admin API without token -> HTTP 401
admin API with Secret token -> HTTP 200
```

**Scale to 3 and load balancing**

```
pulse-6c9d745684-6gdhn   1/1     Running   0          4s    10.244.2.3   pulse-lab-worker2
pulse-6c9d745684-jm6v7   1/1     Running   0          15s   10.244.2.2   pulse-lab-worker2
pulse-6c9d745684-k52lp   1/1     Running   0          4s    10.244.1.3   pulse-lab-worker
requests are load-balanced across pods:
  version=1.0.0  pod=pulse-6c9d745684-6gdhn  responses=7
  version=1.0.0  pod=pulse-6c9d745684-jm6v7  responses=8
```

**Rolling update 1.0.0 → 1.1.0 with traffic running.** About 20 requests/s were sent to `/api/v1/primes/1000` for the whole `helm upgrade --wait`.

```
REVISION: 3
DESCRIPTION: Upgrade complete
traffic during the operation: 227 requests, 0 non-200
  version=1.1.0  pod=pulse-854ddd6446-kkhsx  responses=4
  version=1.1.0  pod=pulse-854ddd6446-zsmh5  responses=3
```

**Broken image tag**

```
Error: UPGRADE FAILED: resource Deployment/pulse/pulse not ready. status: InProgress, message: Updated: 1/3
context deadline exceeded
traffic during the operation: 819 requests, 0 non-200
pulse-7f5fc7bd59-9hq24   0/1     ErrImagePull   0          59s
pulse-854ddd6446-kkhsx   1/1     Running        0          69s
Events:
  Warning  Failed     14s (x3 over 57s)  kubelet  Failed to pull image "pulse-api:9.9.9-does-not-exist": failed to pull and unpack image "docker.io/library/pulse-api:9.9.9-does-not-exist" ...
  Warning  Failed     3s (x3 over 57s)   kubelet  Error: ImagePullBackOff
$ kubectl -n pulse rollout status deploy/pulse --timeout=5s
Waiting for deployment "pulse" rollout to finish: 1 out of 3 new replicas have been updated...
4  ... failed  ... Upgrade "pulse" failed: resource Deployment/pulse/pulse not ready
```

**Rollback**

```
$ helm rollback pulse 3 -n pulse --wait --timeout 120s
Rollback was a success! Happy Helming!
  version=1.1.0  pod=pulse-854ddd6446-kkhsx  responses=3
```

**Crash-looping configuration**

```
pulse-687fb7b54c-9z576   0/1     CrashLoopBackOff   3 (10s ago)   59s
$ kubectl -n pulse logs pulse-687fb7b54c-9z576 --previous --tail=2
app.config.ConfigError: MAX_PRIME_LIMIT must be an integer, got 'oops'
Warning   Unhealthy   pod/pulse-687fb7b54c-9z576   Startup probe failed: ... connect: connection refused
```

After `helm rollback pulse 3`: `helm test passed` (revision 7, "Rollback to 3").

**Readiness failure on one pod**

```
pulse-854ddd6446-kkhsx   0/1     Running   0          2m45s
pulse-854ddd6446-kkhsx  ready=false
pulse-854ddd6446-xwvq4  ready=true
clear fault: HTTP 200
pulse-854ddd6446-kkhsx   1/1     Running   0          2m58s
```

**Final release history**

```
1  superseded  Install complete
2  superseded  Upgrade complete
3  superseded  Upgrade complete
4  failed      Upgrade "pulse" failed: resource Deployment/pulse/pulse not ready ...
5  superseded  Rollback to 3
6  failed      Upgrade "pulse" failed: resource Deployment/pulse/pulse not ready ...
7  deployed    Rollback to 3
```

## Notes on interpretation

- **The "0 non-200" counts are lab measurements.** They cover one client on localhost, roughly 20 requests per second, through a NodePort. They show that the rollout strategy keeps capacity. They do not guarantee zero errors under production load, with long-lived connections, or across node failures.
- **One shellcheck warning (SC2164) in `demo.sh` was fixed after this run.** The fix changed only the script's own `cd` line, not the lab steps.
