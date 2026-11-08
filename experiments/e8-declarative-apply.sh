#!/usr/bin/env bash
# E8 — declarative apply (HostImageSpec) in the lab.
#
# Drives `cockpit image apply --spec`, the declarative front end for the
# build and update commands. Three modes:
#
#   T1 dry-run: the plan is printed and nothing is built or updated.
#   T2 pinned spec: a digest-pinned spec applied directly to the fleet.
#      The fleet already runs the digest, so the apply is idempotent (skips);
#      --force re-sends the update to prove the override.
#   T3 build spec: the build block runs first (through the gateway and
#      Supernova), its digest becomes the hand-off, and the canary + targets
#      are rolled out behind the health gate. The fleet is restored to the
#      good image afterwards.
#
# Use cases:
#   - pinned spec: "this digest must run on this fleet" (no build, no source
#     context; the operator has already built the image).
#   - build spec: "build this Containerfile, then roll the result out"
#     (the spec is the source of truth for the build and the target).
#   - dry-run: "show me what the spec would do" before changing the fleet.
#
# Precondition: setup-fleet.sh has run; the fleet is healthy on $GOOD_TAG.
# Usage: e8-declarative-apply.sh [canary] [target]

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
ensure_cockpit
login

CANARY="${1:-$VM_NODE_1}"
TARGET="${2:-$VM_NODE_2}"
REF=192.168.122.1:5001/os/edge-base
GOOD_DIGEST="${GOOD_DIGEST:-$(zot_digest "$GOOD_TAG")}"
[ -n "$GOOD_DIGEST" ] || fail "no digest for $GOOD_TAG"
[ "$(node_booted_digest "$CANARY")" = "$GOOD_DIGEST" ] || fail "precondition: $CANARY must run $GOOD_TAG"
[ "$(node_booted_digest "$TARGET")" = "$GOOD_DIGEST" ] || fail "precondition: $TARGET must run $GOOD_TAG"

record e8-apply "test,node,seconds,result,detail"
TMP="$TMP_DIR/e8"
mkdir -p "$TMP"

# --- T1: dry-run prints the plan -------------------------------------------
cat > "$TMP/pinned.yaml" <<EOF
apiVersion: c12s/os.v1
kind: HostImageSpec
metadata:
  org: $C12S_ORG
  name: edge-base
  version: $GOOD_TAG
spec:
  image:
    ref: $REF
    digest: $GOOD_DIGEST
    rebootPolicy: immediate
  target:
    org: $C12S_ORG
    nodes: [$CANARY, $TARGET]
  rollout:
    canary: $CANARY
    soak: 2m
    timeout: 15m
EOF
out=$(image_apply "$TMP/pinned.yaml" --dry-run 2>&1) || fail "T1 dry-run failed"
echo "$out" | grep -q 'Dry run: no build or update was performed' || fail "T1 dry-run did not print the plan"
echo "$out" | grep -q "Build: " && fail "T1 dry-run printed a build for a pinned spec"
log "T1 dry-run ok"
record e8-apply "T1-dry-run,$CANARY,0,ok,plan printed"

# --- T2: pinned apply is idempotent; --force overrides ----------------------
# Direct (no rollout) so the idempotency check is the only thing measured.
cat > "$TMP/pinned-direct.yaml" <<EOF
apiVersion: c12s/os.v1
kind: HostImageSpec
metadata:
  org: $C12S_ORG
  name: edge-base
  version: $GOOD_TAG
spec:
  image:
    ref: $REF
    digest: $GOOD_DIGEST
    rebootPolicy: immediate
  target:
    org: $C12S_ORG
    nodes: [$CANARY, $TARGET]
EOF
out=$(image_apply "$TMP/pinned-direct.yaml" 2>&1) || fail "T2 apply failed"
echo "$out" | grep -q 'skipping' || fail "T2 apply did not skip the matching digest"
log "T2 idempotent apply ok"
record e8-apply "T2-idempotent,$CANARY,0,ok,skipped"

out=$(image_apply "$TMP/pinned-direct.yaml" --force 2>&1) || fail "T2 force apply failed"
echo "$out" | grep -q 'accepted' || fail "T2 force apply did not send an update"
log "T2 force apply ok"
record e8-apply "T2-force,$CANARY,0,ok,accepted"
wait_for_phase "$CANARY" healthy 120 >/dev/null || fail "T2 canary not healthy"
wait_for_phase "$TARGET" healthy 120 >/dev/null || fail "T2 target not healthy"

# --- T3: build spec -> build + canary-gated rollout -------------------------
ensure_star_binary
TAG="$GOOD_TAG-apply"
cat > "$TMP/build.yaml" <<EOF
apiVersion: c12s/os.v1
kind: HostImageSpec
metadata:
  org: $C12S_ORG
  name: edge-base
  version: $TAG
spec:
  build:
    context: $REPO_ROOT/tools/bootc
    containerfile: Containerfile.bootc
    registry: 192.168.122.1:5001
    name: os/edge-base
    tag: $TAG
    buildArgs:
      OS_VERSION: $TAG
  target:
    org: $C12S_ORG
    nodes: [$CANARY, $TARGET]
  rollout:
    canary: $CANARY
    soak: 2m
    timeout: 15m
EOF
T0=$(date +%s)
if ! out=$(image_apply "$TMP/build.yaml" 2>&1); then
  echo "$out" >&2
  fail "T3 build+apply failed"
fi
t=$(( $(date +%s) - T0 ))
echo "$out"
NEW_DIGEST=$(echo "$out" | grep -o 'sha256:[0-9a-f]\{64\}' | head -1)
[ -n "$NEW_DIGEST" ] || fail "T3 did not report the built digest"
log "T3 built+applied $TAG in ${t}s"
record e8-apply "T3-build-apply,$CANARY,$t,ok,$NEW_DIGEST"

# --- restore the fleet to the good image ------------------------------------
image_update "$CANARY" "$REF:$GOOD_TAG" "$GOOD_DIGEST" >/dev/null || fail "T3 restore canary failed"
wait_for_digest "$CANARY" "$GOOD_DIGEST" 600 >/dev/null || fail "T3 canary not healthy on $GOOD_TAG"
image_update "$TARGET" "$REF:$GOOD_TAG" "$GOOD_DIGEST" >/dev/null || fail "T3 restore target failed"
wait_for_digest "$TARGET" "$GOOD_DIGEST" 600 >/dev/null || fail "T3 target not healthy on $GOOD_TAG"
log "T3 restored to $GOOD_TAG"
log "E8 passed"
