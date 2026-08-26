# alchemiscale.org - deployment

This repo contains deployment configurations and artifact generation machinery for [alchemiscale](https://github.com/OpenFreeEnergy/alchemiscale) instances hosted under [alchemiscale.org](https://alchemiscale.org/).

Instances run on Amazon EKS and are deployed continuously: pull requests build images and stand up throwaway test environments, and publishing a release rolls the modified instances out to production behind a review gate.

| doc | answers |
| --- | --- |
| [docs/quickstart.md](docs/quickstart.md) | stand it up, try it, tear it down — start here |
| [docs/continuous-deployment.md](docs/continuous-deployment.md) | how PRs and releases deploy; what to configure in the repository |
| [docs/infrastructure.md](docs/infrastructure.md) | clusters, AWS account model, setup, upgrades, cost |
| [docs/operations.md](docs/operations.md) | identities, neo4j dumps, reaching PR environments, monitoring |
| [docs/migration.md](docs/migration.md) | phases and cutover runbooks for the EC2 instances |
| [charts/alchemiscale/README.md](charts/alchemiscale/README.md) | the chart, mapped onto the old compose stack |

## organization

Each deployment under [`deployments`](deployments) carries its own conda environments, Dockerfiles, and chart values — so instances can experiment freely as their needs differ.

| path | what it is |
| --- | --- |
| [`deployments/`](deployments) | per-instance conda environments, Dockerfiles, and chart values |
| [`charts/alchemiscale/`](charts/alchemiscale) | the Helm chart every instance is deployed from |
| [`infra/opentofu/`](infra/opentofu) | the EKS clusters and their supporting AWS resources |
| [`scripts/`](scripts) | operator tooling: identities, neo4j dump/restore |
| [`.github/workflows/`](.github/workflows) | image builds, PR environments, release deployment |

Click a deployment name for its details and client setup instructions.

| Deployment                           | Deployed Tag | API URI                              | Description                                                                                 |
| ------------------------------------ | ------------ | ------------------------------------ | ------------------------------------------------------------------------------------------- |
| [`omsf`](deployments/omsf)           | —            | https://api.omsf.alchemiscale.org      | production use, with a combination of HPC, Kubernetes, and Folding@Home compute provisioned |
| [`asap`](deployments/asap)           | 2026.04.09-0 | https://api.asap.alchemiscale.org      | ASAP Discovery production use, with HPC compute provisioned. Runs on its own host; **not deployed by this repo's automation** |
| [`openadmet`](deployments/openadmet) | —            | https://api.openadmet.alchemiscale.org | OpenADMET production use                                                                    |
| [`root`](deployments/root)           | 2026.02.06-0 | https://api.alchemiscale.org           | **deprecated** — succeeded by `omsf`; frozen, retired at the end of the parallel-run window |

### `root` is being retired

`root` (`https://api.alchemiscale.org`) is succeeded by **`omsf`** (`https://api.omsf.alchemiscale.org`). The two run in parallel for **three months** from the `omsf` availability announcement, then `root` is decommissioned.

- `omsf` starts with a **fresh database and a new S3 prefix**. Finish or retrieve work in progress on `root`; start new work on `omsf`.
- **Identities are not copied over** — ask an administrator to register yours on `omsf`.
- Compute services attached to `root` (HPC, Folding@Home) need repointing during the window.
- `root` stays frozen on its EC2 host in the legacy AWS account. Its configuration remains in [`deployments/root`](deployments/root) for its operators, but has no chart values, so CD cannot deploy it. The directory goes when the host does.

## deploying

Nothing is deployed by hand. A release with a CalVer tag (`YYYY.MM.DD-N`) builds images for whichever instances changed and deploys them one at a time, each behind a GitHub Environment with required reviewers.

To exercise a change first, label the pull request `test-deploy`: it is deployed into a throwaway namespace on the test cluster, smoke tested, and torn down when the label is removed or the PR closes.
