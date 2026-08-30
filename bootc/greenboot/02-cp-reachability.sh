#!/bin/bash
# greenboot required check: the node must reach the control plane transport.
# Reads NATS_ADDRESS from /var/lib/c12s/node.env (persistent across updates).
# NOTE: an edge node that lost uplink for a long time will fail this check and
# roll back its boot; that is intentional for the thesis experiments
# (health gate must be testable end-to-end). Remove this file for deployments
# that must survive network partitions without rolling back.
set -o pipefail

ENV_FILE="/var/lib/c12s/node.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "node env file $ENV_FILE missing"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

NATS_TARGET="${NATS_ADDRESS:-$NATS_HOSTNAME:$NATS_PORT}"
if [ -z "$NATS_TARGET" ]; then
    echo "NATS address not configured in $ENV_FILE"
    exit 1
fi

HOST="${NATS_TARGET%%:*}"
PORT="${NATS_TARGET##*:}"

# wait for convergence: network (and NATS) may still be coming up when
# greenboot runs the checks; fail only if the CP stays unreachable
MAX_WAIT="${GREENBOOT_MAX_WAIT:-120}"
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$HOST/$PORT"; then
        echo "control plane reachable at $NATS_TARGET (waited ${WAITED}s)"
        exit 0
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

echo "cannot reach NATS at $NATS_TARGET within ${MAX_WAIT}s"
exit 1
