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

# Verify the scheduler path on the nvml-mock integration node:
#   1. HAMi admission webhook rewrites a GPU pod to hami-scheduler
#   2. HAMi scheduler filters, annotates, and binds the pod
#   3. HAMi nvidia DP Allocate marks the pod bind phase as success
#   4. an impossible gpumem request is rejected by HAMi scheduler

set -euo pipefail

NS="${SCHED_TEST_NS:-hami-mock-scheduler}"
FIT_POD="${SCHED_FIT_POD:-hami-fit-gpu}"
REJECT_POD="${SCHED_REJECT_POD:-hami-reject-gpumem}"
HAMI_RELEASE="${HAMI_RELEASE:-hami}"
HAMI_NAMESPACE="${HAMI_NAMESPACE:-hami-system}"
WEBHOOK_NAME="${HAMI_WEBHOOK_NAME:-${HAMI_RELEASE}-webhook}"
SCHEDULER_SERVICE="${HAMI_SCHEDULER_SERVICE:-${HAMI_RELEASE}-scheduler}"
FIT_GPUMEM="${SCHED_FIT_GPUMEM:-8192}"
FIT_GPUCORES="${SCHED_FIT_GPUCORES:-30}"

pass() { printf "\033[0;32m  PASS\033[0m  %s\n" "$1"; }
fail() { printf "\033[0;31m  FAIL\033[0m  %s\n" "$1"; FAILED=1; }

FAILED=0

pod_annotation() {
  local pod="$1"
  local key="$2"
  kubectl get pod "$pod" -n "$NS" \
    -o go-template="{{ index .metadata.annotations \"$key\" }}" 2>/dev/null || true
}

pod_jsonpath() {
  local pod="$1"
  local path="$2"
  kubectl get pod "$pod" -n "$NS" -o jsonpath="$path" 2>/dev/null || true
}

event_has_reason() {
  local pod="$1"
  local reason="$2"
  kubectl get events -n "$NS" \
    --field-selector "involvedObject.kind=Pod,involvedObject.name=$pod" \
    -o jsonpath='{range .items[*]}{.reason}{"\n"}{end}' 2>/dev/null \
    | grep -qx "$reason"
}

dump_pod_debug() {
  local pod="$1"
  echo "  --- pod $NS/$pod ---"
  kubectl get pod "$pod" -n "$NS" -o yaml 2>/dev/null || true
  echo "  --- events $NS/$pod ---"
  kubectl get events -n "$NS" \
    --field-selector "involvedObject.kind=Pod,involvedObject.name=$pod" \
    --sort-by=.lastTimestamp 2>/dev/null || true
}

echo "=== Wait for HAMi admission webhook to be usable ==="
WEBHOOK_CA=""
SCHEDULER_ENDPOINT=""
for _ in $(seq 1 60); do
  WEBHOOK_CA=$(kubectl get mutatingwebhookconfiguration "$WEBHOOK_NAME" \
                 -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)
  SCHEDULER_ENDPOINT=$(kubectl get endpoints "$SCHEDULER_SERVICE" -n "$HAMI_NAMESPACE" \
                         -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  if [ -n "$WEBHOOK_CA" ] && [ -n "$SCHEDULER_ENDPOINT" ]; then
    break
  fi
  sleep 2
done

if [ -n "$WEBHOOK_CA" ] && [ -n "$SCHEDULER_ENDPOINT" ]; then
  pass "webhook $WEBHOOK_NAME has caBundle and scheduler service endpoint $SCHEDULER_ENDPOINT"
else
  echo "  --- MutatingWebhookConfiguration ---"
  kubectl get mutatingwebhookconfiguration "$WEBHOOK_NAME" -o yaml 2>/dev/null || true
  echo "  --- scheduler endpoints ---"
  kubectl get endpoints "$SCHEDULER_SERVICE" -n "$HAMI_NAMESPACE" -o yaml 2>/dev/null || true
  fail "webhook $WEBHOOK_NAME is not ready (caBundle=${WEBHOOK_CA:+present} endpoint=${SCHEDULER_ENDPOINT:-missing})"
  exit 1
fi

echo "=== Prepare scheduler test namespace ==="
kubectl delete namespace "$NS" --wait=false 2>/dev/null || true
for _ in $(seq 1 30); do
  if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl create namespace "$NS" >/dev/null

echo ""
echo "=== Check 1: webhook + scheduler + DP Allocate success ==="
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $FIT_POD
  namespace: $NS
spec:
  restartPolicy: Never
  nodeSelector:
    gpu: "on"
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.10
    env:
    - name: CUDA_DISABLE_CONTROL
      value: "true"
    resources:
      limits:
        "nvidia.com/gpu": "1"
        "nvidia.com/gpumem": "$FIT_GPUMEM"
        "nvidia.com/gpucores": "$FIT_GPUCORES"
EOF

SCHEDULER=""
for _ in $(seq 1 24); do
  SCHEDULER=$(pod_jsonpath "$FIT_POD" '{.spec.schedulerName}')
  if [ "$SCHEDULER" = "hami-scheduler" ]; then
    break
  fi
  sleep 5
done

if [ "$SCHEDULER" = "hami-scheduler" ]; then
  pass "webhook rewrote schedulerName to hami-scheduler"
  FIT_SCHEDULER_OK=1
else
  dump_pod_debug "$FIT_POD"
  fail "schedulerName is '$SCHEDULER' (expected hami-scheduler)"
  FIT_SCHEDULER_OK=0
fi

PHASE=""
NODE=""
BIND_PHASE=""
VGPU_NODE=""
TO_ALLOCATE=""
ALLOCATED=""
if [ "$FIT_SCHEDULER_OK" -eq 1 ]; then
  for _ in $(seq 1 36); do
    PHASE=$(pod_jsonpath "$FIT_POD" '{.status.phase}')
    NODE=$(pod_jsonpath "$FIT_POD" '{.spec.nodeName}')
    BIND_PHASE=$(pod_annotation "$FIT_POD" 'hami.io/bind-phase')
    VGPU_NODE=$(pod_annotation "$FIT_POD" 'hami.io/vgpu-node')
    TO_ALLOCATE=$(pod_annotation "$FIT_POD" 'hami.io/vgpu-devices-to-allocate')
    ALLOCATED=$(pod_annotation "$FIT_POD" 'hami.io/vgpu-devices-allocated')
    if [ "$PHASE" = "Running" ] &&
       [ -n "$NODE" ] &&
       [ "$BIND_PHASE" = "success" ] &&
       [ "$VGPU_NODE" = "$NODE" ] &&
       [ -n "$TO_ALLOCATE" ] &&
       [ -n "$ALLOCATED" ]; then
      break
    fi
    sleep 5
  done

  if [ "$PHASE" = "Running" ] &&
     [ -n "$NODE" ] &&
     [ "$BIND_PHASE" = "success" ] &&
     [ "$VGPU_NODE" = "$NODE" ] &&
     [ -n "$TO_ALLOCATE" ] &&
     [ -n "$ALLOCATED" ]; then
    pass "pod ran on $NODE with HAMi allocation annotations and bind-phase=success"
  else
    dump_pod_debug "$FIT_POD"
    fail "pod did not reach Running + HAMi allocation success (phase=$PHASE node=$NODE bind=$BIND_PHASE vgpu-node=$VGPU_NODE)"
  fi

  HAS_FILTER_EVENT=0
  HAS_BIND_EVENT=0
  for _ in $(seq 1 24); do
    if event_has_reason "$FIT_POD" "FilteringSucceed"; then
      HAS_FILTER_EVENT=1
    fi
    if event_has_reason "$FIT_POD" "BindingSucceed"; then
      HAS_BIND_EVENT=1
    fi
    if [ "$HAS_FILTER_EVENT" -eq 1 ] && [ "$HAS_BIND_EVENT" -eq 1 ]; then
      break
    fi
    sleep 5
  done

  if [ "$HAS_FILTER_EVENT" -eq 1 ] && [ "$HAS_BIND_EVENT" -eq 1 ]; then
    pass "scheduler emitted FilteringSucceed and BindingSucceed events"
  else
    dump_pod_debug "$FIT_POD"
    fail "missing scheduler success events (FilteringSucceed=$HAS_FILTER_EVENT BindingSucceed=$HAS_BIND_EVENT)"
  fi
else
  fail "skipping fit pod allocation checks because webhook did not select hami-scheduler"
fi

echo ""
echo "=== Check 2: scheduler rejects impossible gpumem request ==="
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $REJECT_POD
  namespace: $NS
spec:
  restartPolicy: Never
  nodeSelector:
    gpu: "on"
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.10
    env:
    - name: CUDA_DISABLE_CONTROL
      value: "true"
    resources:
      limits:
        "nvidia.com/gpu": "1"
        "nvidia.com/gpumem": "9999999"
        "nvidia.com/gpucores": "100"
EOF

REJECT_SCHEDULER=""
for _ in $(seq 1 24); do
  REJECT_SCHEDULER=$(pod_jsonpath "$REJECT_POD" '{.spec.schedulerName}')
  if [ "$REJECT_SCHEDULER" = "hami-scheduler" ]; then
    break
  fi
  sleep 5
done

if [ "$REJECT_SCHEDULER" = "hami-scheduler" ]; then
  pass "webhook rewrote oversized pod to hami-scheduler"
  REJECT_SCHEDULER_OK=1
else
  dump_pod_debug "$REJECT_POD"
  fail "oversized pod schedulerName is '$REJECT_SCHEDULER' (expected hami-scheduler)"
  REJECT_SCHEDULER_OK=0
fi

REJECT_PHASE=""
REJECT_NODE=""
HAS_FILTER_FAILED=0
if [ "$REJECT_SCHEDULER_OK" -eq 1 ]; then
  for _ in $(seq 1 36); do
    REJECT_PHASE=$(pod_jsonpath "$REJECT_POD" '{.status.phase}')
    REJECT_NODE=$(pod_jsonpath "$REJECT_POD" '{.spec.nodeName}')
    if event_has_reason "$REJECT_POD" "FilteringFailed"; then
      HAS_FILTER_FAILED=1
    fi
    if [ "$REJECT_PHASE" = "Pending" ] &&
       [ -z "$REJECT_NODE" ] &&
       [ "$HAS_FILTER_FAILED" -eq 1 ]; then
      break
    fi
    sleep 5
  done

  if [ "$REJECT_PHASE" = "Pending" ] &&
     [ -z "$REJECT_NODE" ] &&
     [ "$HAS_FILTER_FAILED" -eq 1 ]; then
    pass "oversized gpumem pod stayed Pending with FilteringFailed"
  else
    dump_pod_debug "$REJECT_POD"
    fail "oversized pod was not rejected as expected (phase=$REJECT_PHASE node=$REJECT_NODE FilteringFailed=$HAS_FILTER_FAILED)"
  fi
else
  fail "skipping oversized pod rejection check because webhook did not select hami-scheduler"
fi

echo ""
echo "=== Summary ==="
if [ $FAILED -eq 0 ]; then
  kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
  printf "\033[0;32m  ✓ HAMi scheduler allocation path works on nvml-mock\033[0m\n"
  exit 0
else
  echo "Keeping namespace $NS for failure debug collection"
  printf "\033[0;31m  ✗ scheduler checks failed\033[0m\n"
  exit 1
fi
