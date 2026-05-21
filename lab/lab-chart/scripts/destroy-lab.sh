#!/usr/bin/env bash
# Tear down a lab early.
#
# Usage: ./destroy-lab.sh <namespace>
#
# Deleting the namespace removes everything inside it: VMs, disks, NADs,
# Services, and the Helm release metadata. kube-janitor would do this
# automatically when the TTL expires; this script is for "I'm done early".

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace>}"

echo ">> Destroying lab namespace: $NAMESPACE"
kubectl delete namespace "$NAMESPACE" --wait=true
echo ">> Done."
