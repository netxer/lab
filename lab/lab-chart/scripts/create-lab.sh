#!/usr/bin/env bash
# Create a disposable lab for a trainee.
#
# Usage:
#   ./create-lab.sh <trainee-name> [ttl]
#
# Example:
#   ./create-lab.sh alice 4h
#
# Environment:
#   SSH_KEY_PATH   path to public key (default: ~/.ssh/id_ed25519.pub)
#
# What it does:
#   1. Generates a unique namespace: lab-<trainee>-<timestamp>
#   2. Creates the namespace and annotates it with janitor/ttl
#   3. Runs helm install with the chart in this repo

set -euo pipefail

TRAINEE="${1:?Usage: $0 <trainee-name> [ttl]}"
TTL="${2:-4h}"
TIMESTAMP="$(date +%Y%m%d-%H%M)"
NAMESPACE="lab-${TRAINEE}-${TIMESTAMP}"

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/id_ed25519.pub}"

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "ERROR: SSH public key not found at $SSH_KEY_PATH" >&2
  echo "Set SSH_KEY_PATH or generate one with: ssh-keygen -t ed25519" >&2
  exit 1
fi

SSH_KEY="$(cat "$SSH_KEY_PATH")"

echo ">> Creating namespace ${NAMESPACE} (TTL: ${TTL})"
kubectl create namespace "$NAMESPACE"
kubectl annotate namespace "$NAMESPACE" "janitor/ttl=${TTL}"
kubectl label     namespace "$NAMESPACE" "app=lab" "trainee=${TRAINEE}"

echo ">> Installing lab chart..."
helm install "$TRAINEE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set trainee.name="$TRAINEE" \
  --set trainee.sshPubKey="$SSH_KEY" \
  --set ttl="$TTL"

echo ">> Waiting for VMs to start (this can take several minutes)..."
kubectl wait --for=condition=Ready vm --all \
  -n "$NAMESPACE" --timeout=15m || true

echo
echo "================================================================"
echo "Lab ready for ${TRAINEE}"
echo "================================================================"
echo "Namespace: $NAMESPACE"
echo
SSH_PORT=$(kubectl get svc "trainee-${TRAINEE}-ssh" -n "$NAMESPACE" \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "n/a")
RDP_PORT=$(kubectl get svc "trainee-${TRAINEE}-rdp" -n "$NAMESPACE" \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "n/a")
NODE_IP=$(kubectl get nodes -l lab-node=true \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
  2>/dev/null || echo "<node-ip>")
echo "Trainee SSH:  ssh ${TRAINEE}@${NODE_IP} -p ${SSH_PORT}"
echo "Trainee RDP:  ${NODE_IP}:${RDP_PORT}"
echo
echo "Tear down early:"
echo "  $(dirname "$0")/destroy-lab.sh ${NAMESPACE}"
echo "Otherwise it'll be swept by kube-janitor after ${TTL}."
