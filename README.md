## Documentation

[Follow the link](docs/README.md)

## Running

On Linux:

```bash
# go to tools directory
cd tools

# initially, install all the needed repositories
bash install.sh

# start the control plane (idempotent: safe to re-run, works on old volumes)
./start.sh

# stop it, keeping all state; --clean also deletes volumes (fresh start)
./stop.sh
./stop.sh --clean
```

`start.sh` waits for Scylla and applies the schema, makes sure vault is
unsealed, creates the test user (`C12S_USER`/`C12S_PASS`/`C12S_ORG`, default
`e2e`/`testpass123`/`c12s`), and re-uploads local `edge-base` images and
provisioning disks (`~/.wormhole/images`) if the registry or artifact server
lost them. `NODES_NUM=N ./start.sh` additionally starts N Docker star nodes
(not bootc-capable; default 0).

bootc nodes and experiments: `bootc/README.md`, `experiments/` (start with
`./setup-fleet.sh 2`), and `../plan/handoff-phase5.md` for the lab layout.

On MacOS:

```bash
# go to tools directory
cd tools

brew install findutils

# initially, install all the needed repositories
bash install.sh

# to start both the control plane and node agents
bash start.sh

# to stop both the control plane and node agents
bash stop.sh
```

On Windows, using [git bash](https://git-scm.com/downloads):

```bash
# go to tools directory
cd tools

# initially, install all the needed repositories
bash install.sh

# to start both the control plane and node agents
bash start-windows.sh

# to stop both the control plane and node agents
bash stop.sh
```
