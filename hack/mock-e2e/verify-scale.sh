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

# Submit N pods asking for nvidia.com/gpu via HAMi's scheduler and verify the
# FGO/KWOK capacity plus mock HAMi node-device annotations are enough to bind.

set -euo pipefail

EXPECTED_NODES="${KWOK_NODE_COUNT:-10}"
TEST_PODS="${SCALE_TEST_PODS:-5}"
NS="${SCALE_TEST_NS:-hami-scale-test}"

pass() { printf "\033[0;32m  PASS\033[0m  %s\n" "$1"; }
fail() { printf "\033[0;31m  FAIL\033[0m  %s\n" "$1"; FAILED=1; }

FAILED=0

pod_annotation() {
  local pod="$1"
  local key="$2"
  kubectl get pod "$pod" -n "$NS" \
    -o go-template="{{ index .metadata.annotations \"$key\" }}" 2>/dev/null || true
}

if [ "$TEST_PODS" -gt "$EXPECTED_NODES" ]; then
  fail "SCALE_TEST_PODS ($TEST_PODS) must be <= KWOK_NODE_COUNT ($EXPECTED_NODES) in scheduler-only mode"
  exit 1
fi

echo "=== Check 1: KWOK nodes advertise nvidia.com/gpu ==="
for _ in $(seq 1 24); do
  ADV=$(kubectl get nodes -l type=kwok \
          -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
        | awk '$1 != "" && $1 != "0" { count++ } END { print count + 0 }')
  if [ "$ADV" -ge "$EXPECTED_NODES" ]; then
    break
  fi
  sleep 5
done
if [ "${ADV:-0}" -ge "$EXPECTED_NODES" ]; then
  pass "$ADV KWOK nodes advertise nvidia.com/gpu"
else
  fail "only ${ADV:-0} KWOK nodes advertise nvidia.com/gpu (expected $EXPECTED_NODES)"
fi

echo ""
echo "=== Check 2: KWOK nodes carry HAMi device annotations ==="
for _ in $(seq 1 24); do
  REGISTERED=$(kubectl get nodes -l type=kwok \
                 -o go-template='{{range .items}}{{index .metadata.annotations "hami.io/node-nvidia-register"}}{{"\n"}}{{end}}' 2>/dev/null \
               | awk 'length($0) > 2 { count++ } END { print count + 0 }')
  if [ "$REGISTERED" -ge "$EXPECTED_NODES" ]; then
    break
  fi
  sleep 5
done
if [ "${REGISTERED:-0}" -ge "$EXPECTED_NODES" ]; then
  pass "$REGISTERED KWOK nodes carry hami.io/node-nvidia-register"
else
  fail "only ${REGISTERED:-0} KWOK nodes carry hami.io/node-nvidia-register (expected $EXPECTED_NODES)"
fi

echo "Refreshing KWOK node annotations to wake HAMi scheduler cache..."
kubectl annotate nodes -l type=kwok \
  "hami.io/mock-e2e-register-ts=$(date +%s)" \
  --overwrite >/dev/null

echo ""
echo "=== Check 3: schedule $TEST_PODS HAMi-style pods to KWOK fleet ==="
kubectl create namespace "$NS" 2>/dev/null || true
for i in $(seq 1 "$TEST_PODS"); do
  TARGET_INDEX="$(printf "%03d" "$i")"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: hami-scale-pod-$i
  namespace: $NS
  annotations:
    hami.io/use-gpuuuid: ""
spec:
  schedulerName: hami-scheduler
  nodeSelector:
    type: kwok
    hami.io/mock-scale-index: "$TARGET_INDEX"
  tolerations:
  - key: kwok.x-k8s.io/node
    operator: Equal
    value: fake
    effect: NoSchedule
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: c
    image: ubuntu:22.04
    command: ["sleep", "300"]
    resources:
      limits:
        nvidia.com/gpu: "1"
EOF
done

echo "Waiting for $TEST_PODS pods to be bound..."
for _ in $(seq 1 24); do
  BOUND=0
  for i in $(seq 1 "$TEST_PODS"); do
    NODE=$(kubectl get pod "hami-scale-pod-$i" -n "$NS" \
             -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    if [ -n "$NODE" ]; then
      BOUND=$((BOUND + 1))
    fi
  done
  if [ "$BOUND" -ge "$TEST_PODS" ]; then
    break
  fi
  sleep 5
done

if [ "$BOUND" -ge "$TEST_PODS" ]; then
  UNIQUE_NODES=$(kubectl get pods -n "$NS" \
                   -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
                 | awk 'NF' | sort -u | wc -l | tr -d ' ')
  if [ "${UNIQUE_NODES:-0}" -ge "$TEST_PODS" ]; then
    pass "$BOUND/$TEST_PODS pods bound to distinct KWOK nodes by HAMi scheduler"
  else
    fail "$BOUND/$TEST_PODS pods bound but only ${UNIQUE_NODES:-0} distinct KWOK nodes used"
  fi

  ANNOTATED=0
  ALLOCATING=0
  for i in $(seq 1 "$TEST_PODS"); do
    POD="hami-scale-pod-$i"
    NODE=$(kubectl get pod "$POD" -n "$NS" \
             -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    VGPU_NODE=$(pod_annotation "$POD" 'hami.io/vgpu-node')
    TO_ALLOCATE=$(pod_annotation "$POD" 'hami.io/vgpu-devices-to-allocate')
    ALLOCATED=$(pod_annotation "$POD" 'hami.io/vgpu-devices-allocated')
    BIND_PHASE=$(pod_annotation "$POD" 'hami.io/bind-phase')

    if [ -n "$NODE" ] &&
       [ "$VGPU_NODE" = "$NODE" ] &&
       [ -n "$TO_ALLOCATE" ] &&
       [ -n "$ALLOCATED" ]; then
      ANNOTATED=$((ANNOTATED + 1))
    fi
    if [ "$BIND_PHASE" = "allocating" ]; then
      ALLOCATING=$((ALLOCATING + 1))
    fi
  done

  if [ "$ANNOTATED" -ge "$TEST_PODS" ]; then
    pass "$ANNOTATED/$TEST_PODS pods carry HAMi scheduler allocation annotations"
  else
    fail "only $ANNOTATED/$TEST_PODS pods carry HAMi scheduler allocation annotations"
  fi

  if [ "$ALLOCATING" -ge "$TEST_PODS" ]; then
    pass "$ALLOCATING/$TEST_PODS pods reached bind-phase=allocating (expected without HAMi DP)"
  else
    fail "only $ALLOCATING/$TEST_PODS pods reached bind-phase=allocating"
  fi

  kubectl get pods -n "$NS" -o wide
else
  fail "only $BOUND/$TEST_PODS pods bound"
  kubectl get pods -n "$NS" -o wide
  kubectl get events -n "$NS" --sort-by=.lastTimestamp
fi

# Cleanup test pods (don't wait)
kubectl delete namespace "$NS" --wait=false 2>/dev/null || true

echo ""
echo "=== Summary ==="
if [ $FAILED -eq 0 ]; then
  printf "\033[0;32m  ✓ HAMi + KWOK scale binding works\033[0m\n"
  exit 0
else
  printf "\033[0;31m  ✗ scale checks failed\033[0m\n"
  exit 1
fi
