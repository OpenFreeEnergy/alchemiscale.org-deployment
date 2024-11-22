# alchemiscale.org - root deployment

The [`root`](deployments/root) deployment is reachable by users at [https://api.alchemiscale.org](https://api.alchemiscale.org/redoc).
It is also often referred to as `prod` currently, but other instances used for "production" work may also be deployed from this repo over time.

## for users

To use this instance, clone this repository, and switch to the currently-deployed tag:

    $ git clone https://github.com/OpenFreeEnergy/alchemiscale.org-deployment.git
    $ cd alchemiscale.org-deployment
    $ git checkout 2024.11.21-0

Create a conda environment using, e.g. [`micromamba`](https://github.com/mamba-org/micromamba-releases)::

    $ micromamba create -f deployments/root/conda-envs/alchemiscale-client.yml

Once installed, activate the environment::

    $ micromamba activate alchemiscale-client

You may wish to install other packages into this environment, such as `jupyterlab`.
