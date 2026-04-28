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

# Failure-path debug collection. Modeled on mock-gpu-ci-demo's checklist:
# always-on dumps + per-init-container logs + kind export.
#
# Usage: collect-debug.sh <label>
#   <label> goes into /tmp/debug<label>/... and is just a tag for humans.
#
# Idempotent. Best-effort: every command tolerated to fail; we want as
# many artifacts as possible even if the cluster is partly broken.

set -u
LABEL="${1:-run}"
DEBUG_DIR="${DEBUG_DIR:-/tmp/debug}"
mkdir -p "$DEBUG_DIR"

echo "Collecting debug artifacts to $DEBUG_DIR (label=$LABEL)"

# --- always-on snapshots
kubectl get all -A -o wide > "$DEBUG_DIR/all.txt" 2>&1 || true
kubectl get nodes -o wide --show-labels > "$DEBUG_DIR/nodes.txt" 2>&1 || true
kubectl get nodes -o yaml > "$DEBUG_DIR/nodes.yaml" 2>&1 || true
kubectl get events -A --sort-by=.lastTimestamp > "$DEBUG_DIR/events.txt" 2>&1 || true

# --- describe every pod that's not Running/Succeeded
{
  echo "=== Pod descriptions for non-Running/Succeeded pods ==="
  kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 != "Running" && $4 != "Completed" && $4 != "STATUS"' \
    | while read -r ns name _; do
        echo ""
        echo "--- $ns/$name ---"
        kubectl describe pod -n "$ns" "$name" 2>&1 || true
      done
} > "$DEBUG_DIR/unhealthy-pods.txt" 2>&1 || true

# --- per-pod logs: regular containers AND init containers separately
# (init containers are easy to miss with `kubectl logs` and routinely hide
# the actual root cause behind a "still waiting" main container.)
mkdir -p "$DEBUG_DIR/logs"
kubectl get pods -A --no-headers 2>/dev/null \
  | awk '{print $1, $2}' \
  | while read -r ns name; do
      [ -z "$name" ] && continue
      # regular containers
      for c in $(kubectl get pod -n "$ns" "$name" \
                  -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
        kubectl logs -n "$ns" "$name" -c "$c" --tail=300 \
          > "$DEBUG_DIR/logs/${ns}__${name}__${c}.log" 2>&1 || true
      done
      # init containers
      for c in $(kubectl get pod -n "$ns" "$name" \
                  -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null); do
        kubectl logs -n "$ns" "$name" -c "$c" --tail=300 \
          > "$DEBUG_DIR/logs/${ns}__${name}__init__${c}.log" 2>&1 || true
      done
    done

# --- HAMi-specific
kubectl get cm -n hami-system -o yaml > "$DEBUG_DIR/hami-configmaps.yaml" 2>&1 || true
kubectl describe nodes -l gpu=on > "$DEBUG_DIR/integration-node.txt" 2>&1 || true

# --- nvml-mock + FGO (smoke + matrix)
kubectl get cm -A -l run.ai/gpu-profile=true -o yaml > "$DEBUG_DIR/nvml-mock-profiles.yaml" 2>&1 || true
kubectl get cm -n gpu-operator -o yaml > "$DEBUG_DIR/fgo-cms.yaml" 2>&1 || true

# --- KWOK (scale only)
kubectl get nodes -l type=kwok -o yaml > "$DEBUG_DIR/kwok-nodes.yaml" 2>&1 || true

# --- kind export (containerd, kubelet, etcd, ...)
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-hami-mock-e2e}"
kind export logs "$DEBUG_DIR/kind-logs" --name "$KIND_CLUSTER_NAME" 2>/dev/null || true

echo "Debug artifacts ready in $DEBUG_DIR"
ls -la "$DEBUG_DIR" 2>&1 || true
