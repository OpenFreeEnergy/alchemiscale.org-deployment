# operations

Day-to-day administration. Everything here needs an admin EKS access entry,
declared via `admin_principal_arns`.

```bash
aws eks update-kubeconfig --name alchemiscale-prod
kubectl get pods -n omsf
```

Chart names are fixed — one release per namespace — so
`deploy/alchemiscale-client-api`, `deploy/alchemiscale-compute-api`,
`deploy/alchemiscale-strategist`, and `statefulset/alchemiscale-neo4j` mean the
same thing in every namespace on either cluster.

## identities and scopes

neo4j is never exposed outside its namespace, so `alchemiscale identity add`
runs *inside* the cluster. These wrappers resolve the namespace and run it:

```bash
scripts/identity-add.sh omsf -t user -i alice                   # generates and prints a key
scripts/identity-add.sh omsf -t compute -i folding-at-home-1 -k "$KEY"
scripts/identity-add-scope.sh omsf -t user -i alice -s openfe-demo-project -s openfe-demo-other
```

Retarget at a PR environment with `-c test -n <deployment>-pr-<n>`.

**`kubectl exec` argument lists appear in the EKS audit log**, so a key passed
with `-k` lands there. Acceptable for an internal audit log, but let the script
generate keys rather than choosing memorable ones, and rotate by re-running
`identity add` if one is mishandled.

There is deliberately no workflow-based path for this: every operator holds an
admin access entry anyway, and the audit log records each exec with its caller.

## neo4j dump and restore

| mechanism | for | how |
| --- | --- | --- |
| logical dumps | portability — migrations, archives, version-crossing upgrades | `scripts/neo4j-dump.sh` |
| scheduled EBS snapshots | steady-state backup | DLM policy, daily, automatic |
| pre-upgrade EBS snapshot | rollback of a release | taken by `release-deploy.yml` |

```bash
scripts/neo4j-dump.sh omsf -b alchemiscale-backups-000000000000
scripts/neo4j-restore.sh openadmet s3://alchemiscale-backups-000000000000/openadmet/20260817T090000Z.dump
```

Both open a short maintenance window — `neo4j-admin database dump` needs the
database offline and the volume is ReadWriteOnce, so neo4j scales to zero, a Job
runs against the released volume, and neo4j scales back up. The APIs error for
the duration; keep it to minutes, as on EC2 today. Both prompt before they start
— restore wants the deployment name typed back — so neither can be dropped into
a script or a CI job unattended.

The dump is staged on the node's ephemeral storage before upload. If a database
outgrows that, raise `nodeClass.ephemeralStorage.size` in the cluster module.

Restoring from an **EBS snapshot** is the manual DR path: create a volume from
it, point a PV at it, bind the PVC. For routine rollback prefer `helm rollback`
for images and a dump for data.

## reaching a PR environment

No ingress, by design. Needs the `test-deploy` label, a completed deploy, and an
admin access entry on the test cluster.

```bash
aws eks update-kubeconfig --name alchemiscale-test
kubectl -n <deployment>-pr-<n> port-forward svc/alchemiscale-client-api 1840:1840 &
```

Point a client at `http://localhost:1840` — plain HTTP on localhost is fine, the
tunnel rides the authenticated kubeconfig connection. Closer to what CI sees:

```bash
kubectl -n <deployment>-pr-<n> run -it --rm debug \
  --image=ghcr.io/openfreeenergy/alchemiscale.org-<deployment>-server:pr-<n> \
  --command -- bash
# inside: a client against http://alchemiscale-client-api:1840
```

Credentials are generated per environment, so mint your own identity there:

```bash
scripts/identity-add.sh <deployment> -c test -n <deployment>-pr-<n> -t user -i debug
scripts/identity-add-scope.sh <deployment> -c test -n <deployment>-pr-<n> -t user -i debug -s '*-*-*'
```

## destroying a cluster

OpenTofu's state holds the cluster, the VPC, and the handful of Helm releases it
installed itself. It knows nothing about `alchemiscale` releases — CD or an
operator put those there. Destroying the control plane takes etcd with it, so
every remaining release, PVC, and Ingress stops existing as a Kubernetes object
without any `helm uninstall`, hook, or finalizer running.

Their AWS counterparts do not stop existing. Drain first, in this order:

```bash
helm uninstall <release> -n <namespace>   # every alchemiscale release
kubectl delete namespace <namespace>      # ← this is what deletes the PVCs
kubectl get ingress,svc -A                # nothing type=LoadBalancer may remain
tofu destroy
```

The middle step carries more weight than it looks. **`helm uninstall` does not
delete StatefulSet PVCs** — Kubernetes never reclaims `volumeClaimTemplates`
automatically — and `reclaimPolicy: Delete` only fires when a PVC is deleted in a
*live* cluster, because the CSI controller is what acts on it. Destroy the
cluster outright and the EBS volumes are orphaned whatever the policy says.
`test-cluster-lifecycle.yml` sweeps namespaces before it destroys for exactly
this reason.

On **test** that is the whole story: no ingress, so no load balancers, and the
cost of getting it wrong is a few abandoned 5 GiB volumes.

On **prod** it is worse in three ways, and the first bites during the destroy:

- **The ALB blocks the VPC.** Auto Mode created it from the chart's Ingress and
  the cluster deletion does not remove it. Its ENIs sit in the subnets and its
  security groups reference yours, so subnet and security-group deletion fails
  with `DependencyViolation` — leaving a half-destroyed stack.
- **Orphaned volumes hold production data.** `reclaimPolicy: Retain` is
  deliberate, but they survive as anonymous volumes with no PV to say what they
  were. Label them before that matters.
- **DNS goes stale.** ExternalDNS runs `policy: upsert-only` and never deletes,
  so the hostnames keep resolving to a load balancer that is gone.

Afterwards, check for survivors: unattached EBS volumes, load balancers, ENIs,
and the NAT gateway and its Elastic IP.

## monitoring

All CloudWatch; no self-hosted stack.

| signal | where |
| --- | --- |
| is it up, from outside AWS | Route53 health checks on `api.<domain>/ping` and `compute.<domain>/ping` |
| pods, nodes, restarts | Container Insights |
| container logs | the `alchemiscale` log group, one stream per container, namespace-prefixed |
| neo4j disk | `alchemiscale/neo4j_data_used_percent`, from a sidecar in the neo4j pod; alarms above 80% |
| everything else | the `alchemiscale-<deployment>` dashboard |

Alarms route to the `alchemiscale-alerts` SNS topic. The one that matters most
is the Route53 health check — it exercises the full user path and keeps working
when the cluster does not. `log ingestion stopped` matters too: no logs looks
exactly like no problems.

Health checks are only created for deployments marked `live` in the
`deployments` map, since a check against a hostname that does not resolve yet
alarms immediately.

## common situations

**A PR environment will not come up.** The deploy job dumps events, pod
descriptions, and logs on failure. Usually a pod stuck `Pending` with no node
yet, or a smoke test that beat the database to readiness.

**A release is stuck.** `helm upgrade --wait` timing out leaves
`pending-upgrade`; `helm rollback <deployment> -n <deployment>` clears it.

**Drift.** Push-based CD, not GitOps: a `kubectl edit` is not reverted
automatically. Treat manual cluster changes as emergencies to back-port the same
day.

**A node is being reclaimed under a database.** It should not be — the neo4j pod
carries `karpenter.sh/do-not-disrupt: "true"`. On the built-in Auto Mode node
pool both clusters run, that annotation is the whole of the protection: the
disruption budgets in `prod/main.tf` configure the module's own NodePool, which
is not the one in use ([node pools](infrastructure.md#node-pools)). If it happens
anyway, check the annotation survived the last chart change.
