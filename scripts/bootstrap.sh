#!/usr/bin/env bash
set -euo pipefail

NETWORK="gitops-net"
HUBS="hub:6443"
STAGING="staging:6444"
PROD="prod:6445"

echo "==> Checking Docker network '${NETWORK}'..."
if docker network inspect "${NETWORK}" >/dev/null 2>&1; then
  echo "    Network '${NETWORK}' already exists, skipping."
else
  echo "    Creating network '${NETWORK}'..."
  docker network create "${NETWORK}"
fi

for entry in "${HUBS}" "${STAGING}" "${PROD}"; do
  name="${entry%%:*}"
  port="${entry##*:}"
  echo ""
  echo "==> Creating k3d cluster '${name}' on port ${port}..."
  if k3d cluster list 2>/dev/null | grep -q "^${name} "; then
    echo "    Cluster '${name}' already exists, skipping."
  else
    k3d cluster create "${name}" \
      --network "${NETWORK}" \
      --api-port "${port}"
  fi
done

echo ""
echo "==> Verifying contexts..."
kubectl config get-contexts --no-headers | grep -E "k3d-hub|k3d-staging|k3d-prod"

echo ""
echo "All clusters ready."
echo "Next steps (see README.md):"
echo "  1. kubectl config use-context k3d-hub"
echo "  2. Install ArgoCD on the hub cluster"
echo "  3. Register spoke clusters with ArgoCD"
echo "  4. Apply root-application.yaml"
