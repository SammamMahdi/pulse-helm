# Kubernetes troubleshooting runbook

Start broad, then narrow:
1. **Deployment** — `kubectl rollout status`
2. **Pods** — `kubectl get pods -o wide`
3. **One pod** — `kubectl describe pod`, then read the **Events** section
4. **Container** — `kubectl logs`, adding `--previous` after a restart
5. **Service wiring** — EndpointSlices

| Pod status / symptom | Usual cause | Commands | Fix |
|---|---|---|---|
| `ErrImagePull` → `ImagePullBackOff` | Tag or digest does not exist, registry auth missing, image name typo | `kubectl describe pod <p>` (Events: `Failed to pull image ... not found`) | Correct the tag or digest, or grant pull access (AcrPull / `imagePullSecrets`). `helm rollback` to restore service. Reproduced in demo step 6. |
| `ErrImageNeverPull` | `pullPolicy: Never` and the image was not side-loaded into kind | `docker exec pulse-lab-worker crictl images` | `kind load docker-image pulse-api:<tag> --name pulse-lab` |
| `CrashLoopBackOff` | The process exits at startup: bad config, missing env, failing migration | `kubectl logs <p> --previous` (the crashed container's output) | Fix the configuration and roll back. Reproduced in demo step 9: `ConfigError: MAX_PRIME_LIMIT must be an integer` |
| `Running` but `READY 0/1` | Readiness probe failing: dependency down, app not ready, wrong probe path or port | `kubectl describe pod` (`Readiness probe failed: HTTP probe failed with statuscode: 503`); check `kubectl get endpointslices` | Fix the dependency or the probe. The pod is out of the Service but is **not** restarted, because liveness is separate. Reproduced in demo step 11. |
| Restarts increasing, `OOMKilled` | Memory limit too low or a leak | `kubectl describe pod` (Last State: `OOMKilled`, exit 137), `kubectl top pod` | Raise `resources.limits.memory` after measuring, or fix the leak |
| `Pending` | No node has enough requested CPU/memory, or taints/affinity don't match | `kubectl describe pod` (`0/3 nodes are available: insufficient cpu`) | Lower the requests, add nodes, or fix the selectors |
| Service returns nothing / connection refused | Selector does not match the pod labels, or no ready pods | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>`, `kubectl get pods --show-labels` | Align the labels. Note that `targetPort` uses the named port `http`. |
| `helm upgrade` fails with timeout | New ReplicaSet never becomes ready (any of the above) | `helm history`, `kubectl rollout status`, then work down the rows above | `helm rollback <release> <last-good-revision> --wait` |

## Why the broken releases in the demo caused no outage

The Deployment uses `maxUnavailable: 0` and `maxSurge: 1`. Kubernetes starts one new pod and removes an old pod only after the new one is **Ready**. A new pod that can never become ready (bad image, crash loop) stalls the rollout, while the old ReplicaSet keeps serving. The demo measured this with traffic running during each rollout; the counts are in `docs/verification.md`.
