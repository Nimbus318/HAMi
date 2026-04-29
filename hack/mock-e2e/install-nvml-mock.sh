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

# Build + install NVIDIA/k8s-test-infra nvml-mock onto the integration node.
#
# nvml-mock provides a real ELF libnvidia-ml.so.1 shared library + nvidia-smi
# binary at /var/lib/nvml-mock/driver/... on the kind node, which HAMi's
# nvidia device plugin can dlopen via the standard NVIDIA driver-root pattern.

set -euo pipefail

NVML_MOCK_REPO_DIR="${NVML_MOCK_REPO_DIR:-_k8s-test-infra}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-hami-mock-e2e}"
GPU_PROFILE="${GPU_PROFILE:-h100}"
GPU_COUNT="${GPU_COUNT:-8}"

if [ ! -d "$NVML_MOCK_REPO_DIR" ]; then
  echo "ERROR: $NVML_MOCK_REPO_DIR not found. Checkout NVIDIA/k8s-test-infra first." >&2
  exit 1
fi

echo "=== Build nvml-mock image ==="
docker build -t nvml-mock:ci -f "$NVML_MOCK_REPO_DIR/deployments/nvml-mock/Dockerfile" "$NVML_MOCK_REPO_DIR"

echo ""
echo "=== Load image into kind ==="
kind load docker-image nvml-mock:ci --name "$KIND_CLUSTER_NAME"

echo ""
echo "=== Helm install nvml-mock (profile=$GPU_PROFILE count=$GPU_COUNT) ==="
helm install nvml-mock "$NVML_MOCK_REPO_DIR/deployments/nvml-mock/helm/nvml-mock" \
  --namespace nvml-mock \
  --create-namespace \
  --set image.repository=nvml-mock \
  --set image.tag=ci \
  --set image.pullPolicy=Never \
  --set integrations.fakeGpuOperator.enabled=true \
  --set gpu.profile="$GPU_PROFILE" \
  --set gpu.count="$GPU_COUNT" \
  --set "nodeSelector.run\.ai/simulated-gpu-node-pool=integration" \
  --wait \
  --timeout 4m

echo ""
echo "=== nvml-mock pods ==="
kubectl get pods -n nvml-mock -o wide

echo ""
echo "=== Wait for /var/lib/nvml-mock layout to settle on the host ==="
POD=$(kubectl get pods -n nvml-mock -l app.kubernetes.io/name=nvml-mock \
        -o jsonpath='{.items[0].metadata.name}')
for _ in $(seq 1 30); do
  if kubectl exec -n nvml-mock "$POD" -- \
       test -x /host/var/lib/nvml-mock/driver/usr/bin/nvidia-smi 2>/dev/null; then
    break
  fi
  sleep 2
done

# Per mock-gpu-ci-demo design notes: device nodes must live under BOTH
# $ROOT/dev (where setup.sh creates them) AND $ROOT/driver/dev (where
# anything keying off nvidiaDriverRoot expects them). The chart's setup.sh
# only writes the former; copy them across so HAMi's DP is happy regardless
# of which path it probes.
kubectl exec -n nvml-mock "$POD" -- sh -c '
set -eu
ROOT=/host/var/lib/nvml-mock
mkdir -p "$ROOT/driver/dev"
cp -a "$ROOT/dev/." "$ROOT/driver/dev/" 2>/dev/null || true
test -x "$ROOT/driver/usr/bin/nvidia-smi"
test -e "$ROOT/driver/usr/lib64/libnvidia-ml.so.1"
test -e "$ROOT/driver/dev/nvidiactl"
echo "nvml-mock layout OK on host"
'

echo ""
echo "=== Profile ConfigMaps (FGO discovery channel) ==="
kubectl get configmaps -n nvml-mock -l run.ai/gpu-profile=true
