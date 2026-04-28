# Mock E2E (Nimbus318/HAMi fork only)

Free-tier-friendly GitHub Actions E2E for HAMi that runs without any real
GPU. Modeled after [`Nimbus318/mock-gpu-ci-demo`](https://github.com/Nimbus318/mock-gpu-ci-demo).

## Why this exists

Project-HAMi's existing `call-e2e.yaml` runs on self-hosted GPU runners
(VSphere VM with a Tesla P4). That works for upstream but means:

- Forks have no E2E coverage — contributors push and pray.
- Only one GPU model is exercised at a time.
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

## Job structure

| Job | When | What | Current measured status |
|---|---|---|---|
| **smoke** | every push / PR / dispatch / schedule | h100 profile, HAMi nvidia DP backed by real mock NVML lib | 2m52s on green run `25049447573` |
| **matrix** | dispatch (`run_full=true`) / weekly | smoke flow × 3 profiles in parallel (a100/gb200/l40s) | a100 3m07s, l40s 2m54s, gb200 4m01s on green run `25049447573` |
| **scale** | dispatch / weekly | FGO + 10 KWOK fake nodes + mock HAMi node annotations + HAMi scheduler binds N pods | 3m00s on green run `25049447573` |

`matrix` and `scale` `needs: smoke` — if smoke fails the expensive jobs skip.

## Runtime Notes

The upstream ginkgo `overcommit` spec is disabled by default. On run
`25046437513`, the verified mock chain completed before ginkgo, then the
ginkgo step spent 7m8s waiting for an event that is not produced in this mock
environment. Keep ginkgo as a manual diagnostic only; the script now defaults
to a 2m suite timeout:

```bash
gh workflow run mock-e2e.yaml --ref <branch> \
  -f run_full=false -f run_ginkgo=true
```

Green full run `25049447573` took about 7m wall-clock from dispatch to final
job completion.

## Architecture

```
                     GHA ubuntu-latest runner
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
   build nvml-mock      pull HAMi image      install kind cluster
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
```

For the **scale** job, we swap nvml-mock's role with FGO's
kwok-gpu-device-plugin to advertise GPU resources on KWOK virtual nodes — no
Linux kernel hooks needed for KWOK pods. Only HAMi's scheduler is installed
(`devicePlugin.enabled=false`). Because HAMi's scheduler builds its device
cache from `hami.io/node-nvidia-register` annotations written by HAMi's device
plugin, `install-kwok.sh` writes a minimal mock form of that annotation onto
each KWOK node. FGO owns the Kubernetes resource capacity; the annotation owns
HAMi scheduler's internal device view.

Scale pods are pinned one-per-KWOK-node with `hami.io/mock-scale-index`.
Without HAMi's device plugin, a successful bind leaves HAMi's node lock in
place until timeout; this mode therefore verifies multi-node scheduler binding,
not repeated allocation on the same node.

## Triggering

Workflows are **disabled by default in the fork**. Re-enable in
GitHub Actions UI → Actions tab → "I understand my workflows, go ahead and
enable them".

After enabling:

```bash
# Auto on push to master / PR — smoke only
git push

# Manual full battery
gh workflow run mock-e2e.yaml --ref master \
  -f run_full=true -f kwok_node_count=10

# Optional slow diagnostic for the upstream ginkgo overcommit spec
gh workflow run mock-e2e.yaml --ref master \
  -f run_full=false -f run_ginkgo=true
```

## Fork Workflow Hygiene

Keep fork-only CI experiments on a branch in `Nimbus318/HAMi`, then open a PR
back to `Nimbus318/HAMi:master`. Do not push exploratory commits straight to
`master`, and never push them to `Project-HAMi/HAMi`.

Self-hosted-runner workflows should be guarded with
`github.repository == 'Project-HAMi/HAMi'`. Forks do not have that runner pool,
so unguarded jobs sit queued forever.

## Scope

This demo covers (these are the gating checks):

- ✅ HAMi chart installs cleanly on a vanilla kind cluster
- ✅ HAMi nvidia DP can talk to NVML (via mock lib) — real go-nvml code path
- ✅ HAMi scheduler + extender pods reach Ready
- ✅ DP advertises `nvidia.com/gpu` resources backed by mock NVML
- matrix and scale coverage are still pending a green full run

The existing ginkgo `overcommit` spec is available as a manual diagnostic only.
Reason: that spec asserts on HAMi-scheduler-extender event reasons
(`FilteringFailed` / `no available node`) that only fire when the full
scheduling chain is intact. On mock, two parts of that chain are missing:

1. The mock-backed DP advertises `nvidia.com/gpu` count but **not**
   `nvidia.com/gpumem` / `nvidia.com/gpucores` capacity (HAMi tracks
   those internally, not via Node.status.allocatable). kube-scheduler
   sees the pod's gpumem/gpucores requests as Insufficient and rejects
   before the extender ever runs.
2. The test pod is created in the `hami-system` namespace, which HAMi's
   mutating webhook skips (otherwise it would loop on its own pods),
   so `schedulerName` stays `default-scheduler` instead of being
   rewritten to `hami-scheduler`.

Both gaps are intrinsic to mocking HAMi at the K8s API layer. To keep
that spec passing here would need either custom advertisement of gpumem
capacity (changes HAMi DP behavior) or a custom test pod with
`schedulerName: hami-scheduler` (changes test source). Neither is in
scope for a fork-only smoke harness.

It deliberately does NOT cover (out of scope by design):

- Real CUDA kernel execution (the existing test_pod.go "with CUDA configuration"
  spec is skipped via `--skip`)
- libvgpu CUDA-hook behavior (no real CUDA inside containers)
- HAMi extender's filter event format (the test relies on it)
- Multi-node NVLink fabric

For those, keep using the upstream self-hosted GPU runner.

## Pinned versions

Per the parent project's design notes, kind + node image are part of the
test contract and must be pinned tightly:

| | Pinned to |
|---|---|
| kind | `v0.31.0` |
| node image | `kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f` |
| HAMi image | `projecthami/hami:v2.8.1` (tagged release) |
| nvml-mock | latest from `NVIDIA/k8s-test-infra@main` (built each run) |

Bump these together, never just one of them.

## Files

```
.github/workflows/mock-e2e.yaml
hack/mock-e2e/
├── setup-cluster.sh                  # 4-node kind, pinned node image
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
├── verify-scale.sh                   # 3 checks (advertise + annotate + bind)
├── run-ginkgo.sh                     # ginkgo --focus="overcommit pods"
├── collect-debug.sh                  # failure-path artifact collector
│                                     #   (init containers logged separately)
└── README.md                         # this file
```
