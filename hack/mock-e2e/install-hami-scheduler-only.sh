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
HAMI_IMAGE_TAG="${HAMI_IMAGE_TAG:-v2.8.1}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-hami-mock-e2e}"

KUBE_SCHEDULER_TAG=$(kubectl version -o json 2>/dev/null \
                      | python3 -c 'import sys,json; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')

docker pull "$HAMI_IMAGE_REPO:$HAMI_IMAGE_TAG"
kind load docker-image "$HAMI_IMAGE_REPO:$HAMI_IMAGE_TAG" --name "$KIND_CLUSTER_NAME"

helm dependency build charts/hami
helm upgrade --install --create-namespace --cleanup-on-fail \
  "$HAMI_RELEASE" charts/hami \
  -n "$HAMI_NAMESPACE" \
  --set scheduler.kubeScheduler.imageTag="$KUBE_SCHEDULER_TAG" \
  --set scheduler.leaderElect=false \
  --set global.imageTag="$HAMI_IMAGE_TAG" \
  --set scheduler.extender.image.registry="docker.io" \
  --set scheduler.extender.image.repository="$HAMI_IMAGE_REPO" \
  --set devicePlugin.enabled=false \
  --wait \
  --timeout 5m

echo ""
echo "=== HAMi pods (scheduler-only mode) ==="
kubectl get pods -n "$HAMI_NAMESPACE" -o wide
