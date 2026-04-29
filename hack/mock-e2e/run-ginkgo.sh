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

# Run only the e2e specs that don't require real CUDA execution.
#
# HAMi's existing test_pod.go has two specs:
#   - "creates a single pod with CUDA configuration" — runs nvidia-smi + a
#     CUDA sample inside the pod. Requires real CUDA. SKIP.
#   - "create overcommit pods" — validates that an overcommitted pod stays
#     Pending due to scheduler filtering. Pure scheduler logic. RUN.
#
# This script is wired as a manual diagnostic in mock-gpu-e2e.yaml, not as a
# default gating check. Use --focus to keep it stable as new specs are added:
# only specs that explicitly opt in (today: "overcommit") run on mock CI.

set -euo pipefail

# HAMi's test/utils/common.go reads kubeconfig from the KUBE_CONF env var
# (not KUBECONFIG, not ginkgo's --kubeconfig flag). Export it explicitly.
export KUBE_CONF="${KUBE_CONF:-${KUBECONFIG:-$HOME/.kube/config}}"
echo "KUBE_CONF=$KUBE_CONF"
test -s "$KUBE_CONF" || { echo "ERROR: kubeconfig is empty or missing: $KUBE_CONF" >&2; exit 1; }

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# HAMi's test/utils/config.go hardcodes the GPU node name to "gpu-master"
# (the upstream self-hosted GPU VM). On kind it's `<cluster>-worker[N]`.
# Patch the constant in-tree before compiling — CI has a fresh checkout
# every run so this never pollutes the working tree across runs.
TARGET_NODE=$(kubectl get nodes -l gpu=on \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$TARGET_NODE" ]; then
  echo "ERROR: no node with label gpu=on; cannot continue" >&2
  exit 1
fi
echo "Re-targeting test/utils/config.go GPUNode -> $TARGET_NODE"
sed -i.bak "s|GPUNode\s*=\s*\"gpu-master\"|GPUNode              = \"$TARGET_NODE\"|" \
  test/utils/config.go
grep -E '^\s*GPUNode' test/utils/config.go

GINKGO_VERSION=$(go list -m -f '{{.Version}}' github.com/onsi/ginkgo/v2)
echo "ginkgo version: $GINKGO_VERSION"
GINKGO_TIMEOUT="${GINKGO_TIMEOUT:-2m}"
echo "ginkgo timeout: $GINKGO_TIMEOUT"

echo ""
echo "=== Running mock-friendly e2e: overcommit ==="
go run "github.com/onsi/ginkgo/v2/ginkgo@${GINKGO_VERSION}" \
  run -v -r \
  --timeout="$GINKGO_TIMEOUT" \
  --focus="overcommit pods" \
  --skip="single pod with CUDA configuration" \
  ./test/e2e/ \
  -- --kubeconfig="$KUBE_CONF"
