#!/bin/bash
# greenboot required check: star agent service must be running.
# Any required.d script exiting non-zero fails the boot:
# greenboot runs `bootc rollback` and reboots into the previous deployment.
set -o pipefail

if ! systemctl is-active --quiet star.service; then
    echo "star.service is not active"
    exit 1
fi

echo "star.service is active"
exit 0
