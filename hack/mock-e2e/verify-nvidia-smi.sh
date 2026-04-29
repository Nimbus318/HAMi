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

# Run nvidia-smi inside a GPU workload pod after HAMi scheduler binding,
# HAMi DP Allocate, and HAMi-core preload injection. The pod mounts the mock
# driver root so the nvidia-smi binary and mock libnvidia-ml.so are available
# inside a vanilla kind worker.

set -euo pipefail

NS="${NVIDIA_SMI_TEST_NS:-hami-mock-nvidia-smi}"
POD="${NVIDIA_SMI_TEST_POD:-hami-nvidia-smi}"
IMAGE="${NVIDIA_SMI_TEST_IMAGE:-nvml-mock:ci}"
REQUESTED_GPUMEM="${NVIDIA_SMI_GPUMEM:-8192}"
REQUESTED_GPUCORES="${NVIDIA_SMI_GPUCORES:-30}"
REQUESTED_BYTES=$(( REQUESTED_GPUMEM * 1024 * 1024 ))

pass() { printf "\033[0;32m  PASS\033[0m  %s\n" "$1"; }
fail() { printf "\033[0;31m  FAIL\033[0m  %s\n" "$1"; FAILED=1; }

FAILED=0

pod_jsonpath() {
  local path="$1"
  kubectl get pod "$POD" -n "$NS" -o jsonpath="$path" 2>/dev/null || true
}

pod_annotation() {
  local key="$1"
  kubectl get pod "$POD" -n "$NS" \
    -o go-template="{{ index .metadata.annotations \"$key\" }}" 2>/dev/null || true
}

logs_contain() {
  local pattern="$1"
  grep -q -- "$pattern" <<<"$LOGS"
}

logs_match() {
  local pattern="$1"
  grep -Eq -- "$pattern" <<<"$LOGS"
}

print_proof_logs() {
  echo "  --- nvidia-smi proof lines ---"
  awk -v mem="${REQUESTED_GPUMEM}MiB" '
    /^NVIDIA_VISIBLE_DEVICES=/ && !seen_visible++ { print "  " $0; next }
    /^CUDA_DEVICE_MEMORY_LIMIT_0=/ && !seen_mem_limit++ { print "  " $0; next }
    /^CUDA_DEVICE_SM_LIMIT=/ && !seen_sm_limit++ { print "  " $0; next }
    /^ld.so.preload=/ && !seen_preload++ { print "  " $0; next }
    /^mock config original total_bytes=/ && !seen_origin_total++ { print "  " $0; next }
    /GPU 0:/ && !seen_gpu++ { print "  " $0; next }
    /origin_free=.*total=/ && !seen_origin++ { print "  " $0; next }
    /usage=.*limit=/ && !seen_limit++ { print "  " $0; next }
    index($0, mem) && $0 ~ /MiB[[:space:]]*\|/ && !seen_nvidia_smi++ { print "  " $0; next }
  ' <<<"$LOGS"
}

dump_debug() {
  echo "  --- pod $NS/$POD ---"
  kubectl get pod "$POD" -n "$NS" -o yaml 2>/dev/null || true
  echo "  --- logs $NS/$POD ---"
  kubectl logs "$POD" -n "$NS" 2>/dev/null || true
  echo "  --- events $NS/$POD ---"
  kubectl get events -n "$NS" \
    --field-selector "involvedObject.kind=Pod,involvedObject.name=$POD" \
    --sort-by=.lastTimestamp 2>/dev/null || true
}

echo "=== Prepare nvidia-smi test namespace ==="
kubectl delete namespace "$NS" --wait=false 2>/dev/null || true
for _ in $(seq 1 30); do
  if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl create namespace "$NS" >/dev/null

echo ""
echo "=== Run nvidia-smi inside a HAMi GPU workload pod ==="
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NS
spec:
  restartPolicy: Never
  nodeSelector:
    gpu: "on"
  containers:
  - name: nvidia-smi
    image: $IMAGE
    imagePullPolicy: Never
    command:
    - /bin/sh
    - -c
    - |
      set -eu
      echo "NVIDIA_VISIBLE_DEVICES=\${NVIDIA_VISIBLE_DEVICES:-}"
      echo "CUDA_DEVICE_MEMORY_LIMIT_0=\${CUDA_DEVICE_MEMORY_LIMIT_0:-}"
      echo "CUDA_DEVICE_SM_LIMIT=\${CUDA_DEVICE_SM_LIMIT:-}"
      echo "ld.so.preload=\$(cat /etc/ld.so.preload 2>/dev/null || true)"
      test -n "\${NVIDIA_VISIBLE_DEVICES:-}"
      test "\${CUDA_DEVICE_MEMORY_LIMIT_0:-}" = "${REQUESTED_GPUMEM}m"
      test "\${CUDA_DEVICE_SM_LIMIT:-}" = "${REQUESTED_GPUCORES}"
      test -f /usr/local/vgpu/libvgpu.so
      grep -qx /usr/local/vgpu/libvgpu.so /etc/ld.so.preload

      # nvml-mock filters devices by /dev/nvidia<N> presence but keeps the
      # selected device's physical index. Real NVIDIA runtime setups present a
      # container-local GPU namespace where the allocated device is index 0.
      # Adapt only that namespace here; keep the profile memory untouched so
      # HAMi-core must be the component that changes Memory-Usage.
      ALLOCATED_UUID="\${NVIDIA_VISIBLE_DEVICES%%,*}"
      CUSTOM_CONFIG=/tmp/hami-vgpu-mock-nvml.yaml
      ORIGIN_TOTAL_BYTES=\$(awk '
        /^  memory:/ { in_memory=1; next }
        in_memory && /^  [[:alnum:]_]+:/ { exit }
        in_memory && \$1 == "total_bytes:" { print \$2; exit }
      ' /mock-driver/config/config.yaml)
      test "\$ORIGIN_TOTAL_BYTES" -gt "${REQUESTED_BYTES}"
      awk '
        /^devices:/ { exit }
        /^  num_devices:/ { print "  num_devices: 1"; next }
        { print }
      ' /mock-driver/config/config.yaml \\
        > "\$CUSTOM_CONFIG"
      cat >>"\$CUSTOM_CONFIG" <<YAML
      devices:
        - index: 0
          uuid: "\$ALLOCATED_UUID"
          minor_number: 0
      YAML
      awk -v want="\$ORIGIN_TOTAL_BYTES" '
        \$1 == "total_bytes:" && \$2 == want { found=1 }
        END { exit found ? 0 : 1 }
      ' "\$CUSTOM_CONFIG"
      if awk -v want="${REQUESTED_BYTES}" '
        \$1 == "total_bytes:" && \$2 == want { found=1 }
        END { exit found ? 0 : 1 }
      ' "\$CUSTOM_CONFIG"; then
        echo "custom mock config must not rewrite memory.total_bytes to requested gpumem"
        exit 1
      fi

      echo "mock config original total_bytes=\$ORIGIN_TOTAL_BYTES"
      echo "MOCK_NVML_CONFIG=\$CUSTOM_CONFIG"
      env MOCK_NVML_CONFIG="\$CUSTOM_CONFIG" /mock-driver/usr/bin/nvidia-smi -L
      env MOCK_NVML_CONFIG="\$CUSTOM_CONFIG" /mock-driver/usr/bin/nvidia-smi
    env:
    - name: LIBCUDA_LOG_LEVEL
      value: "4"
    volumeMounts:
    - name: mock-driver
      mountPath: /mock-driver
      readOnly: true
    resources:
      limits:
        "nvidia.com/gpu": "1"
        "nvidia.com/gpumem": "$REQUESTED_GPUMEM"
        "nvidia.com/gpucores": "$REQUESTED_GPUCORES"
  volumes:
  - name: mock-driver
    hostPath:
      path: /var/lib/nvml-mock/driver
      type: Directory
EOF

SCHEDULER=""
for _ in $(seq 1 24); do
  SCHEDULER=$(pod_jsonpath '{.spec.schedulerName}')
  if [ "$SCHEDULER" = "hami-scheduler" ]; then
    break
  fi
  sleep 5
done

if [ "$SCHEDULER" = "hami-scheduler" ]; then
  pass "webhook rewrote nvidia-smi pod to hami-scheduler"
else
  dump_debug
  fail "schedulerName is '$SCHEDULER' (expected hami-scheduler)"
fi

PHASE=""
for _ in $(seq 1 60); do
  PHASE=$(pod_jsonpath '{.status.phase}')
  if [ "$PHASE" = "Succeeded" ] || [ "$PHASE" = "Failed" ]; then
    break
  fi
  sleep 5
done

LOGS="$(kubectl logs "$POD" -n "$NS" 2>/dev/null || true)"
NODE="$(pod_jsonpath '{.spec.nodeName}')"
BIND_PHASE="$(pod_annotation 'hami.io/bind-phase')"
ALLOCATED="$(pod_annotation 'hami.io/vgpu-devices-allocated')"

if [ "$PHASE" = "Succeeded" ] &&
   [ -n "$NODE" ] &&
   [ "$BIND_PHASE" = "success" ] &&
   [ -n "$ALLOCATED" ] &&
   logs_contain 'NVIDIA_VISIBLE_DEVICES=' &&
   logs_contain "CUDA_DEVICE_MEMORY_LIMIT_0=${REQUESTED_GPUMEM}m" &&
   logs_contain "CUDA_DEVICE_SM_LIMIT=${REQUESTED_GPUCORES}" &&
   logs_contain 'ld.so.preload=/usr/local/vgpu/libvgpu.so' &&
   logs_contain 'mock config original total_bytes=' &&
   logs_contain 'HAMI-core' &&
   logs_contain 'loaded nvml libraries' &&
   logs_contain 'GPU 0:' &&
   logs_match "origin_free=.*total=[0-9]+" &&
   logs_match "limit=${REQUESTED_BYTES}" &&
   logs_match "/[[:space:]]+${REQUESTED_GPUMEM}MiB"; then
  pass "nvidia-smi completed in pod on $NODE through HAMi-core preload and mock NVML"
  pass "HAMi-core nvmlDeviceGetMemoryInfo override fired (limit=${REQUESTED_BYTES})"
  pass "nvidia-smi reported the requested ${REQUESTED_GPUMEM}MiB vGPU memory limit"
  print_proof_logs
else
  dump_debug
  fail "nvidia-smi pod did not complete through HAMi-core with the requested memory cap (phase=$PHASE node=$NODE bind=$BIND_PHASE allocated=${ALLOCATED:+present})"
fi

echo ""
echo "=== Summary ==="
if [ $FAILED -eq 0 ]; then
  kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
  printf "\033[0;32m  ✓ in-pod nvidia-smi works through HAMi scheduler + DP + HAMi-core preload on nvml-mock\033[0m\n"
  exit 0
else
  echo "Keeping namespace $NS for failure debug collection"
  printf "\033[0;31m  ✗ nvidia-smi workload check failed\033[0m\n"
  exit 1
fi
