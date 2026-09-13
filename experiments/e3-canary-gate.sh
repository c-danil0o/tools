#!/usr/bin/env bash
# E3 — canary rollout with a health gate (plan/phase-next.md §3.1).
#
# Both nodes run the good image. The canary is offered a deliberately broken
# image; the gate signal is phase=rolled_back in Magnetar, and the production
# node must remain untouched (same healthy digest) — the operator does not
# proceed with the rollout.

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
[ "$VM_COUNT" -ge 2 ] || fail "E3 needs at least 2 nodes (have $VM_COUNT)"
ensure_cockpit
login

CANARY="${1:-$VM_NODE_1}"
PROD="${2:-$VM_NODE_2}"
GOOD_DIGEST="${GOOD_DIGEST:-$(zot_digest "$GOOD_TAG")}"

BROKEN_TAG="$GOOD_TAG-broken-canary"
BROKEN_DIGEST=$(build_image "$BROKEN_TAG" "$BROKEN_TAG" Containerfile.broken "localhost:5001/os/edge-base:$GOOD_TAG")
log "broken canary image digest: $BROKEN_DIGEST"

record e3-canary "role,node,phase,digest,result"
T0=$(date +%s)
image_update "$CANARY" "192.168.122.1:5001/os/edge-base:$BROKEN_TAG" "$BROKEN_DIGEST" >/dev/null || fail "canary update failed"

if ELAPSED=$(wait_for_phase "$CANARY" rolled_back 700 3); then
  log "canary rolled back at +${ELAPSED}s (gate: do not proceed)"
  record e3-canary "canary,$CANARY,rolled_back,$BROKEN_DIGEST,ok"
else
  record e3-canary "canary,$CANARY,timeout,$BROKEN_DIGEST,timeout"
  fail "canary did not report rolled_back within ${ELAPSED}s"
fi

PROD_PHASE=$(node_phase "$PROD")
PROD_DIGEST=$(node_booted_digest "$PROD")
if [ "$PROD_PHASE" = "healthy" ] && [ "$PROD_DIGEST" = "$GOOD_DIGEST" ]; then
  log "production node untouched: healthy on $GOOD_TAG"
  record e3-canary "production,$PROD,$PROD_PHASE,$PROD_DIGEST,untouched"
else
  record e3-canary "production,$PROD,$PROD_PHASE,$PROD_DIGEST,changed"
  fail "production node was affected: phase=$PROD_PHASE digest=$PROD_DIGEST"
fi

# restore the canary to the declared good image
log "restoring canary to $GOOD_TAG"
image_update "$CANARY" "192.168.122.1:5001/os/edge-base:$GOOD_TAG" "$GOOD_DIGEST" >/dev/null || fail "canary restore failed"
if ELAPSED=$(wait_for_digest "$CANARY" "$GOOD_DIGEST" 900); then
  log "canary healthy on $GOOD_TAG at +${ELAPSED}s"
  record e3-canary "canary,$CANARY,healthy,$GOOD_DIGEST,restored"
else
  fail "canary did not return to $GOOD_TAG within ${ELAPSED}s"
fi
log "E3 gate conclusion: rollout stopped after canary failure; production never received the bad image"
