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

# Mock E2E (Nimbus318/HAMi fork only): kind cluster topology.
#
#   - 1 control-plane
#   - 1 worker labeled `gpu=on` (test fixture expects this label) +
#     `run.ai/simulated-gpu-node-pool=integration` so nvml-mock chart
#     places its DaemonSet there
#   - 2 workers labeled `run.ai/simulated-gpu-node-pool=scale` (used by
#     fake-gpu-operator + KWOK in the `scale` job; sit idle in smoke/matrix)
#
# Free-tier-friendly. ~30s.

set -euo pipefail

# Pin both the semver and the digest. Per mock-gpu-ci-demo design notes, the
# Kubernetes API version is a real test input and floating tags drift.
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-hami-mock-e2e}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f}"
KIND_CONFIG=$(mktemp)

cat > "$KIND_CONFIG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: $KIND_NODE_IMAGE
  - role: worker
    image: $KIND_NODE_IMAGE
    labels:
      gpu: "on"
      run.ai/simulated-gpu-node-pool: integration
  - role: worker
    image: $KIND_NODE_IMAGE
    labels:
      run.ai/simulated-gpu-node-pool: scale
  - role: worker
    image: $KIND_NODE_IMAGE
    labels:
      run.ai/simulated-gpu-node-pool: scale
EOF

echo "=== Deleting any existing cluster ==="
kind delete cluster --name "$KIND_CLUSTER_NAME" 2>/dev/null || true

echo "=== Creating cluster $KIND_CLUSTER_NAME ($KIND_NODE_IMAGE) ==="
kind create cluster \
  --name "$KIND_CLUSTER_NAME" \
  --config "$KIND_CONFIG" \
  --wait 90s

echo "=== Wait for nodes Ready ==="
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo ""
echo "=== Cluster nodes ==="
kubectl get nodes --show-labels
