# alchemiscale.org - deployment

This repo contains deployment configurations and artifact generation machinery for [alchemiscale](https://github.com/OpenFreeEnergy/alchemiscale) instances hosted under [alchemiscale.org](https://alchemiscale.org/).


## organization

Deployments are listed under [`deployments`](deployments), with each deployment having its own environment files for `client`, `server`, `compute`, etc.
Each deployment also features its own Dockerfiles, allowing deployments to experiment more freely as needed to accommodate different needs.

### root

The `root` deployment is reachable by users at https://api.alchemiscale.org.
It is also often referred to as `prod` currently, but other instances used for "production" work may also be deployed from this repo over time.
