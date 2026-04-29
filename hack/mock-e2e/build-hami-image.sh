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

HAMI_IMAGE_REPO="${HAMI_IMAGE_REPO:-hami-mock-e2e}"
HAMI_IMAGE_TAG="${HAMI_IMAGE_TAG:-ci}"
HAMI_BUILD_VERSION="${HAMI_BUILD_VERSION:-$HAMI_IMAGE_TAG}"
GOLANG_IMAGE="${HAMI_BUILD_GOLANG_IMAGE:-golang:1.26.2-bookworm}"
NVIDIA_IMAGE="${HAMI_BUILD_NVIDIA_IMAGE:-nvidia/cuda:12.3.2-devel-ubuntu20.04}"
DEST_DIR="${HAMI_BUILD_DEST_DIR:-/usr/local/vgpu/}"

IMAGE="$HAMI_IMAGE_REPO:$HAMI_IMAGE_TAG"

if [ ! -f libvgpu/build.sh ]; then
  echo "ERROR: libvgpu submodule is missing; checkout with submodules enabled" >&2
  exit 1
fi

echo "=== Build HAMi image from current checkout ==="
echo "image: $IMAGE"
docker build \
  --build-arg VERSION="$HAMI_BUILD_VERSION" \
  --build-arg GOLANG_IMAGE="$GOLANG_IMAGE" \
  --build-arg NVIDIA_IMAGE="$NVIDIA_IMAGE" \
  --build-arg DEST_DIR="$DEST_DIR" \
  --build-arg GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}" \
  -t "$IMAGE" \
  -f docker/Dockerfile .

docker image inspect "$IMAGE" --format='built image {{.RepoTags}} {{.Id}}'
