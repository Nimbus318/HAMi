#!/usr/bin/env bash
# Copyright 2024 The HAMi Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# `scale` job variant: install HAMi scheduler/webhook ONLY.
# We rely on FGO's kwok-gpu-device-plugin to advertise nvidia.com/gpu on the
# KWOK fleet, so HAMi's own DP would just be noise. Disable it through the
# chart's devicePlugin.enabled value; do not rely on impossible nodeSelectors,
# because Helm --wait still waits for the rendered DaemonSet.

set -euo pipefail

HAMI_RELEASE="${HAMI_RELEASE:-hami}"
HAMI_NAMESPACE="${HAMI_NAMESPACE:-hami-system}"
HAMI_IMAGE_REPO="${HAMI_IMAGE_REPO:-projecthami/hami}"
HAMI_IMAGE_REGISTRY="${HAMI_IMAGE_REGISTRY-docker.io}"
HAMI_IMAGE_TAG="${HAMI_IMAGE_TAG:-v2.8.1}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-hami-mock-e2e}"

KUBE_SCHEDULER_TAG=$(kubectl version -o json 2>/dev/null \
                      | python3 -c 'import sys,json; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')

if [ "${HAMI_IMAGE_PULL:-true}" = "true" ]; then
  docker pull "$HAMI_IMAGE_REPO:$HAMI_IMAGE_TAG"
else
  docker image inspect "$HAMI_IMAGE_REPO:$HAMI_IMAGE_TAG" >/dev/null
fi
kind load docker-image "$HAMI_IMAGE_REPO:$HAMI_IMAGE_TAG" --name "$KIND_CLUSTER_NAME"

helm dependency build charts/hami
# Keep scheduler.leaderElect at the chart default so the scheduler Service gets
# a hami.io/scheduler-role=leader endpoint for the admission webhook.
helm upgrade --install --create-namespace --cleanup-on-fail \
  "$HAMI_RELEASE" charts/hami \
  -n "$HAMI_NAMESPACE" \
  --set scheduler.kubeScheduler.imageTag="$KUBE_SCHEDULER_TAG" \
  --set global.imageTag="$HAMI_IMAGE_TAG" \
  --set scheduler.extender.image.registry="$HAMI_IMAGE_REGISTRY" \
  --set scheduler.extender.image.repository="$HAMI_IMAGE_REPO" \
  --set devicePlugin.enabled=false \
  --wait \
  --timeout 5m

echo ""
echo "=== Wait for scheduler Service endpoint ==="
for _ in $(seq 1 60); do
  SCHEDULER_ENDPOINT=$(kubectl get endpoints "$HAMI_RELEASE-scheduler" -n "$HAMI_NAMESPACE" \
                         -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  if [ -n "$SCHEDULER_ENDPOINT" ]; then
    break
  fi
  sleep 2
done

if [ -z "${SCHEDULER_ENDPOINT:-}" ]; then
  echo "ERROR: scheduler Service never got an endpoint" >&2
  kubectl get pods -n "$HAMI_NAMESPACE" -l app.kubernetes.io/component=hami-scheduler --show-labels -o wide || true
  kubectl get endpoints "$HAMI_RELEASE-scheduler" -n "$HAMI_NAMESPACE" -o yaml || true
  exit 1
fi
echo "scheduler Service endpoint: $SCHEDULER_ENDPOINT"

echo ""
echo "=== HAMi pods (scheduler-only mode) ==="
kubectl get pods -n "$HAMI_NAMESPACE" -o wide
