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

# Install fake-gpu-operator with topology backing for the `scale` job.
# integration pool defers to nvml-mock; scale pool advertises GPU resources
# on KWOK-managed virtual nodes through FGO's kwok-gpu-device-plugin.

set -euo pipefail

GPU_PROFILE="${GPU_PROFILE:-h100}"
GPU_COUNT="${GPU_COUNT:-8}"

echo "=== Helm install fake-gpu-operator ==="
helm upgrade --install gpu-operator \
  oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --wait \
  --timeout 4m \
  -f - <<EOF
topology:
  nodePools:
    integration:
      backend: mock
      gpuCount: $GPU_COUNT
      gpuProduct: $GPU_PROFILE
    scale:
      backend: fake
      gpuCount: $GPU_COUNT
      gpuProduct: $GPU_PROFILE
EOF

echo ""
echo "=== fake-gpu-operator pods ==="
kubectl get pods -n gpu-operator -o wide
