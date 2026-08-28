# continuous deployment

```
PR opened ─────────► static checks (helm lint, golden diff, tofu validate)
PR labelled ───────► build pr-<n> images ─► ensure test cluster ─► helm install into
                     <deployment>-pr-<n> ─► smoke test ─► status + sticky PR comment
PR closed/unlabelled ► helm uninstall + namespace + scratch data
release published ─► detect modified deployments ─► build <calver> images ─►
                     [required review] ─► pre-upgrade EBS snapshot ─► helm upgrade ─► smoke test
```

GitHub Actions authenticates to AWS through OIDC — no long-lived AWS keys in
repository secrets.

## workflows

| workflow | trigger | does |
| --- | --- | --- |
| [`build-images.yml`](../.github/workflows/build-images.yml) | `workflow_call`, `workflow_dispatch` | builds and pushes one deployment's server/compute/fah-compute images; replaces the old `build-*-docker.yml` triplet |
| [`pr-deploy.yml`](../.github/workflows/pr-deploy.yml) | `pull_request` | static checks always; build + deploy for labelled, non-draft, same-repo PRs |
| [`pr-teardown.yml`](../.github/workflows/pr-teardown.yml) | PR `closed` / `unlabeled` | removes the environment, its Pod Identity association, and its scratch data |
| [`release-deploy.yml`](../.github/workflows/release-deploy.yml) | `release: published`, `workflow_dispatch` | production rollout, one deployment at a time, each behind a required review |
| [`test-cluster-lifecycle.yml`](../.github/workflows/test-cluster-lifecycle.yml) | `workflow_call`, `workflow_dispatch`, 6-hourly | applies the test cluster on demand, destroys it when idle |

## PR environments

**Opt-in per PR**: add the `test-deploy` label. Unlabelled PRs run only the
static checks, so pushes cost nothing. Removing the label tears the environment
down without closing the PR.

- Only deployments whose `deployments/<name>/` files changed are deployed; a
  `charts/` change deploys all of them.
- **A directory is deployable only if it has a `values.yaml`** — which is what
  keeps the frozen legacy `root` out of every deploy path, including "chart
  changed, deploy everything".
- A chart- or values-only push **skips the image build** and redeploys the
  existing `pr-<n>` images.
- Rapid pushes cancel superseded runs. Since a cancelled run can strand a
  release in `pending-upgrade`, each deploy recovers any stuck release first and
  runs `helm upgrade --atomic`.
- A spun-down test cluster is brought up first (~20 min, announced on the PR).
- **Fork PRs never deploy** — deploy jobs require a same-repo head, and
  `pull_request_target` is deliberately unused.

No ingress: reach one through the Kubernetes API
([operations.md](operations.md#reaching-a-pr-environment)).

## releases

Publish a release with a CalVer tag (`YYYY.MM.DD-N`). The workflow diffs
`deployments/` and `charts/` since the previous tag, builds images, then per
deployment: waits for approval on the `production-<deployment>` environment,
snapshots that deployment's neo4j volume, `helm upgrade --install --wait` **by
digest**, and runs the read-only smoke test.

Deployments roll out one at a time, so a bad release is caught before it reaches
the rest. A final job opens a PR updating the README's *Deployed Tag* column.

### rollback

```bash
helm rollback <deployment> -n <deployment>          # previous images, immediately
gh workflow run release-deploy.yml \
  -f deployment=<deployment> -f tag=<previous-calver> -f build=false
```

`helm rollback` restores images, not data. alchemiscale version bumps can touch
the neo4j schema and are not always roll-back-safe — hence the pre-upgrade
snapshot and the logical dumps
([operations.md](operations.md#neo4j-dump-and-restore)).

## deploying by digest

Both paths resolve the digest from the registry and deploy
`repository@sha256:…`. Tags are mutable — a force-push reuses `pr-<n>` — so the
tag stays the human-readable label while the digest is what rolls out.

## repository configuration

Actions **variables** (not secrets). Every ARN comes from `tofu
-chdir=infra/opentofu/identity output` — which is why none of this waits on the
production cluster:

| variable | value |
| --- | --- |
| `AWS_REGION` | region both clusters run in (default `us-east-1`) |
| `PROD_CLUSTER` / `TEST_CLUSTER` | cluster names (default `alchemiscale-prod` / `alchemiscale-test`) |
| `AWS_DEPLOY_RELEASE_ROLE` | `deploy_release_role_arn` |
| `AWS_DEPLOY_PR_ROLE` | `deploy_pr_role_arn` |
| `AWS_TEST_INFRA_ROLE` | `test_infra_role_arn` |
| `TEST_SCRATCH_BUCKET` / `TEST_SCRATCH_ROLE_ARN` | `test_scratch_bucket` / `test_scratch_role_arn` |
| `TOFU_STATE_BUCKET` | `state_bucket`, from the bootstrap layer |
| `TEST_ADMIN_PRINCIPAL_ARNS` | JSON list of operator IAM ARNs for the test cluster |

Also needed: a **`test-deploy` label**, and **environments**
`production-omsf` and `production-openadmet` with required reviewers. Those environments are the production gate — the release role's trust
policy only accepts tokens carrying one of their claims, so without them nothing
can deploy to production at all.

No repository secrets are needed beyond the built-in `GITHUB_TOKEN`.

## what each role can reach

| role | trusted from | reach |
| --- | --- | --- |
| `alchemiscale-deploy-release` | runs bound to a `production-*` environment | prod cluster namespaces; EBS snapshots |
| `alchemiscale-deploy-pr` | `pull_request` runs and `main` | test cluster only — **no access entry on prod at all** — plus the scratch bucket |
| `alchemiscale-test-infra` | the lifecycle workflow file | apply/destroy of the test stack, inside a permissions boundary denying anything tagged `cluster=prod` — plus the backups bucket by name, since S3 does not evaluate that tag |

All three are declared in [`infra/opentofu/identity/`](../infra/opentofu/identity),
applied before either cluster and destroyed by neither.
