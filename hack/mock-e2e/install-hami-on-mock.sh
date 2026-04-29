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

# Install HAMi with its real nvidia device plugin, but configured to dlopen
# the mock libnvidia-ml.so provided by nvml-mock instead of the stub library
# baked into the CUDA base image.
#
# Two-fold trick:
#   1. devicePlugin.nvidiaDriverRoot=/var/lib/nvml-mock/driver
#      → host-mounted into /driver-root inside the DP container
#   2. Patch the DaemonSet (after Helm renders it but before the DP pods stop
#      crashing) to inject LD_LIBRARY_PATH and bind-mount the mock lib over
#      the cuda image's stub at the standard ld search location.
#
# Important sequencing:
#   - We do NOT pass --wait to helm. The DP pod will CrashLoopBackOff until
#     the patch lands, and helm --wait will time out before we get to patch.
#     So: install (no wait) → patch DS → poll for rollout manually.

set -euo pipefail

HAMI_RELEASE="${HAMI_RELEASE:-hami}"
HAMI_NAMESPACE="${HAMI_NAMESPACE:-hami-system}"
HAMI_IMAGE_REPO="${HAMI_IMAGE_REPO:-projecthami/hami}"
HAMI_IMAGE_REGISTRY="${HAMI_IMAGE_REGISTRY-docker.io}"
# Default to v2.8.1 (latest stable release). The chart on master and earlier
# images don't agree on flag sets — the chart's --leader-elect was added
# after v2.7.0, so chart-master + image-v2.7.0 makes the extender crash with
# "unknown flag: --leader-elect".
HAMI_IMAGE_TAG="${HAMI_IMAGE_TAG:-v2.8.1}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-hami-mock-e2e}"
EXPECTED_GPUS="${GPU_COUNT:-8}"

echo "=== Detecting kube-scheduler tag from cluster ==="
KUBE_SCHEDULER_TAG=$(kubectl version -o json 2>/dev/null \
                      | python3 -c 'import sys,json; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')
echo "kube-scheduler tag: $KUBE_SCHEDULER_TAG"

echo ""
echo "=== Prepare HAMi image for kind ==="
if [ "${HAMI_IMAGE_PULL:-true}" = "true" ]; then
  docker pull "$HAMI_IMAGE_REPO:$HAMI_IMAGE_TAG"
else
  docker image inspect "$HAMI_IMAGE_REPO:$HAMI_IMAGE_TAG" >/dev/null
fi
kind load docker-image "$HAMI_IMAGE_REPO:$HAMI_IMAGE_TAG" --name "$KIND_CLUSTER_NAME"

echo ""
echo "=== Helm install HAMi (NO --wait; we patch DS after) ==="
helm dependency build charts/hami
# Keep scheduler.leaderElect at the chart default. The scheduler Service selects
# hami.io/scheduler-role=leader; without that endpoint, the admission webhook is
# present but unreachable and pods fall through to default-scheduler.
helm upgrade --install --create-namespace --cleanup-on-fail \
  "$HAMI_RELEASE" charts/hami \
  -n "$HAMI_NAMESPACE" \
  --set scheduler.kubeScheduler.imageTag="$KUBE_SCHEDULER_TAG" \
  --set global.imageTag="$HAMI_IMAGE_TAG" \
  --set scheduler.extender.image.registry="$HAMI_IMAGE_REGISTRY" \
  --set scheduler.extender.image.repository="$HAMI_IMAGE_REPO" \
  --set devicePlugin.image.registry="$HAMI_IMAGE_REGISTRY" \
  --set devicePlugin.image.repository="$HAMI_IMAGE_REPO" \
  --set devicePlugin.monitor.image.registry="$HAMI_IMAGE_REGISTRY" \
  --set devicePlugin.monitor.image.repository="$HAMI_IMAGE_REPO" \
  --set devicePlugin.passDeviceSpecsEnabled=true \
  --set devicePlugin.nvidiaDriverRoot=/var/lib/nvml-mock/driver \
  --set "devicePlugin.nodeSelector.gpu=on" \
  --timeout 2m

echo ""
echo "=== Wait for DP DaemonSet object to exist ==="
for _ in $(seq 1 30); do
  if kubectl get ds -n "$HAMI_NAMESPACE" hami-device-plugin >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

DS_NAME="hami-device-plugin"
echo "device-plugin DaemonSet: $DS_NAME"

echo ""
echo "=== Patch DP DaemonSet so dlopen(libnvidia-ml.so.1) finds the mock lib ==="
# The HAMi DP image (projecthami/hami) does not ship libnvidia-ml.so.1 by
# itself. In production it gets it from a runtime-mounted host path
# (e.g. /run/nvidia/driver). We give it the mock library two ways so
# dlopen finds it regardless of search order:
#   (a) bind-mount mock libnvidia-ml.so.1 directly over the container's
#       /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 — first ld search hit.
#   (b) LD_LIBRARY_PATH=/driver-root/usr/lib64 — fallback.
#
# Both `device-plugin` and `vgpu-monitor` containers in the same pod load
# NVML, so apply the patch to both.
kubectl patch -n "$HAMI_NAMESPACE" ds/"$DS_NAME" --type=strategic --patch '
spec:
  template:
    spec:
      containers:
      - name: device-plugin
        env:
        - name: LD_LIBRARY_PATH
          value: /driver-root/usr/lib64:/usr/lib/x86_64-linux-gnu:/usr/lib64
        volumeMounts:
        - name: mock-nvml-lib
          mountPath: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1
          subPath: libnvidia-ml.so.1
          readOnly: true
      - name: vgpu-monitor
        env:
        - name: LD_LIBRARY_PATH
          value: /driver-root/usr/lib64:/usr/lib/x86_64-linux-gnu:/usr/lib64
        volumeMounts:
        - name: mock-nvml-lib
          mountPath: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1
          subPath: libnvidia-ml.so.1
          readOnly: true
        - name: driver-root
          mountPath: /driver-root
          readOnly: true
      volumes:
      - name: mock-nvml-lib
        hostPath:
          path: /var/lib/nvml-mock/driver/usr/lib64
          type: Directory
'

echo ""
echo "=== Wait for the patched DP DaemonSet to roll out ==="
kubectl rollout status -n "$HAMI_NAMESPACE" ds/"$DS_NAME" --timeout=240s

echo ""
echo "=== Wait for the scheduler Deployment to roll out ==="
kubectl rollout status -n "$HAMI_NAMESPACE" deploy/hami-scheduler --timeout=180s

echo ""
echo "=== Wait for scheduler webhook Service endpoint ==="
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
  echo "  --- scheduler pods ---"
  kubectl get pods -n "$HAMI_NAMESPACE" -l app.kubernetes.io/component=hami-scheduler --show-labels -o wide || true
  echo "  --- scheduler endpoints ---"
  kubectl get endpoints "$HAMI_RELEASE-scheduler" -n "$HAMI_NAMESPACE" -o yaml || true
  exit 1
fi
echo "scheduler Service endpoint: $SCHEDULER_ENDPOINT"

echo ""
echo "=== HAMi pods ==="
kubectl get pods -n "$HAMI_NAMESPACE" -o wide

echo ""
echo "=== Wait for nvidia.com/gpu allocatable on integration node ==="
for _ in $(seq 1 30); do
  GPU=$(kubectl get nodes -l gpu=on \
          -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  if [ -n "$GPU" ] && [ "$GPU" != "0" ]; then
    break
  fi
  sleep 5
done

if [ -z "${GPU:-}" ] || [ "${GPU:-0}" = "0" ]; then
  echo "ERROR: integration node never advertised nvidia.com/gpu" >&2
  echo "  --- DP pod logs ---"
  kubectl logs -n "$HAMI_NAMESPACE" -l app.kubernetes.io/component=hami-device-plugin --tail=120 || true
  echo "  --- Node status ---"
  kubectl describe node -l gpu=on | head -60
  exit 1
fi

echo ""
echo "=== Resource summary on integration node ==="
kubectl get nodes -l gpu=on \
  -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu,GPUMEM:.status.allocatable.nvidia\\.com/gpumem
echo "Got nvidia.com/gpu=$GPU (expected $EXPECTED_GPUS)"
