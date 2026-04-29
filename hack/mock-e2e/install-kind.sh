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

set -euo pipefail

KIND_VERSION="${KIND_VERSION:-v0.31.0}"
KIND_ARCH="${KIND_ARCH:-linux-amd64}"
KIND_URL="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${KIND_ARCH}"
KIND_BIN="${KIND_BIN:-/usr/local/bin/kind}"

tmp_kind="$(mktemp)"
trap 'rm -f "$tmp_kind"' EXIT

for attempt in 1 2 3 4 5; do
  echo "Downloading kind ${KIND_VERSION} for ${KIND_ARCH} (attempt ${attempt}/5)"
  if curl --fail --show-error --location \
    --retry 5 --retry-delay 2 --retry-all-errors \
    "$KIND_URL" -o "$tmp_kind"; then
    sudo install -m 0755 "$tmp_kind" "$KIND_BIN"
    "$KIND_BIN" version
    exit 0
  fi

  sleep "$((attempt * 5))"
done

echo "ERROR: failed to download kind from ${KIND_URL}" >&2
exit 1
