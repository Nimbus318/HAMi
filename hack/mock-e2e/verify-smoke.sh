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

# Verify the smoke chain:
#   1. HAMi scheduler + extender pods are Running
#   2. HAMi nvidia DP pod is Running on integration node
#   3. nvidia.com/gpu allocatable matches GPU_COUNT
#   4. nvml-mock pod's /var/lib/nvml-mock layout is intact

set -euo pipefail

HAMI_NAMESPACE="${HAMI_NAMESPACE:-hami-system}"
EXPECTED_GPUS="${GPU_COUNT:-8}"

pass() { printf "\033[0;32m  PASS\033[0m  %s\n" "$1"; }
fail() { printf "\033[0;31m  FAIL\033[0m  %s\n" "$1"; FAILED=1; }

FAILED=0

echo "=== Check 1: HAMi scheduler Running ==="
SCHED=$(kubectl get pods -n "$HAMI_NAMESPACE" \
          -l app.kubernetes.io/component=hami-scheduler \
          --field-selector=status.phase=Running \
          --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$SCHED" -ge 1 ]; then
  pass "scheduler has $SCHED Running pod(s)"
else
  fail "no scheduler pod Running"
  kubectl get pods -n "$HAMI_NAMESPACE" -o wide
fi

echo ""
echo "=== Check 2: HAMi nvidia DP Running on integration node ==="
DP_NODE=$(kubectl get pods -n "$HAMI_NAMESPACE" \
            -l app.kubernetes.io/component=hami-device-plugin \
            -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
if [ -n "$DP_NODE" ]; then
  if kubectl get node "$DP_NODE" -o jsonpath='{.metadata.labels.gpu}' | grep -q "^on$"; then
    pass "DP pod runs on $DP_NODE (gpu=on)"
  else
    fail "DP pod runs on $DP_NODE but it has no gpu=on label"
  fi
else
  fail "no DP pod found"
fi

echo ""
echo "=== Check 3: nvidia.com/gpu allocatable ==="
# Per mock-gpu-ci-demo design notes: don't fixed-sleep, poll until status
# is observed or timeout. The DP advertise loop after rollout can take
# several seconds depending on registration timing.
GPU=""
for _ in $(seq 1 24); do
  GPU=$(kubectl get nodes -l gpu=on \
          -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  if [ -n "$GPU" ] && [ "$GPU" != "0" ]; then
    break
  fi
  sleep 5
done
if [ -n "$GPU" ] && [ "$GPU" -ge "$EXPECTED_GPUS" ] 2>/dev/null; then
  pass "node advertises nvidia.com/gpu=$GPU (expected $EXPECTED_GPUS)"
else
  echo "  --- DP pod logs (last 60 lines) ---"
  kubectl logs -n "$HAMI_NAMESPACE" -l app.kubernetes.io/component=hami-device-plugin \
    -c device-plugin --tail=60 2>/dev/null || true
  fail "node advertises nvidia.com/gpu=$GPU (expected $EXPECTED_GPUS)"
fi

echo ""
echo "=== Check 4: nvml-mock host layout ==="
POD=$(kubectl get pods -n nvml-mock -l app.kubernetes.io/name=nvml-mock \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$POD" ]; then
  if kubectl exec -n nvml-mock "$POD" -- \
       test -e /host/var/lib/nvml-mock/driver/usr/lib64/libnvidia-ml.so.1; then
    pass "/var/lib/nvml-mock/driver/usr/lib64/libnvidia-ml.so.1 present on host"
  else
    fail "mock NVML library missing on host"
  fi
else
  fail "no nvml-mock pod found"
fi

echo ""
echo "=== Summary ==="
if [ $FAILED -eq 0 ]; then
  printf "\033[0;32m  ✓ HAMi + nvml-mock smoke chain works\033[0m\n"
  exit 0
else
  printf "\033[0;31m  ✗ smoke checks failed\033[0m\n"
  exit 1
fi
