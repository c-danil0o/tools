# bootc node image artifacts

This directory holds everything that goes **into** the node OS image (which
travels with every bootc switch) plus the Containerfiles that assemble it.
It does **not** hold node-local state — see `/var/lib/c12s/` semantics in
`plan/architecture.md`.

## Contents

| Path | Lands in image at | Purpose |
|---|---|---|
| `Containerfile.bootc` | — | image recipe (`quay.io/fedora/fedora-bootc:45` base) |
| `Containerfile.broken` | — | good image + `99-always-fail.sh` (rollback/canary tests) |
| `node.env` | `/usr/lib/c12s/node.env` | node defaults shared by every node (NATS address, agent settings); changed by an image update |
| `systemd/star.service` | `/usr/lib/systemd/system/` | runs Star at boot, `Restart=always`; loads `/usr/lib/c12s/node.env`, then `/var/lib/c12s/node.env` (per-node, wins) |
| `greenboot/01-star-health.sh` | `/etc/greenboot/check/required.d/` | boot gate: star service active (waits ≤60 s) |
| `greenboot/02-cp-reachability.sh` | `/etc/greenboot/check/required.d/` | boot gate on **update boots only** (star's attempt is `applied` on an earlier boot and the attempted image is booted): NATS reachable per `node.env` (image defaults, then the per-node file) within 60 s, else rollback; on other boots an unreachable CP only logs a warning (review R14) |
| `greenboot/99-always-fail.sh` | (broken image only) | always fails |

The image also trusts the lab registry `192.168.122.1:5001` (insecure),
installs libvirt/virt-install (used only by `run_vms` nodes), keeps a
persistent journal, and sets `GREENBOOT_MAX_BOOT_ATTEMPTS=2`.

## Build

Through the control plane (gateway → Supernova; needs the
`image.build|image|os/edge-base` policy, and `image.build|image|<disk-name>`
for the disk). Rebuild the star binary first: the image ships whatever
`tools/bootc/star` holds.

```bash
cd star && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ../tools/bootc/star ./cmd && cd ..
cockpit image build --name os/edge-base --tag v4.0 --context tools/bootc \
  --containerfile Containerfile.bootc --build-arg OS_VERSION=v4.0 --wait
cockpit image build --name os/edge-base --tag v4.1-broken --context tools/bootc \
  --containerfile Containerfile.broken \
  --build-arg BASE=localhost:5001/os/edge-base:v4.1 --build-arg OS_VERSION=v4.1-broken --wait
```

`EXTRA_PACKAGES="htop tmux"` (build arg) adds packages to one version.

Provisioning disk (qcow2) through Supernova, from a pushed image:

```bash
cockpit image build qcow2 --name edge-base-v4.0 \
  --image-ref 192.168.122.1:5001/os/edge-base:v4.0 --wait
# -> prints the artifact name and checksum; the disk lands on the artifact server (:8081)
```

The command goes through the gateway's authenticated `BuildQCOW2` route. The
`curl` equivalent is `POST /apis/core/v1/builds/qcow2` with a bearer token
(the gateway forwards it to Supernova's gRPC `BuildQCOW2`); poll
`GET /apis/core/v1/builds/{id}`.

Use `192.168.122.1:5001/...` as the image ref: it is what nodes boot from and
can resolve. The experiment helpers (`tools/experiments/common.sh`
`build_image`, `broken_image`) build the same Containerfiles directly with
docker/podman.

## Node configuration: image defaults + per-node file

| File | Written by | Holds | Changes when |
|---|---|---|---|
| `/usr/lib/c12s/node.env` | this image (`node.env` here) | values shared by every node: `NATS_ADDRESS`, ports, poll interval | every image update |
| `/var/lib/c12s/node.env` | cloud-init, from the seed (wormhole, or star for VMs) | per-node values: `VM_NETWORK`, `VM_IP_BASE`, optional overrides | first boot only |

`star.service` and `02-cp-reachability.sh` read both in that order; a key in
the per-node file wins. To move the control plane, edit `node.env`, build,
and roll out: the update travels over the old address, and an image whose
address is unreachable fails the update boot and rolls back. Keep the old
address reachable until every node has moved.

## How the health gate and rollback work

greenboot here is the `greenboot` 0.16 package (greenboot-rs). Rollback needs
all three of its parts:

1. **Staging:** Star runs `bootc switch <ref>@<digest>` (no `--apply`),
   records the attempt in `/var/lib/c12s/`, then reboots. On the staging
   shutdown `greenboot-set-rollback-trigger.service` sets
   `boot_counter=GREENBOOT_MAX_BOOT_ATTEMPTS` and the fallback deployment id.
2. **GRUB snippet `08_greenboot.cfg`** (owned by the greenboot package): on
   every boot it counts `boot_counter` down and resets `boot_success=0`; at 0
   it boots the previous deployment. It reaches `/boot` only when
   bootc-image-builder creates a disk — image updates never change `/boot`.
   **Do not remove it** (see `plan/deviations.md` DEV-12 correction).
3. **Health check:** `greenboot-healthcheck.service` runs `required.d`. All
   pass → `boot_success=1`, counter cleared. A failure → reboot; once GRUB has
   fallen back, greenboot makes the rollback permanent.

Star reports `switching` until the health check has run on this boot, then
`healthy` only with `boot_success=1`. After a rollback it reports
`rolled_back` and parks that digest (no retry loop) until a new
`cockpit image update` arrives.

## Testing a broken image

```bash
cd tools/experiments && ./e3-canary-gate.sh   # canary rollout of <GOOD_TAG>-broken-canary
./e1-rollback-reliability.sh                  # repeated broken-image cycles
```

Expected: the node boots the broken deployment twice, falls back to the
previous one, and reports `phase: rolled_back` (~2.5 min on the nested lab
VMs).
