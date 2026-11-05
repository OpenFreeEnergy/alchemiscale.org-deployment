# omsf compute on NRP

GPU compute for `omsf` runs on the [National Research Platform](https://nrp.ai) (NRP) Kubernetes cluster, in a namespace we were granted but don't administer.
Nothing here is deployed by CD: an operator with NRP access applies it by hand.

There are two modes:

| mode | what runs | use it for |
| --- | --- | --- |
| **autoscaled** | an [`alchemiscale-k8s`](https://github.com/datryllic/alchemiscale-k8s) manager that creates one Job per compute service while `omsf` has Tasks waiting, up to `max_compute_services` | normal operation |
| **static** | a fixed set of compute services from [`static-compute.yaml`](static-compute.yaml) | manual tests, or a fallback |

Don't run both in the same namespace. The manager acts on **every** Job in its namespace, including the static ones ([#31](https://github.com/datryllic/alchemiscale-k8s/issues/31)).

| file | what it is |
| --- | --- |
| [`kustomization.yaml`](kustomization.yaml) | namespace, manager image, ConfigMap generation; builds on [`compute/k8s/base`](/compute/k8s/base) |
| [`manager.yaml`](manager.yaml) | manager settings: name, scaling limits, cycle interval |
| [`job-spec.yaml`](job-spec.yaml) | the container the manager runs for each compute service |
| [`service-settings.example.yaml`](service-settings.example.yaml) | compute service settings, without the key |
| [`static-compute.yaml`](static-compute.yaml) | a fixed-size Job, without the manager |

## credentials

The only secret is the compute identity's key. It lives in `service-settings.yaml`, which is gitignored and loaded into the cluster as the `alchemiscale-compute-settings-yaml` Secret.
It never enters git or the kustomization, so `kubectl kustomize` renders without it.

1. Create the compute identity on `omsf` and scope it (see [docs/operations.md](/docs/operations.md)). The key is printed once:

       scripts/identity-add.sh omsf -t compute -i nrp-omsf
       scripts/identity-add-scope.sh omsf -t compute -i nrp-omsf -s '*-*-*'

2. Write the settings and load them:

       cd deployments/omsf/compute/nrp
       cp service-settings.example.yaml service-settings.yaml   # then set `key`
       kubectl -n <namespace> create secret generic alchemiscale-compute-settings-yaml \
         --from-file=service-settings.yaml --dry-run=client -o yaml | kubectl apply -f -

To rotate the key, repeat step 2 and restart the manager. Jobs that are already running keep the old key until they exit.

## static

    kubectl -n <namespace> create -f deployments/omsf/compute/nrp/static-compute.yaml
    kubectl -n <namespace> get jobs,pods -l app=alchemiscale-compute-static
    kubectl -n <namespace> delete jobs -l app=alchemiscale-compute-static

Each pod runs up to `max_tasks` Tasks, then exits. Finished Jobs are removed after a day.

## autoscaled

The manager needs `alchemiscale-k8s` v0.2.0 or later in the `omsf` compute image.
Set `RELEASE_TAG` in [`kustomization.yaml`](kustomization.yaml) and [`job-spec.yaml`](job-spec.yaml) to a release that includes it.
Both use the same image, so keep the two tags in step.

    kubectl kustomize deployments/omsf/compute/nrp            # review
    kubectl apply -k deployments/omsf/compute/nrp
    kubectl -n <namespace> logs -f deploy/alchemiscale-compute-manager

Each cycle (`sleep_interval`), the manager asks the compute API how many Tasks are waiting, clears Jobs that succeeded, and creates up to `max_submit_per_cycle` new ones, never holding more than `max_compute_services`.
Compute services exit after `max_tasks`, so capacity shrinks as the queue drains.

Changing `manager.yaml` or `job-spec.yaml` and reapplying restarts the manager. Already-running Jobs keep the spec they started with.

To stop: `kubectl delete -k deployments/omsf/compute/nrp`, then delete any remaining Jobs.

### when the manager crashloops

The manager refuses to continue while **any** Job in the namespace has failed. That includes evictions and out-of-memory kills, both of which happen on a shared cluster.
Find out why the Job failed, then clear it:

    kubectl -n <namespace> get jobs
    kubectl -n <namespace> describe job <name>
    kubectl -n <namespace> exec deploy/alchemiscale-compute-manager -- \
      /usr/local/bin/_entrypoint.sh alchemiscale-k8s k8s clear-jobs -n <namespace>

If the compute API has marked the manager as errored, clear that too:

    kubectl -n <namespace> exec deploy/alchemiscale-compute-manager -- \
      /usr/local/bin/_entrypoint.sh alchemiscale-k8s manager clear-error \
      -c /mnt/manager/manager.yaml -s /mnt/settings/service-settings.yaml

### limitations

These come from `alchemiscale-k8s` v0.2.0:

- **The manager name is restricted.** It may contain only lowercase letters, digits and dots, and must be 30 characters or fewer; see [`manager.yaml`](manager.yaml) ([#14](https://github.com/datryllic/alchemiscale-k8s/issues/14)).
- **Jobs can't be steered to particular nodes.** Only `containers` and `volumes` are read from `job-spec.yaml`, so Jobs land on whichever GPU node the scheduler picks ([#30](https://github.com/datryllic/alchemiscale-k8s/issues/30)).
- **One failed Job stops scaling** until it is cleared, as described above ([#29](https://github.com/datryllic/alchemiscale-k8s/issues/29)).
