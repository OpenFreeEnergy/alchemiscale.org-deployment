# alchemiscale.org - omsf deployment

The [`omsf`](/deployments/omsf) deployment is reachable by users at [https://api.omsf.alchemiscale.org](https://api.omsf.alchemiscale.org/redoc).

`omsf` succeeds the `root` deployment (`https://api.alchemiscale.org`), which runs in parallel for three months from the `omsf` availability announcement and is then retired.
It starts with a fresh database and object-store prefix: finish or retrieve in-flight work on `root`, and start new work here.
Access requires an identity on `omsf` — these are **not** copied from `root`, so ask an administrator to register yours.

## environment installation instructions for users

To use this deployed instance, first clone this repository:

    $ git clone https://github.com/OpenFreeEnergy/alchemiscale.org-deployment.git
    $ cd alchemiscale.org-deployment

Switch to the *Deployed Tag* listed for the `omsf` deployment in the table [here](/README.md).

    $ git checkout <deployed-tag>

Create a conda environment using, e.g. [`micromamba`](https://github.com/mamba-org/micromamba-releases)::

    $ micromamba create -f deployments/omsf/conda-envs/alchemiscale-client.yml

Once installed, activate the environment::

    $ micromamba activate alchemiscale-client

You may wish to install other packages into this environment, such as `jupyterlab`.

See the [`alchemiscale` User Guide](https://docs.alchemiscale.org/en/stable/user_guide/index.html) for further details on how to connect and interact with the deployment.
