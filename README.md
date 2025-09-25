# alchemiscale.org - deployment

This repo contains deployment configurations and artifact generation machinery for [alchemiscale](https://github.com/OpenFreeEnergy/alchemiscale) instances hosted under [alchemiscale.org](https://alchemiscale.org/).

## organization

Deployments are listed under [`deployments`](deployments), with each deployment having its own environment files for `client`, `server`, `compute`, etc.
Each deployment also features its own Dockerfiles, allowing deployments to experiment more freely as needed to accommodate different needs.

Looking for more details on a particular deployment?
Click on the deployment name in the table below.

| Deployment                 | Deployed Tag | API URI                           | Description                                                                                   |
| -------------------------- | ------------ | --------------------------------- | --------------------------------------------------------------------------------------------- |
| [`root`](deployments/root) | 2025.09.22-0 | https://api.alchemiscale.org      | production use, with a combination of HPC, Kubernetes, and Folding@Home compute provisioned   |
| [`asap`](deployments/asap) | 2025.04.29-0 | https://api.asap.alchemiscale.org | ASAP Discovery production use, with HPC compute provisioned                                   |
