# Hints: probe-misconfigured

## Hint 1
Every pod is Running, with zero restarts - this is not a crash. Check whether
the pods are actually marked ready: `kubectl get pods -n {{.WorkloadNamespace}}`
and look at the READY column. If it never reaches 1/1, something is stopping
Kubernetes from calling the pod healthy, even though it is alive.

## Hint 2
`kubectl describe pod -n {{.WorkloadNamespace}} <pod>` and read its Events at
the bottom. A line like `Readiness probe failed: HTTP probe failed with
statuscode: 404` means Kubernetes asked the app a question and got "not found"
back - the app answered, just not with what was expected.

## Hint 3
Compare the path in the Deployment's readiness probe
(`kubectl get deploy {{.WorkloadName}} -n {{.WorkloadNamespace}} -o yaml`, under
`readinessProbe.httpGet.path`) against the path the app really serves.

Fix the **path**, not the probe itself. Deleting the readiness probe makes
Kubernetes mark the pod ready immediately, which clears the symptom without
fixing anything - the next real problem has nothing checking for it.
