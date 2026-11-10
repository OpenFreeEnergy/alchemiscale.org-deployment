# omsf compute on NRP

GPU compute for `omsf` runs on the [National Research Platform](https://nrp.ai) (NRP) Kubernetes cluster, in the `choderalab` namespace.
We don't administer that namespace, and it also holds other groups' and instances' workloads, so every resource here is prefixed `omsf-` and labeled `app.kubernetes.io/instance=omsf`.
Nothing here is deployed by CD: an operator with NRP access applies it by hand.

There are two modes:

| mode | what runs | use it for |
| --- | --- | --- |
| **autoscaled** | an [`alchemiscale-k8s`](https://github.com/datryllic/alchemiscale-k8s) manager that creates one Job per compute service while `omsf` has Tasks waiting, up to `max_compute_services` | normal operation |
| **static** | a fixed set of compute services from [`static-compute.yaml`](static-compute.yaml) | manual tests, or a fallback |

The two can run side by side: the manager only acts on Jobs labeled `k8s.alchemiscale.org/compute-manager=nrp.omsf`, which it creates itself.

| file | what it is |
| --- | --- |
| [`kustomization.yaml`](kustomization.yaml) | namespace, manager image, ConfigMap generation; builds on [`compute/k8s/base`](/compute/k8s/base) |
| [`manager-settings.yaml`](manager-settings.yaml) | manager settings: name, scaling limits, cycle interval |
| [`job-spec.yaml`](job-spec.yaml) | the Job template the manager creates for each compute service |
| [`service-settings.example.yaml`](service-settings.example.yaml) | compute service settings, without the key |
| [`static-compute.yaml`](static-compute.yaml) | a fixed-size Job, without the manager |

## credentials

The only secret is the compute identity's key. It lives in `service-settings.yaml`, which is gitignored and loaded into the cluster as the `omsf-alchemiscale-compute-service-settings` Secret.
It never enters git or the kustomization, so `kubectl kustomize` renders without it.

1. Create the compute identity on `omsf` and scope it (see [docs/operations.md](/docs/operations.md)). The key is printed once:

       scripts/identity-add.sh omsf -t compute -i nrp-omsf
       scripts/identity-add-scope.sh omsf -t compute -i nrp-omsf -s '*-*-*'

2. Write the settings and load them:

       cd deployments/omsf/compute/nrp
       cp service-settings.example.yaml service-settings.yaml   # then set `key`
       kubectl -n choderalab create secret generic omsf-alchemiscale-compute-service-settings \
         --from-file=service-settings.yaml --dry-run=client -o yaml | kubectl apply -f -

### rotating the key

Compute services and the manager read the key once, at startup, and use it again whenever their token expires (after 30 minutes, the chart's `jwt.expireSeconds`).
Re-running `identity add` for an existing identity overwrites its key. After that, each running service fails at its next token refresh, usually while uploading a finished Task's result, and that Task's work is lost.
The Tasks it had claimed return to `waiting` once its registration expires.

For a planned rotation, switch to a new identity and let the old one drain:

1. Create and scope a new identity, e.g. `nrp-omsf-2`, as in step 1 above.
2. Set its `identifier` and `key` in `service-settings.yaml`, reload the Secret as in step 2, then restart the manager:

       kubectl -n choderalab rollout restart deploy/omsf-alchemiscale-compute-manager

   Jobs created from then on use the new identity; running ones keep the old one.
3. Once the older Jobs have finished, remove the old identity. There is no wrapper script for this, so run the CLI the way the wrappers do:

       kubectl -n omsf exec deploy/alchemiscale-client-api -c client-api -- \
         /usr/local/bin/_entrypoint.sh alchemiscale identity remove -t compute -i nrp-omsf

If the key is compromised, cut it off at once: overwrite it with `scripts/identity-add.sh`, reload the Secret, restart the manager, and delete the running Jobs, static ones included. Their work is lost either way.

    kubectl -n choderalab delete jobs -l k8s.alchemiscale.org/compute-manager=nrp.omsf
    kubectl -n choderalab delete jobs -l app=alchemiscale-compute-static,app.kubernetes.io/instance=omsf

## static

    kubectl -n choderalab create -f deployments/omsf/compute/nrp/static-compute.yaml
    kubectl -n choderalab get jobs,pods -l app=alchemiscale-compute-static,app.kubernetes.io/instance=omsf
    kubectl -n choderalab delete jobs -l app=alchemiscale-compute-static,app.kubernetes.io/instance=omsf

Each pod runs up to `max_tasks` Tasks, then exits. Finished Jobs are removed after a day.

## autoscaled

The manager needs `alchemiscale-k8s` v0.3.0 or later in the `omsf` compute image.
The image tag appears in [`kustomization.yaml`](kustomization.yaml), [`job-spec.yaml`](job-spec.yaml) and [`static-compute.yaml`](static-compute.yaml); keep all three in step.

    kubectl kustomize deployments/omsf/compute/nrp            # review
    kubectl apply -k deployments/omsf/compute/nrp
    kubectl -n choderalab logs -f deploy/omsf-alchemiscale-compute-manager

Each cycle (`sleep_interval`), the manager asks the compute API how many Tasks are waiting, clears Jobs that succeeded, and creates up to `max_submit_per_cycle` new ones, never holding more than `max_compute_services`.
Compute services exit after `max_tasks`, so capacity shrinks as the queue drains.

Changing `manager-settings.yaml` or `job-spec.yaml` and reapplying restarts the manager. Already-running Jobs keep the spec they started with.

To stop: `kubectl delete -k deployments/omsf/compute/nrp`, then delete any remaining Jobs.

### failed Jobs

Evictions, preemptions and out-of-memory kills are routine on a shared cluster.
The manager logs each failed Job with its pod's termination reason, deletes it, and carries on.
It stops only if failed Jobs turn up in more than `max_consecutive_failed_cycles` consecutive cycles that create compute services, which usually means a bad image, Job spec or settings.
Fix the cause, then clear the remaining failed Jobs and restart the manager:

    kubectl -n choderalab get jobs -l k8s.alchemiscale.org/compute-manager=nrp.omsf
    kubectl -n choderalab describe job <name>
    kubectl -n choderalab exec deploy/omsf-alchemiscale-compute-manager -- \
      /usr/local/bin/_entrypoint.sh alchemiscale-k8s k8s clear-jobs \
      --namespace choderalab --manager-name nrp.omsf
    kubectl -n choderalab rollout restart deploy/omsf-alchemiscale-compute-manager

If the compute API has marked the manager as errored, clear that too:

    kubectl -n choderalab exec deploy/omsf-alchemiscale-compute-manager -- \
      /usr/local/bin/_entrypoint.sh alchemiscale-k8s manager clear-error \
      -c /mnt/manager-config/manager-settings.yaml -s /mnt/service-settings/service-settings.yaml
