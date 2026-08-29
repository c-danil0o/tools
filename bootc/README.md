# bootc node image artifacts

This directory holds everything that goes **into** the node OS image (which
travels with every bootc switch) plus the Containerfile that assembles it.
It does **not** hold node-local state — see `/var/lib/c12s/` semantics in
`plan/architecture.md`.

## Contents

| Path | Lands in image at | Purpose |
|---|---|---|
| `Containerfile.bootc` | — | image recipe (fedora-bootc:40 base) |
| `systemd/star.service` | `/usr/lib/systemd/system/` | runs Star at boot, `Restart=always` |
| `greenboot/01-star-health.sh` | `/etc/greenboot/check/required.d/` | boot gate: star service active |
| `greenboot/02-cp-reachability.sh` | `/etc/greenboot/check/required.d/` | boot gate: NATS reachable (per `node.env`) |

## Build the OS image

```bash
cd tools/bootc
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -C ../../star -o ../tools/bootc/star github.com/c12s/star/cmd
podman build -f Containerfile.bootc -t localhost:5000/os/edge-base:v1.0 .
podman push localhost:5000/os/edge-base:v1.0
```

Phase 3 (Supernova) automates exactly this, adds cosign signing, and runs
`bootc-image-builder` to produce qcow2/ISO artifacts for provisioning.

## How the health gate works on the node

1. `bootc switch --apply <ref>@<digest>` stages a new deployment and reboots.
2. On boot, greenboot runs **required.d** checks:
   - `01-star-health.sh` — systemd unit active.
   - `02-cp-reachability.sh` — NATS TCP-reachable using `/var/lib/c12s/node.env`
     (which persists across the update, since it is in `/var`).
3. All pass → deployment is finalized (`bootc` cleanup; old deployment stays
   as fallback).
4. Any failure within the greenboot window → `bootc rollback` + reboot into
   the previous deployment. The Star poller sees "desired digest was attempted
   but not booted" (`/var/lib/c12s/os_attempt.json`) and parks the node in
   `rolled_back` phase — it will not loop (see `plan/deviations.md` DEV-3).

## Testing a broken image (rollback experiment)

Build the same image but with a deliberately failing check:

```dockerfile
RUN echo 'exit 1' > /etc/greenboot/check/required.d/99-always-fail.sh
```

Declare it via `cockpit image update`; expected result: node switches, boots
the new deployment, `99-always-fail` fails, greenboot rolls back, node reports
`phase: rolled_back` in `cockpit image status`.
