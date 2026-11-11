# tools — c12s lab orchestration

Everything about *running* c12s on one machine lives here: the Docker
Compose control plane, start/stop scripts, the node OS image artifacts
(`bootc/`), the bootc fleet + update experiments (`experiments/`), and the
corrected operator/API reference (`docs/README.md`). No service code lives in
this repository; the build contexts are the sibling repos of the workspace.

## Role in c12s

| Part | Serves |
|---|---|
| `docker-compose.yml` | the full lab stack: control plane + registry/artifacts + build service + metrics |
| `start.sh` / `stop.sh` | idempotent bring-up / shutdown (schema, vault, test user, image re-seeding) |
| `experiments/` | `setup-fleet.sh` and E1–E7 thesis experiments (see `plan/`) |
| `bootc/` | Containerfiles + greenboot checks that go **into** the node OS image |
| `docs/README.md` | corrected API/CLI reference (the old docs were wrong in places) |
| `vault/`, `scylla/`, `grafana/` | local infra images/config for the stack |

Compose service → source repo (build context is the workspace root):

| Container | Repo / image | Purpose |
|---|---|---|
| `magnetar`, `oort`, `kuiper`, `quasar`, `apollo`, `meridian`, `pulsar` | same-named repos | control plane services |
| `agent_queue` | `gravity` | node delivery (config/join/app-config/OS updates) |
| `lunar-gateway` | `lunar-gateway` | HTTP API on `:5555` |
| `rate_limiter_service` + `consul` | `heliosphere` | per-user/method rate limiting |
| `etcd`, `kuiper_etcd`, `quasar_etcd`, `scylla`, `vault`, `nats` | upstream images (Scylla via `scylla/Dockerfile`) | datastores/broker |
| `protostar_healthcheck`, `protostar_metrics` | `protostar` | node metric ingestion |
| `singularity` | upstream Zot image (`singularity/config/zot-config.json`) | OCI registry `:5001` |
| `singularity-files` | `singularity` | qcow2/artifact server `:8081` |
| `supernova` | `supernova` | gRPC image + qcow2 build service (`127.0.0.1:8090`); reached by the gateway as `supernova:8090` |
| `node_exporter`, `cadvisor`, `prometheus_healthcheck`, grafana | upstream | metrics |

## Running

```bash
cd tools

bash install.sh     # first time: clones missing repos (see bugs — stale list)
./start.sh          # control plane; idempotent, safe on old volumes
./stop.sh           # stop, keep state (volumes)
./stop.sh --clean   # also wipe volumes + dockerized node ids (fresh start)
```

`start.sh` is safe to re-run and performs, in order:

1. build (unless `--no-build`) + `docker compose up -d` (uses `docker-compose.yml`);
2. wait for Scylla and apply `scylla/create_schema_scylla.cql`;
3. wait for Apollo to initialize/unseal Vault (keys in `vault/api_key.json`);
4. ensure the test user exists and can log in —
   `e2e` / `testpass123` / org `c12s`, overridable via `C12S_USER`, `C12S_PASS`,
   `C12S_ORG`;
5. re-seed the provisioning disks (`~/.wormhole/images/edge-base-*.qcow2`,
   overridable via `QCOW2_DIR`) into the artifact server and local
   `edge-base` tags into the registry if a previous `stop.sh --clean` wiped
   them;
6. start Grafana (`localhost:3000`) and, if `NODES_NUM > 0`, N dockerized
   star/starometry node pairs.

`--no-build` skips the image builds and is the fast path after a host reboot;
`--build` overrides `C12S_NO_BUILD=1`. If no images exist yet, run without
`--no-build` once.

Endpoints after start: gateway `localhost:5555`, registry
`localhost:5001`, artifacts `localhost:8081`, Supernova `127.0.0.1:8090`.

`stop.sh` keeps all volumes (etcd nodes, users, vault, registry images,
artifacts) and removes dockerized nodes + Grafana; `--clean` additionally does
`docker compose down -v` and removes `nodeconfig/`. **Libvirt VMs (wormhole)
are left running** — edge nodes outlive the control plane.

### Local binaries (no system install)

`install-local.sh` builds the c12s binaries into one folder (default
`tools/bin/`) and writes `<bin-dir>/activate.sh`. Nothing is written to
`/usr/local/bin`, `/etc/profile`, or `~/.bashrc`:

```bash
./install-local.sh                 # cockpit, star, starometry, protostar, wormhole
./install-local.sh --all           # also lunar-gateway, magnetar, oort, apollo, ...
./install-local.sh --bin-dir ~/c12s-bin
source tools/bin/activate.sh       # or: source ~/c12s-bin/activate.sh
```

The activation script adds the folder to `PATH` for the current shell only.
Use `activate.sh` for bash/zsh and `activate.fish` for fish (fish cannot source
the bash `case` syntax). It also wraps `cockpit` so it runs from the cockpit
repo (the binary reads `.env` and `token.txt` from its current directory).
The built binaries are plain ELF files; `bin/` is git-ignored. The observability
binaries (`starometry`, `health-check`, `node-metrics`,
`cluster-metrics-subscriber`) are useful for running the stack outside Compose;
they still expect the environment variables described in the service READMEs.

### Lifecycle and reboot behavior

`docker compose` is a CLI, not a daemon: after `up -d` returns, Docker owns
the containers. There is deliberately **no systemd unit** for the lab stack;
boot recovery relies on Docker's per-container restart policy.

Every long-running service in `docker-compose.yml` uses
`restart: unless-stopped` (Grafana, started by `start.sh` outside Compose, uses
the same policy). After a host reboot or a Docker daemon restart, Docker
restarts the whole stack automatically. Consequences:

- `docker compose stop` / `docker stop` marks a container stopped;
  `unless-stopped` intentionally does **not** bring it back.
- `docker compose down` removes containers (this is what `stop.sh` does);
  `./start.sh --no-build` recreates them.
- Startup order is not guaranteed on Docker restore. `lunar-gateway` retries
  each backend until it is reachable, for up to `GATEWAY_STARTUP_TIMEOUT`
  (default `5m`), instead of panicking when a dependency is still booting.
- Vault is unsealed by Apollo on startup. If the Vault volume and
  `vault/api_key.json` do not match, automatic recovery cannot work; restore
  the matching key or use `./stop.sh --clean`.
- `./start.sh --no-build` remains the idempotent repair path: it waits for
  Scylla, re-applies the schema, checks Vault, recreates the test user, and
  re-seeds artifacts/images. Running it after a reboot is harmless and does
  not rebuild images.
- `--no-build` still fails if an image is missing. Use a normal
  `./start.sh` (or `./start.sh --build`) after changing service code.

> The Vault data volume and `vault/api_key.json` are a pair: if they do not
> match, the stack cannot unseal Vault. Restore the `api_key.json` written
> when the volume was initialized, or start over with `./stop.sh --clean`.

### Lab fleet and experiments

```bash
cd experiments
./setup-fleet.sh 2          # build the good image, claim host-1, create 2 VMs,
                            # wait for enrollment/health, pin the good image
./e1-rollback-reliability.sh ... ./e7-cp-unreachable-boot.sh
```

Helpers in `common.sh` (`build_image`, `broken_image`, `alt_image`,
`fleet_*`, `vm_run`, `cockpit_retry`, ...) drive Supernova + cockpit;
results land in `experiments/results/*.csv`. The bootc image itself is
documented in `bootc/README.md` (greenboot gates, rollback mechanics,
Containerfiles). Fleet layout and handoff state: `../plan/handoff-phase5.md`.

### Dockerized "simulated" nodes

`NODES_NUM=N ./start.sh` starts N `star_i` + `starometry_i` containers
(node id state under `nodeconfig/star_i`). They are **not bootc-capable** —
they join the pool next to real nodes and exist for control-plane logic
testing only.

## Configuration

Everything is driven by `.env` (plus the Compose files). The variables that
matter most day-to-day:

| Variable | Default | Meaning |
|---|---|---|
| `NODES_NUM` | `0` | dockerized star nodes to start |
| `C12S_NO_BUILD` | `0` | `1` skips image builds in `start.sh` (same as `--no-build`; `--build` overrides) |
| `SINGULARITY_PORT` / `SINGULARITY_HOST_PORT` | `5000` / `5001` | registry inside/outside compose (nodes see `192.168.122.1:5001`) |
| `SINGULARITY_FILES_PORT` / `..._HOST_PORT` | `8080` / `8081` | artifact server inside/outside |
| `SUPERNOVA_PORT` / `SUPERNOVA_HOST_PORT` | `8090` | build service (bound to `127.0.0.1` only) |
| `SUPERNOVA_ENGINE_REGISTRY` | `localhost:5001` | registry address the push reaches (compose: `singularity:5000`) |
| `NATS_ADDRESS` | `nats:4222` | broker address given to in-network services |
| `SECRET_KEY` | `secret-key` | shared JWT signing key (lab value) |
| `BIND_PORT` | `7946` | Serf/gossip port baked into images and docker nodes |
| `NODE_STALE_AFTER` / `NODE_OFFLINE_AFTER` | `90s` / `5m` | node liveness thresholds (Magnetar derives `online`/`stale`/`offline` from the last heartbeat) |
| `NODE_GC_ENABLED` | `true` | Magnetar's stale-record GC |
| `NODE_GC_INTERVAL` / `NODE_GC_POOL_AFTER` | `10m` / `24h` | GC cadence; unclaimed (pool) records without a heartbeat for this long are deleted. Org-owned nodes are never GC'd — delete them explicitly with `cockpit delete node` |
| `GRAFANA`/metrics ports | see file | protostar/starometry/cadvisor/node_exporter wiring |

`NODES_NUM`, `C12S_USER/PASS/ORG`, `QCOW2_DIR`, `METRICS_*` are read by
`start.sh` at run time (environment overrides `.env`).

Nodes heartbeat every 30 s (`HEARTBEAT_INTERVAL` in `node.env`; the value is
baked into the node image's environment and read by star). A node that
heartbeats successfully shows up as `online` in `cockpit list nodes`; a node
whose record Magnetar lost (e.g. `stop.sh --clean`) learns this from the
heartbeat reply and re-registers with the same id.

## Status

The supported entry point for the whole lab: `start.sh`/`stop.sh`,
`experiments/` and `bootc/` are maintained; the alternative stacks listed
below are not.

## Bugs, disabled and unfinished features

### Confirmed bugs / footguns

| Where | Effect |
|---|---|
| `install.sh` | **Stale clone list**: misses `supernova`, `singularity`, `wormhole` — without them the compose build fails (singularity/supernova) and no bootc VMs can be made. Also lists only the CP repos the bootc lab tests need beyond that. |
| `control_plane.yml` + `control_plane_start.sh`/`control_plane_stop.sh` | **Legacy, divergent second stack**: `docker compose` (no `-f`) uses `docker-compose.yml`, but running the old scripts starts a CP-only stack without singularity/supernova and different env plumbing. Two configs drift — always use `start.sh`/`stop.sh`. |
| `node.yml` + `node_start.sh`/`node_stop.sh`, `start-windows.sh`, `control_plane.env`, `node.env`, `windows.env` | Superseded scaffolding: three different node/start mechanisms exist; only `start.sh`'s `NODES_NUM` path is maintained. |
| Gateway rate limiter defaults | Every authenticated API call passes the per-`method`+`user` limiter; absent a configured limiter one is auto-created with `RL_DEFAULT_REQ_PER_SEC`/`RL_DEFAULT_BURST` (`.env`: 10 req/s, burst 20; the service's own default is 1/1). Limiters are stored in Consul, so ones created under an older default keep it: `docker exec tools-consul-1 consul kv delete -recurse rateLimiters/ && docker restart rate_limiter_service`. |
| `docker run`'d Grafana | Started outside Compose by `start.sh` on the compose network; `stop.sh` forcibly `docker rm -f`s **any** container named `grafana`/`tardis-grafana` on the machine. |

### Disabled / unfinished features

- **No test suite for the orchestration scripts** — they are exercised only by
  lab runs; correctness feedback comes from `start.sh`'s own waits/failures.
- **Registry re-seeding requires `podman` on the host**: machines without it
  silently skip the registry half of step 5 (provisioning disks are still
  re-uploaded via curl; image tags are not re-pushed).
- `supernova` is bound to `127.0.0.1` deliberately (review S3) — a remote
  build host is not supported by this stack layout.
- Metrics Grafana wiring is convenience-grade: dashboards/datasources are
  provisioned from `grafana/`, but nothing is versioned per lab session, and
  the health-check Prometheus (`prometheus_healthcheck`) is a separate,
  pre-existing helper.
- Windows/macOS paths (`start-windows.sh`, `windows.env`) are unmaintained;
  the bootc lab is Linux-only (libvirt, KVM, podman).

### PoC boundaries (by design, not bugs)

- **No systemd unit for the lab stack** (deliberate): `docker compose` is only
  a CLI, so after a host reboot Docker restores containers from their
  `restart:` policies. There is no supervised `compose up`; use
  `./start.sh --no-build` when the out-of-band steps (schema, Vault, test
  user, seeds) need re-running.
- Plaintext everything inside the compose network (NATS, etcd, Vault HTTP,
  gRPC, webhooks); lab credentials are in-tree (`SECRET_KEY`, test user).
- The compose files hardcode per-service static IPs (`10.5.0.x`) — one lab
  stack per Docker host.
- `vault/api_key.json` is gitignored: protect it together with the
  `tools_vault_data` volume.

References: `../plan/architecture.md` (as-built), `../plan/handoff-phase5.md`
(lab state), `../plan/review.md` (S1/S3, rate limits), `docs/README.md`
(corrected API reference).
