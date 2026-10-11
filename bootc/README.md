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
| `systemd/star.service` | `/usr/lib/systemd/system/` | runs Star at boot, `Restart=always` |
| `greenboot/01-star-health.sh` | `/etc/greenboot/check/required.d/` | boot gate: star service active (waits ≤60 s) |
| `greenboot/02-cp-reachability.sh` | `/etc/greenboot/check/required.d/` | boot gate: NATS reachable per `node.env` (waits ≤60 s) |
| `greenboot/99-always-fail.sh` | (broken image only) | always fails |

The image also trusts the lab registry `192.168.122.1:5001` (insecure),
installs libvirt/virt-install (used only by `run_vms` nodes), keeps a
persistent journal, and sets `GREENBOOT_MAX_BOOT_ATTEMPTS=2`.

## Build

Normally through the experiment helpers (they build star, the image, and push
to the lab registry):

```bash
cd tools/experiments
bash -c 'source common.sh; build_image v3.11 v3.11'          # good image
bash -c 'source common.sh; broken_image 1'                    # <GOOD_TAG>-broken-1
```

Provisioning disk (qcow2) through Supernova, from a pushed image:

```bash
curl -X POST localhost:8090/build/qcow2 -H 'Content-Type: application/json' \
  -d '{"name":"edge-base-v3.11","imageRef":"192.168.122.1:5001/os/edge-base:v3.11"}'
# -> poll localhost:8090/jobs/<id>; disk lands on the artifact server (:8081)
```

Use `192.168.122.1:5001/...` as the image ref: it is what nodes boot from and
can resolve.

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
