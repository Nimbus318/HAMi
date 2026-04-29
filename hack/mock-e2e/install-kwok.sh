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

# Install KWOK + create N fake GPU nodes labeled `scale`.
# FGO's status-updater reacts to the new nodes and the kwok-gpu-device-plugin
# advertises nvidia.com/gpu on each. HAMi's scheduler also needs the node
# device annotation normally written by HAMi's device plugin, so this script
# writes a minimal mock hami.io/node-nvidia-register annotation for each node.

set -euo pipefail

KWOK_VERSION="${KWOK_VERSION:-v0.7.0}"
KWOK_NODE_COUNT="${KWOK_NODE_COUNT:-10}"
KWOK_GPU_PER_NODE="${KWOK_GPU_PER_NODE:-8}"
KWOK_GPU_MEMORY_MB="${KWOK_GPU_MEMORY_MB:-81920}"
KWOK_GPU_PRODUCT="${KWOK_GPU_PRODUCT:-NVIDIA-H100-80GB}"

if [ "$KWOK_NODE_COUNT" -gt 50 ]; then
  echo "WARNING: capping KWOK_NODE_COUNT from $KWOK_NODE_COUNT to 50"
  KWOK_NODE_COUNT=50
fi
if [ "$KWOK_GPU_PER_NODE" -lt 1 ]; then
  echo "KWOK_GPU_PER_NODE must be >= 1" >&2
  exit 1
fi

echo "=== Installing KWOK $KWOK_VERSION ==="
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/$KWOK_VERSION/kwok.yaml"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/$KWOK_VERSION/stage-fast.yaml"

kubectl wait deployment/kwok-controller -n kube-system \
  --for=condition=available --timeout=120s

mock_hami_devices() {
  local node_name="$1"
  local devices="["
  local gpu

  for gpu in $(seq 0 $((KWOK_GPU_PER_NODE - 1))); do
    if [ "$gpu" -gt 0 ]; then
      devices+=","
    fi
    devices+="{\"id\":\"GPU-${node_name}-${gpu}\",\"index\":${gpu},\"count\":1,\"devmem\":${KWOK_GPU_MEMORY_MB},\"devcore\":100,\"type\":\"${KWOK_GPU_PRODUCT}\",\"numa\":0,\"mode\":\"hami-core\",\"health\":true}"
  done

  devices+="]"
  printf "%s" "$devices"
}

echo ""
echo "=== Creating $KWOK_NODE_COUNT KWOK fake GPU nodes ==="
for i in $(seq 1 "$KWOK_NODE_COUNT"); do
  NODE_NAME="kwok-gpu-$(printf "%03d" "$i")"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Node
metadata:
  annotations:
    kwok.x-k8s.io/node: fake
  labels:
    type: kwok
    run.ai/simulated-gpu-node-pool: scale
    hami.io/mock-scale-index: "$(printf "%03d" "$i")"
  name: $NODE_NAME
spec:
  taints:
  - effect: NoSchedule
    key: kwok.x-k8s.io/node
    value: fake
status:
  allocatable:
    cpu: "16"
    memory: 64Gi
    pods: "110"
  capacity:
    cpu: "16"
    memory: 64Gi
    pods: "110"
EOF
  kubectl annotate node "$NODE_NAME" \
    hami.io/node-nvidia-register="$(mock_hami_devices "$NODE_NAME")" \
    --overwrite >/dev/null
done

echo "=== Wait for KWOK nodes Ready ==="
sleep 8
kubectl wait nodes -l type=kwok --for=condition=Ready --timeout=60s || true

READY=$(kubectl get nodes -l type=kwok --no-headers 2>/dev/null \
          | awk '$2 == "Ready"' | wc -l | tr -d ' ')
echo "KWOK nodes Ready: $READY / $KWOK_NODE_COUNT"
