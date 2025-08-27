# alchemiscale.org - asap deployment

The [`asap`](deployments/asap) deployment is reachable by users at [https://api.asap.alchemiscale.org](https://api.asap.alchemiscale.org/redoc).

## environment installation instructions for users

To use this deployed instance, first clone this repository:

    $ git clone https://github.com/OpenFreeEnergy/alchemiscale.org-deployment.git
    $ cd alchemiscale.org-deployment

Create a conda environment using, e.g. [`micromamba`](https://github.com/mamba-org/micromamba-releases)::

    $ micromamba create -f deployments/asap/conda-envs/alchemiscale-client.yml

Once installed, activate the environment::

    $ micromamba activate alchemiscale-client

You may wish to install other packages into this environment, such as `jupyterlab`.

See the [`alchemiscale` User Guide](https://docs.alchemiscale.org/en/latest/user_guide.html) for further details on how to connect and interact with the deployment.
