# Solution: probe-misconfigured

## What happened

A refactor renamed {{.WorkloadName}}'s readiness probe path from `/ready` to
`/healthz`. The app does not serve `/healthz`, so every probe gets a 404.
Kubernetes never restarts anything for a failed readiness probe - it just
marks the pod Not Ready and removes it from the Service's endpoints. The app
is healthy the whole time: it never crashes, never restarts, and its own logs
show nothing wrong.

With no ready endpoints, the Service has nowhere to send traffic: every
request through the ingress fails, while `kubectl get pods` looks completely
fine.

## How this differs from liveness-probe-kill

Same mistake - a probe path renamed to one the app never serves - with a
different consequence, because a readiness probe and a liveness probe fail in
different ways:

| | liveness-probe-kill | probe-misconfigured |
|---|---|---|
| Kubernetes' response | restarts the container | marks the pod Not Ready, nothing else |
| Pod's RESTARTS count | climbing | stays at 0 |
| Where to look first | `kubectl describe pod` → Last State | `kubectl get pods` → READY column |

## Diagnosis path

```bash
kubectl get pods -n {{.WorkloadNamespace}}                  # Running, 0 restarts, READY 0/1
kubectl describe pod -n {{.WorkloadNamespace}} <pod>
# Readiness:  http-get http://:http/healthz delay=10s timeout=3s period=5s #success=1 #failure=3
# Events:
#   Warning  Unhealthy  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
kubectl get endpoints {{.WorkloadName}} -n {{.WorkloadNamespace}}   # <none>
```

## Fix

```bash
kubectl -n {{.WorkloadNamespace}} patch deploy {{.WorkloadName}} --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/ready"}]'
kubectl -n {{.WorkloadNamespace}} rollout status deploy/{{.WorkloadName}}
```

`kubectl -n {{.WorkloadNamespace}} rollout undo deploy/{{.WorkloadName}}` works
too, and so does re-applying the app's chart (`labctl app deploy
{{.WorkloadName}}`), which puts back the probe the chart defines.

Verify: `labctl incident status`. The check asks the probe's path on a running
pod, the way the kubelet does, and passes once it answers and every replica is
ready.

## The tempting wrong fix

Deleting the readiness probe entirely. Without one, Kubernetes marks the pod
Ready as soon as it starts, so the Service gets its endpoints back and the
symptom disappears immediately - but nothing is checking real readiness any
more. The next time this app genuinely is not ready (a slow dependency on
startup, say), traffic goes to it anyway. The detection check rejects this on
purpose: it fails outright if no readiness probe exists at all.

## Real-world parallel

Probe paths drift during refactors just like this one, usually silently: a
health-endpoint rename that updates the app and forgets the Deployment, or a
shared Helm values file edited for one app that quietly changes another's.
Because a failed readiness probe produces no crash, no restart and no error
log, it is one of the easiest production incidents to leave undiagnosed for a
long time - the only fingerprint is a pod that is Running but never Ready, and
endpoints that stay empty.
