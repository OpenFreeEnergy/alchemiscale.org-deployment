# alchemiscale.org - root deployment (frozen, being retired)

> **Frozen and being retired**, succeeded by [`omsf`](/deployments/omsf) at
> [api.omsf.alchemiscale.org](https://api.omsf.alchemiscale.org/redoc). The two run in parallel for
> **three months** from the `omsf` availability announcement; then this host is decommissioned and
> this directory deleted.
>
> **Users:** finish or retrieve in-flight work here, start new work on `omsf`, and ask an
> administrator for an identity there — they are not copied across. Compute services need
> repointing within the window.
>
> **Operators:** these files are the live configuration of the EC2 stack, kept on `main` for the
> window so you have it to hand. Nothing deploys them — `root` has no chart values and no
> namespace, which is what keeps it out of every deploy path — so treat any change here as a
> mistake. Images remain buildable by hand through `build-images.yml`; building one deploys
> nothing.
> See [docs/migration.md](/docs/migration.md) for the retirement sequence.

The [`root`](/deployments/root) deployment is reachable by users at [https://api.alchemiscale.org](https://api.alchemiscale.org/redoc).

## environment installation instructions for users

To use this deployed instance, first clone this repository, and switch to the currently-deployed tag:

    $ git clone https://github.com/OpenFreeEnergy/alchemiscale.org-deployment.git
    $ cd alchemiscale.org-deployment
    $ git checkout 2026.02.06-0

Create a conda environment using, e.g. [`micromamba`](https://github.com/mamba-org/micromamba-releases)::

    $ micromamba create -f deployments/root/conda-envs/alchemiscale-client.yml

Once installed, activate the environment::

    $ micromamba activate alchemiscale-client

You may wish to install other packages into this environment, such as `jupyterlab`.

See the [`alchemiscale` User Guide](https://docs.alchemiscale.org/en/stable/user_guide/index.html) for further details on how to connect and interact with the deployment.
