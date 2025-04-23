<div align="center">

English version | [中文版](README_cn.md)

<img src="imgs/hami-horizontal-colordark.png" width="600px">

# HAMi: Heterogeneous AI Computing Virtualization Middleware

<p align="center">
  Efficient sharing and management of AI accelerators (GPU, NPU, etc.) in Kubernetes clusters.<br />
  Improve hardware utilization by 3-5x with zero code changes.
</p>

<br/>

[![LICENSE](https://img.shields.io/github/license/Project-HAMi/HAMi.svg)](/LICENSE)
[![build status](https://github.com/Project-HAMi/HAMi/actions/workflows/ci.yaml/badge.svg)](https://github.com/Project-HAMi/HAMi/actions/workflows/ci.yaml)
[![Releases](https://img.shields.io/github/v/release/Project-HAMi/HAMi)](https://github.com/Project-HAMi/HAMi/releases/latest)
[![docker pulls](https://img.shields.io/docker/pulls/projecthami/hami.svg)](https://hub.docker.com/r/projecthami/hami)
[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2FProject-HAMi%2FHAMi.svg?type=shield)](https://app.fossa.com/projects/git%2Bgithub.com%2FProject-HAMi%2FHAMi?ref=badge_shield)
[![slack](https://img.shields.io/badge/Slack-Join%20Slack-blue)](https://cloud-native.slack.com/archives/C07T10BU4R2)
[![website](https://img.shields.io/badge/website-blue)](http://project-hami.io)

<p align="center">
  <img src="./imgs/hami-hero-image.png" width="800px" />
</p>

> HAMi is a sandbox project of [Cloud Native Computing Foundation](https://cncf.io/) (CNCF)

</div>

## What HAMi Solves

<table>
<tr>
<td width="60%">

**Problem**: AI devices (GPUs, NPUs) in Kubernetes are inefficiently utilized:
- Each pod gets an entire device, even when using a fraction of its capacity
- Expensive hardware sits idle much of the time
- Managing different types of accelerators requires different tools

**Solution**: HAMi enables fine-grained sharing of AI devices among pods with proper isolation:
- Share compute cores and memory across multiple workloads
- Set hard resource limits for predictable performance
- Manage all device types through a unified interface
- Improve utilization by 3-5x with zero application changes

</td>
<td width="40%">
<img src="./imgs/utilization-comparison.png" width="100%">
</td>
</tr>
</table>

## Key Features

<div align="center">
<table>
<tr>
<td align="center" width="33%">
<img src="./imgs/icon-sharing.png" width="80px"><br/>
<b>Device Sharing</b><br/>
Multiple workloads share the same physical device with proper isolation
</td>
<td align="center" width="33%">
<img src="./imgs/icon-isolation.png" width="80px"><br/>
<b>Resource Isolation</b><br/>
Hard limits on device memory and compute resources
</td>
<td align="center" width="33%">
<img src="./imgs/icon-multi-device.png" width="80px"><br/>
<b>Multi-Device Support</b><br/>
Works with NVIDIA, Cambricon, Hygon, Ascend and more
</td>
</tr>
<tr>
<td align="center" width="33%">
<img src="./imgs/icon-zero-changes.png" width="80px"><br/>
<b>Zero Code Changes</b><br/>
Compatible with existing ML/AI applications
</td>
<td align="center" width="33%">
<img src="./imgs/icon-dashboard.png" width="80px"><br/>
<b>Visual Dashboard</b><br/>
Monitor all devices from a unified interface
</td>
<td align="center" width="33%">
<img src="./imgs/icon-scheduler.png" width="80px"><br/>
<b>Smart Scheduling</b><br/>
Optimized placement based on device topology
</td>
</tr>
</table>
</div>

## Quick Start (5 minutes)

Label your GPU nodes:
```bash
kubectl label nodes {nodeid} gpu=on
```

Install HAMi using Helm:
```bash
helm repo add hami-charts https://project-hami.github.io/HAMi/
helm install hami hami-charts/hami -n kube-system
```

Run a sample GPU-sharing workload:
```bash
kubectl apply -f https://raw.githubusercontent.com/Project-HAMi/HAMi/master/examples/nvidia/default_use.yaml
```

<details>
<summary><b>View example YAML file</b></summary>

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example-gpu-sharing
spec:
  containers:
  - name: gpu-container
    image: nvidia/cuda:11.6.2-base-ubuntu20.04
    command: ["sleep", "infinity"]
    resources:
      limits:
        nvidia.com/gpu: 1      # Request one physical GPU
        nvidia.com/gpumem: 3000 # Allocate 3GB GPU memory
```

</details>

## Choose Your Path

<div align="center">
<table>
<tr>
<td align="center" width="20%">
<img src="./imgs/icon-developer.png" width="64px"><br/>
<b>Developer</b><br/>
<a href="#quick-start-5-minutes">Quick Start Guide</a>
</td>
<td align="center" width="20%">
<img src="./imgs/icon-platform.png" width="64px"><br/>
<b>Platform Engineer</b><br/>
<a href="docs/installation.md">Installation Guide</a>
</td>
<td align="center" width="20%">
<img src="./imgs/icon-ml.png" width="64px"><br/>
<b>ML Engineer</b><br/>
<a href="examples/ml_workloads/">ML Examples</a>
</td>
<td align="center" width="20%">
<img src="./imgs/icon-mlops.png" width="64px"><br/>
<b>MLOps Team</b><br/>
<a href="#dashboard">HAMi Dashboard</a>
</td>
<td align="center" width="20%">
<img src="./imgs/icon-architect.png" width="64px"><br/>
<b>Cloud Architect</b><br/>
<a href="#supported-devices">Supported Devices</a>
</td>
</tr>
</table>
</div>

## Dashboard

HAMi includes a powerful web dashboard for monitoring and managing all AI devices:

<div align="center">
<img src="./imgs/dashboard-example.png" width="800px" />
</div>

Access after installation:
```bash
# Enable port-forwarding to access the dashboard
kubectl port-forward -n kube-system svc/hami-webui 8080:80
# Open http://localhost:8080 in your browser
```

## 🔧 Device Virtualization

HAMi virtualizes AI accelerators allowing fine-grained resource allocation:

### Memory & Compute Isolation

<div align="center">
<img src="./imgs/example.png" width="600px" />
</div>

In your deployments, simply specify:
```yaml
resources:
  limits:
    nvidia.com/gpu: 1     # Number of physical GPUs needed
    nvidia.com/gpumem: 3000  # Memory per GPU (MB)
```

Inside the container, the application will only see the allocated resources:

<div align="center">
<img src="./imgs/hard_limit.jpg" width="600px" />
</div>

## Common Deployment Templates

<details>
<summary><b>Basic GPU memory sharing</b></summary>

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-mem-pod
spec:
  containers:
  - name: cuda-container
    image: nvidia/cuda:11.6.2-base-ubuntu20.04
    command: ["sleep", "infinity"]
    resources:
      limits:
        nvidia.com/gpu: 1      # Request 1 physical GPU
        nvidia.com/gpumem: 4000 # Allocate 4GB GPU memory
```
</details>

<details>
<summary><b>ML training job with multiple GPUs</b></summary>

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ml-training
spec:
  template:
    spec:
      containers:
      - name: training
        image: pytorch/pytorch:1.12.0-cuda11.3-cudnn8-runtime
        command: ["python", "train.py"]
        resources:
          limits:
            nvidia.com/gpu: 2      # Request 2 physical GPUs
            nvidia.com/gpumem: 8000 # Allocate 8GB per GPU
      restartPolicy: Never
```
</details>

<details>
<summary><b>Inference service with compute limits</b></summary>

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inference-service
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: inference
        image: tensorflow/tensorflow:2.9.1-gpu
        ports:
        - containerPort: 8501
        resources:
          limits:
            nvidia.com/gpu: 1      # Request 1 physical GPU
            nvidia.com/gpumem: 2000 # Allocate 2GB GPU memory
            nvidia.com/gpucores: 30 # Use 30% of GPU compute
```
</details>

## Supported Devices

<div align="center">
<table>
<tr>
<td align="center">
<img src="./imgs/nvidia-logo.png" width="80px"><br/>
<a href="https://github.com/Project-HAMi/HAMi#preparing-your-gpu-nodes">NVIDIA GPU</a>
</td>
<td align="center">
<img src="./imgs/cambricon-logo.png" width="80px"><br/>
<a href="docs/cambricon-mlu-support.md">Cambricon MLU</a>
</td>
<td align="center">
<img src="./imgs/hygon-logo.png" width="80px"><br/>
<a href="docs/hygon-dcu-support.md">Hygon DCU</a>
</td>
<td align="center">
<img src="./imgs/iluvatar-logo.png" width="80px"><br/>
<a href="docs/iluvatar-gpu-support.md">Iluvatar GPU</a>
</td>
</tr>
<tr>
<td align="center">
<img src="./imgs/mthreads-logo.png" width="80px"><br/>
<a href="docs/mthreads-support.md">Mthreads GPU</a>
</td>
<td align="center">
<img src="./imgs/ascend-logo.png" width="80px"><br/>
<a href="https://github.com/Project-HAMi/ascend-device-plugin/blob/main/README.md">Ascend NPU</a>
</td>
<td align="center">
<img src="./imgs/metax-logo.png" width="80px"><br/>
<a href="docs/metax-support.md">Metax GPU</a>
</td>
<td align="center">
<img src="./imgs/more-logo.png" width="80px"><br/>
More coming soon
</td>
</tr>
</table>
</div>

## 🏗️ Architecture

<div align="center">
<img src="./imgs/hami-arch.png" width="700px" />
</div>

HAMi consists of a unified mutating webhook, scheduler extender, device plugins and in-container virtualization for each AI device type.

## Monitoring & Observability

Built-in monitoring is enabled after installation:
```
http://{scheduler-ip}:31993/metrics
```

<div align="center">
<img src="./imgs/metrics-dashboard.png" width="700px" />
</div>

[View Grafana Dashboard Examples](docs/dashboard.md)

## 📈 Real-world Results

<div align="center">
<table>
<tr>
<td width="50%" align="center">
<img src="./imgs/case-study1.png" width="90%"><br/>
<b>Financial Services</b><br/>
70% reduction in GPU costs for ML training pipeline
</td>
<td width="50%" align="center">
<img src="./imgs/case-study2.png" width="90%"><br/>
<b>E-commerce Platform</b><br/>
4x more inference workloads on same hardware
</td>
</tr>
</table>
</div>

## Advanced Configuration

- [Customizing Installation](docs/config.md)
- [Using with Volcano Scheduler](docs/how-to-use-volcano-vgpu.md)
- [Dynamic MIG Support](docs/dynamic-mig-support.md)

## Community & Support

<div align="center">
<table>
<tr>
<td align="center" width="25%">
<img src="./imgs/icon-meeting.png" width="64px"><br/>
<b>Community Meeting</b><br/>
Friday at 16:00 UTC+8 (weekly)<br/>
<a href="https://meeting.tencent.com/dm/Ntiwq1BICD1P">Join Here</a>
</td>
<td align="center" width="25%">
<img src="./imgs/icon-slack.png" width="64px"><br/>
<b>Slack Channel</b><br/>
#project-hami on CNCF Slack<br/>
<a href="https://slack.cncf.io/">Join CNCF Slack</a>
</td>
<td align="center" width="25%">
<img src="./imgs/icon-issues.png" width="64px"><br/>
<b>GitHub Issues</b><br/>
Report bugs or request features<br/>
<a href="https://github.com/Project-HAMi/HAMi/issues">Open Issues</a>
</td>
<td align="center" width="25%">
<img src="./imgs/icon-discussion.png" width="64px"><br/>
<b>Discussions</b><br/>
Ask questions and share ideas<br/>
<a href="https://github.com/Project-HAMi/HAMi/discussions">Join Discussion</a>
</td>
</tr>
</table>
</div>

## 👥 Contributors

Thank you to all the amazing people who have contributed to HAMi!

<a href="https://github.com/Project-HAMi/HAMi/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=Project-HAMi/HAMi" />
</a>

<!-- Made with [contrib.rocks](https://contrib.rocks). -->

## 📝 Detailed Documentation

- [Complete Installation Guide](docs/installation.md)
- [Configuration Options](docs/config.md)
- [FAQ](docs/faq.md)
- [Contributing to HAMi](CONTRIBUTING.md)
- [Roadmap](docs/develop/roadmap.md)

## 📚 References & Talks

- [KubeCon EU 2024: Cloud Native Batch Computing with Volcano](https://youtu.be/fVYKk6xSOsw)
- [KubeCon China 2024: Unlocking Heterogeneous AI Infrastructure](https://www.youtube.com/watch?v=kcGXnp_QShs)
- [More Talks and References](docs/talks.md)

## License

HAMi is under the Apache 2.0 license. See the [LICENSE](LICENSE) file for details.

## Star History

<div align="center">
<a href="https://star-history.com/#Project-HAMi/HAMi&Date">
  <img src="https://api.star-history.com/svg?repos=Project-HAMi/HAMi&type=Date" width="600px">
</a>
</div>
