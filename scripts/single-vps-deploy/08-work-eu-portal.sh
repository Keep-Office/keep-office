#!/usr/bin/env bash
# Usage: ./08-work-eu-portal.sh
# work-eu layer on top of the MinBZK base (scripts 01-07):
#   - builds our patched bureaublad backend (CalDAV fixes) and frontend
#     (upcoming-events Calendar widget) from pinned upstream source + overlays
#   - installs the Nextcloud Calendar app
#   - wires the portal's calendar to Nextcloud CalDAV
#
# Idempotent and safe to re-run. Reads the domain from /etc/mijnbureau/domain.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OVERLAY="${REPO_ROOT}/overlays/bureaublad"
BUREAUBLAD_REF="${BUREAUBLAD_REF:-v0.9.3}"
BACKEND_BASE_IMAGE="${BACKEND_BASE_IMAGE:-ghcr.io/minbzk/bureaublad-api:v0.9.3}"
BUILDX_VERSION="${BUILDX_VERSION:-v0.19.3}"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
DOMAIN="$(cat /etc/mijnbureau/domain)"

echo "==> [1/7] Ensuring docker buildx is available"
if ! docker buildx version >/dev/null 2>&1; then
  mkdir -p ~/.docker/cli-plugins
  curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
    -o ~/.docker/cli-plugins/docker-buildx
  chmod +x ~/.docker/cli-plugins/docker-buildx
fi

echo "==> [2/7] Fetching bureaublad source @ ${BUREAUBLAD_REF} and applying overlays"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
git clone --depth 1 --branch "${BUREAUBLAD_REF}" https://github.com/MinBZK/bureaublad "${WORK}/bureaublad"
# Overlay our patched/added files (carry-and-upstream: these become PRs upstream).
cp -a "${OVERLAY}/backend/." "${WORK}/bureaublad/backend/"
cp -a "${OVERLAY}/frontend/." "${WORK}/bureaublad/frontend/"

echo "==> [3/7] Building backend image (overlay on ${BACKEND_BASE_IMAGE} to avoid lockfile drift)"
cat > "${WORK}/Dockerfile.backend" <<EOF
FROM ${BACKEND_BASE_IMAGE}
COPY backend/app/clients/caldav.py /app/app/clients/caldav.py
EOF
docker buildx build --load -f "${WORK}/Dockerfile.backend" -t work-eu/bureaublad-api:local "${WORK}/bureaublad"
docker save work-eu/bureaublad-api:local | k3s ctr -n k8s.io images import -

echo "==> [4/7] Building frontend image from source + overlay"
docker buildx build --load -t work-eu/bureaublad-frontend:local "${WORK}/bureaublad/frontend"
docker save work-eu/bureaublad-frontend:local | k3s ctr -n k8s.io images import -

echo "==> [5/7] Pointing portal deployments at our images"
kubectl -n mb-bureaublad patch deploy bureaublad-backend --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"work-eu/bureaublad-api:local"},
  {"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]'
kubectl -n mb-bureaublad patch deploy bureaublad-frontend --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"work-eu/bureaublad-frontend:local"},
  {"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]'

echo "==> [6/7] Installing the Nextcloud Calendar app"
kubectl -n mb-nextcloud exec deploy/nextcloud -c nextcloud -- \
  sh -c "cd /var/www/html && (php occ app:install calendar || php occ app:enable calendar)"

echo "==> [7/7] Wiring the portal calendar to Nextcloud CalDAV"
kubectl -n mb-bureaublad set env deploy/bureaublad-backend \
  CALENDAR_URL="https://nextcloud.${DOMAIN}/apps/calendar" \
  CALENDAR_CARD=true \
  TASK_URL="https://nextcloud.${DOMAIN}" \
  TASK_AUDIENCE=nextcloud

kubectl -n mb-bureaublad rollout status deploy/bureaublad-backend --timeout=120s
kubectl -n mb-bureaublad rollout status deploy/bureaublad-frontend --timeout=180s

echo ""
echo "work-eu portal + calendar live at https://bureaublad.${DOMAIN}"
