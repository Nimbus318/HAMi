# Mock GPU E2E

Lightweight GitHub Actions E2E for HAMi that runs without any physical GPU.
Modeled after [`Nimbus318/mock-gpu-ci-demo`](https://github.com/Nimbus318/mock-gpu-ci-demo).

## Why this exists

HAMi's existing `call-e2e.yaml` runs on self-hosted GPU runners (VSphere VM
with a Tesla P4). That provides real-GPU coverage, but it also means:

- Contributors do not get a cheap, reproducible E2E signal on ordinary GitHub
  hosted runners.
- Only one real GPU model is exercised at a time.
- The chart's built-in `mockDevicePlugin` is too primitive to reflect real
  NVML behavior (no per-profile memory, no per-device UUID, no cudaCompute
  capability) so HAMi's scheduler logic that branches on those fields can't
  be validated against it.

This workflow uses [NVIDIA/k8s-test-infra](https://github.com/NVIDIA/k8s-test-infra)'s
`nvml-mock` (real CGo-built `libnvidia-ml.so` with per-profile YAML configs)
plus [run-ai/fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator)
+ KWOK for scale tests, all on `ubuntu-latest`.

The shape of this workflow follows lessons from a sibling demo repo:
[`Nimbus318/mock-gpu-ci-demo`](https://github.com/Nimbus318/mock-gpu-ci-demo)
green-runs the same pattern against the upstream NVIDIA DRA driver. The
[design notes there](https://github.com/Nimbus318/mock-gpu-ci-demo/blob/main/docs/e2e-design-notes.md)
catalog the failure modes (kind/node version drift, mock driver root
mistakes, ResourceClaim API skew, KWOK boundaries) — every constraint they
called out is now baked into this workflow.

## Trigger Policy

This workflow is intentionally split by cost and confidence:

| Trigger | Jobs | Intent |
|---|---|---|
| `pull_request` to `master` | `smoke` only | cheap PR gate for install + mock NVML + scheduler allocation |
| `push` to `ci/**` | `smoke` only | branch-only iteration without opening a PR |
| `push` to `master` | `smoke` + `matrix` + `scale` | full regression after merge |
| `workflow_dispatch`, `run_full=false` | `smoke` only | manual quick check |
| `workflow_dispatch`, `run_full=true` | `smoke` + `matrix` + `scale` | manual full check before merge or upstream submission |
| weekly `schedule` | `smoke` + `matrix` + `scale` | catches dependency, chart, and Kubernetes drift |

Docs, examples, and Markdown-only changes are ignored by the push/PR triggers.

## Job structure

| Job | When | What | Current measured status |
|---|---|---|---|
| **smoke** | PR / `ci/**` push / dispatch / schedule / master push | h100 profile, HAMi nvidia DP backed by real mock NVML; verifies webhook, scheduler filter/bind, DP Allocate success, in-pod `nvidia-smi`, and oversized gpumem rejection | 5m58s on run `25102878975` |
| **matrix** | dispatch (`run_full=true`) / weekly / master push | smoke flow × 3 profiles in parallel (a100/gb200/l40s) | a100 6m15s, gb200 6m15s, l40s 5m37s on run `25102878975` |
| **scale** | dispatch (`run_full=true`) / weekly / master push | FGO + KWOK fake nodes + mock HAMi node annotations + HAMi scheduler binds N pods to distinct fake nodes | 5m28s on run `25102878975` |

`matrix` and `scale` `needs: smoke` — if smoke fails the expensive jobs skip.

## Runtime Notes

The upstream ginkgo `overcommit` spec is disabled by default. On run
`25046437513`, the verified mock chain completed before ginkgo, then the
ginkgo step spent 7m8s waiting for an event that is not produced in this mock
environment. Keep ginkgo as a manual diagnostic only; the script now defaults
to a 2m suite timeout:

```bash
gh workflow run mock-gpu-e2e.yaml --ref <branch> \
  -f run_full=false -f run_ginkgo=true
```

Manual full run `25102878975` completed in 12m41s wall-clock after dispatch.
The push-only smoke run on the same commit (`25102607337`) completed in 5m42s.
`install-kind.sh` retries the kind binary download so transient 5xx responses
from `kind.sigs.k8s.io` do not fail the E2E before the cluster exists.

## Architecture

```
                     GHA ubuntu-latest runner
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
   build nvml-mock      build HAMi image     install kind cluster
        │                     │                     │
        └─────────┬───────────┘                     │
                  ▼                                 ▼
        helm install nvml-mock          4-node kind topology:
        on integration node               cp + integration + 2× scale
        → /var/lib/nvml-mock/driver/...
                  │
                  ▼
        helm install HAMi
        + kubectl patch DP DaemonSet:
          · LD_LIBRARY_PATH=/driver-root/usr/lib64
          · bind-mount mock libnvidia-ml.so.1
                  │
                  ▼
        HAMi nvidia DP dlopen("libnvidia-ml.so.1")
        → loads mock NVML
        → enumerates 8 fake GPUs
        → advertises nvidia.com/gpu=8 on integration node
                  │
                  ▼
        verify-smoke.sh
        → scheduler/extender pods are Running
        → DP pod runs on the mock GPU node
        → node advertises nvidia.com/gpu=8
        → mock driver root is present on the host
                  │
                  ▼
        verify-scheduler.sh
        → webhook rewrites GPU pods to hami-scheduler
        → HAMi filter patches vgpu allocation annotations
        → HAMi bind sets bind-phase=allocating
        → HAMi DP Allocate flips bind-phase=success
        → impossible gpumem request stays Pending with FilteringFailed
                  │
                  ▼
        verify-nvidia-smi.sh
        → creates a real GPU workload pod on the mock-NVML node
        → HAMi webhook/scheduler/DP allocate the pod
        → HAMi DP injects /etc/ld.so.preload + libvgpu.so
        → test harness gives nvml-mock a one-device, index-0 config for the
          allocated UUID because the hostPath mock driver does not provide
          NVIDIA runtime visible-device remapping
        → /mock-driver/usr/bin/nvidia-smi runs through HAMi-core's NVML hook
        → libvgpu calls through to mock libnvidia-ml.so.1
        → HAMi-core changes nvmlDeviceGetMemoryInfo_v2 from the full mock
          framebuffer to CUDA_DEVICE_MEMORY_LIMIT_0
        → nvidia-smi reports the requested vGPU memory limit
```

`verify-nvidia-smi.sh` treats the `Memory-Usage` total printed by `nvidia-smi`
as a gating assertion. HAMi DP injects per-container limits such as
`CUDA_DEVICE_MEMORY_LIMIT_0=8192m`; real NVIDIA runtime setups also remap the
allocated device into the container-visible GPU set. Because this mock harness
hostPath-mounts the driver root directly, nvml-mock can expose the selected
device as visible index 0 while `nvmlDeviceGetIndex()` still returns the
physical mock index, which makes HAMi-core's NVML-to-CUDA mapping miss the
device. The test adapts only the mock device namespace: after scheduler and DP
allocation, it writes a per-process `MOCK_NVML_CONFIG` under `/tmp` with a
single `devices:` entry for the allocated UUID at `index: 0`. It does **not**
rewrite `device_defaults.memory.total_bytes`; the config still reports the full
profile framebuffer to raw mock NVML. The gating proof is the HAMi-core debug
sequence: `origin_free=... total=<full profile bytes>`, then
`usage=... limit=<requested gpumem bytes>`, then the `nvidia-smi` table showing
the requested MiB cap. This keeps the assertion on HAMi-core's
`nvmlDeviceGetMemoryInfo_v2` override instead of faking the final table through
the mock profile itself.

For the **scale** job, we swap nvml-mock's role with FGO's
kwok-gpu-device-plugin to advertise GPU resources on KWOK virtual nodes — no
Linux kernel hooks needed for KWOK pods. KWOK nodes do not have a real kubelet,
so they cannot run HAMi's device plugin and `kubectl exec`/in-pod
`nvidia-smi` is out of scope for that job. Only HAMi's scheduler is installed
(`devicePlugin.enabled=false`). Because HAMi's scheduler builds its device
cache from `hami.io/node-nvidia-register` annotations written by HAMi's device
plugin, `install-kwok.sh` writes a minimal mock form of that annotation onto
each KWOK node. FGO owns the Kubernetes resource capacity; the annotation owns
HAMi scheduler's internal device view.

Scale pods are pinned one-per-KWOK-node with `hami.io/mock-scale-index`.
Without HAMi's device plugin, a successful bind leaves HAMi's node lock in
place until timeout; this mode therefore verifies multi-node scheduler binding,
not repeated allocation on the same node. If we need scale coverage that also
executes `nvidia-smi`, add a separate real-kind-worker scale job instead of
trying to make KWOK execute containers.

## Triggering

When testing from a fork, GitHub may keep Actions disabled until the repository
owner explicitly enables them in the Actions tab.

After enabling:

```bash
# Auto on PR and ci/** branch push — smoke only
git push

# Manual full battery on an experiment branch
gh workflow run mock-gpu-e2e.yaml --ref ci/mock-gpu-e2e \
  -f run_full=true -f kwok_node_count=10

# Optional slow diagnostic for the upstream ginkgo overcommit spec
gh workflow run mock-gpu-e2e.yaml --ref ci/mock-gpu-e2e \
  -f run_full=false -f run_ginkgo=true
```

## Development Workflow Hygiene

Keep CI experiments on a topic branch such as `ci/mock-gpu-e2e`. A PR is not
required while iterating locally or in a fork; `push` to `ci/**` already runs
the smoke job. When working from a fork, keep `master` aligned with
`Project-HAMi/HAMi` until there is a deliberate fork change to keep.

Self-hosted-runner workflows should be guarded with
`github.repository == 'Project-HAMi/HAMi'`. Forks do not have that runner pool,
so unguarded jobs sit queued forever.

## Scope

This demo covers (these are the gating checks):

- ✅ HAMi chart installs cleanly on a vanilla kind cluster
- ✅ HAMi nvidia DP can talk to NVML (via mock lib) — real go-nvml code path
- ✅ HAMi scheduler + extender pods reach Ready
- ✅ DP advertises `nvidia.com/gpu` resources backed by mock NVML
- ✅ HAMi admission webhook rewrites GPU pods to `hami-scheduler`
- ✅ HAMi scheduler filters, annotates, and binds a schedulable GPU pod
- ✅ HAMi nvidia DP `Allocate` marks the pod bind phase as `success`
- ✅ A real workload pod executes `nvidia-smi` through HAMi-core's preload/NVML hook against mock NVML after HAMi DP allocation
- ✅ `nvidia-smi` reports the requested `nvidia.com/gpumem` cap instead of the mock GPU profile's full framebuffer
- ✅ HAMi scheduler rejects an impossible GPU memory request with `FilteringFailed`
- ✅ KWOK scale verifies multi-node scheduler binding and allocation annotations

The existing ginkgo `overcommit` spec is available as a manual diagnostic only.
It was written for HAMi's self-hosted GPU E2E shape, not for this mock harness.
In particular, it creates the overcommit pod in `hami-system`, a
namespace excluded by HAMi's mutating webhook, so that pod is not rewritten to
`hami-scheduler`. The gating mock check uses purpose-built pods in a normal
test namespace and explicitly verifies webhook rewrite, scheduler filter/bind,
DP `Allocate`, and `FilteringFailed` rejection.

One easy trap: do not disable `scheduler.leaderElect` in this chart install.
The scheduler Service selects `hami.io/scheduler-role=leader`; if there is no
leader-labelled scheduler pod, the webhook object can have a valid `caBundle`
but still have no Service endpoint. Because the chart sets `failurePolicy:
Ignore`, pods then fall through to `default-scheduler`.

It deliberately does NOT cover (out of scope by design):

- Real CUDA kernel execution (the existing test_pod.go "with CUDA configuration"
  spec is skipped via `--skip`)
- CUDA-runtime hook behavior beyond the preload/NVML path (no real CUDA workload inside containers)
- HAMi extender's filter event format (the test relies on it)
- HAMi DP or in-pod `nvidia-smi` on KWOK nodes (KWOK has no real kubelet)
- Multi-node NVLink fabric

For those, keep using the upstream self-hosted GPU runner.

## Pinned versions

Per the parent project's design notes, kind + node image are part of the
test contract and must be pinned tightly:

| | Pinned to |
|---|---|
| kind | `v0.31.0` |
| node image | `kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f` |
| HAMi image | built from the current checkout and loaded into kind as `hami-mock-e2e:${GITHUB_SHA}` |
| nvml-mock | latest from `NVIDIA/k8s-test-infra@main` (built each run) |

Keep the kind/node image pins explicit. The HAMi image should stay tied to the
current checkout so chart and binary behavior do not drift apart. The HAMi
checkout must include submodules because the image build needs `libvgpu`.

## Files

```
.github/workflows/mock-gpu-e2e.yaml
hack/mock-e2e/
├── setup-cluster.sh                  # 4-node kind, pinned node image
├── install-kind.sh                   # retrying kind binary installer
├── build-hami-image.sh               # build current checkout into a local
│                                     #   hami-mock-e2e image for kind
├── install-nvml-mock.sh              # build + helm install nvml-mock; copies
│                                     #   /dev nodes into driver/dev so any
│                                     #   probing of <driver-root>/dev works
├── install-hami-on-mock.sh           # helm install HAMi + patch DP DaemonSet
│                                     #   to bind-mount mock libnvidia-ml.so
│                                     #   over the cuda image's stub library
├── install-hami-scheduler-only.sh    # scale variant: HAMi DP disabled
├── install-fgo.sh                    # scale variant
├── install-kwok.sh                   # scale variant: KWOK nodes + mock HAMi
│                                     #   node-device annotations
├── verify-smoke.sh                   # 4 checks; polls for async DP advertise
├── verify-scheduler.sh               # webhook + scheduler + DP Allocate checks
├── verify-nvidia-smi.sh              # runs nvidia-smi in a GPU workload pod
├── verify-scale.sh                   # advertise + annotate + bind + annotations
├── run-ginkgo.sh                     # ginkgo --focus="overcommit pods"
├── collect-debug.sh                  # failure-path artifact collector
│                                     #   (init containers logged separately)
└── README.md                         # this file
```
