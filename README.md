# RHOAI 3.5 Field Source Setup Guide

Created: 04 Nov 2026
Last modified: 25 Nov 2026
Last verified: 25 Nov 2026, on RHOAI 3.5.2 (OpenShift 4.22)

Scripts that set up Red Hat OpenShift AI 3.5 on a **Field Source** cluster and
prepare it for a hands-on workshop. Tested on RHOAI 3.5.2 and OpenShift 4.22.

> **Unofficial.** Not maintained or endorsed by Red Hat. Tested on RHOAI 3.5.2
> only. Use at your own discretion.

## Where to start

| You are | Go to | What it covers |
| ------- | ----- | -------------- |
| **Administrator** preparing a workshop | [`scripts/workshop-prep/README.md`](scripts/workshop-prep/README.md) | Ordering the environment, sizing, and setting up per-user Workbenches, GPU nodes, and Showroom lab guides |
| **User / participant** setting up a cluster | [`scripts/WORKSHOP-SETUP.md`](scripts/WORKSHOP-SETUP.md) ([한국어](scripts/WORKSHOP-SETUP_KR.md)) | Opening the Web Terminal and running the setup scripts below |

## The setup scripts

Run them in order. All are safe to re-run.

Order the environment with **OpenShift AI unticked**, so that Script 0 installs
RHOAI pinned to the tested version. If RHOAI is already installed, Script 0
reports it and exits without changing it.

### Script 0: [`workshop-prep/install-rhoai-operator.sh`](scripts/workshop-prep/install-rhoai-operator.sh)

Installs the RHOAI operator pinned to one version (default 3.5.2). Later
upgrades wait for manual approval.

| Step | What it does |
| ---- | ------------ |
| 1 | Prerequisites, existing RHOAI check, and version prompt (press Enter for 3.5.2) |
| 2 | Check that the version is in the catalog channel (`stable-3.5`) |
| 3 | Namespace, OperatorGroup, and Subscription (Manual approval) |
| 4 | Approve only the InstallPlan for the pinned version |
| 5 | Wait for the operator to install |
| 6 | DSCInitialization `default-dsci` and DataScienceCluster `default-dsc` |
| 7 | Verification, including newer versions left unapproved |

### Script 1: `field-source-enable-all-features-35.sh`

Installs supporting operators, then enables RHOAI 3.5 components and dashboard features.

| Step | What it does |
| ---- | ------------ |
| 1 | Prerequisites check |
| 2 | User Workload Monitoring |
| 3a | Install operators: NFD, NVIDIA GPU Operator, cert-manager, LWS, OpenTelemetry, Tempo, Cluster Observability, Dev Spaces |
| 3b | Wait for operators and create their CRs (NodeFeatureDiscovery, ClusterPolicy, LWS, UIPlugins, CheCluster) |
| 4 | DSCI patch (monitoring configuration) |
| 5 | DSC patch (activate components) |
| 6 | MLflow server, demo project, and EvalHub |
| 7 | MaaS Gateway CRs |
| 8 | Dashboard menu flags and accelerator metrics rules |
| 9 | Install RHCL, Kuadrant, and Authorino TLS (may briefly disconnect the Web Terminal; re-run if it does) |
| 10 | Dashboard restart |
| 11 | Verification (flags anything not ready) |

### Script 2: `field-source-setup-maas-35.sh`

Sets up Models-as-a-Service (MaaS). Run after Script 1 completes.

| Step | What it does |
| ---- | ------------ |
| 1 | PostgreSQL database (POC deployment, or `--postgres-connection <url>` for an external DB) |
| 2 | Kuadrant CR and Authorino TLS in `kuadrant-system` |
| 3 | Rate limiting with Redis and EnvoyFilters (skip with `--skip-rate-limiting`) |
| 4 | Kuadrant AuthPolicy reconciliation |
| 5 | Verification |

### Add-on: [`add-on-scripts/field-source-setup-model-registry-35.sh`](scripts/add-on-scripts/field-source-setup-model-registry-35.sh)

Optional. Run **last**, after Scripts 1 and 2 are done, to give the cluster
sample workloads for a platform walkthrough: a model registry with a
two-version model deployed in the `demo` project. CPU only, so no GPU is
needed. Standalone and safe to re-run. See
[`scripts/add-on-scripts/README.md`](scripts/add-on-scripts/README.md).

| Step | What it does |
| ---- | ------------ |
| 1 | Prerequisites check (token login, KServe Managed, `default-profile`, vLLM CPU runtime template) |
| 2 | Model registry component: patched to `Managed` only if it isn't already |
| 3 | Registry instance `demo-model-registry` with the default (operator-managed) PostgreSQL |
| 4 | Register model `minilm-l6` with versions `v1` (modelcar `1.5`) and `v2` (modelcar `3.0`) |
| 5 | Project `demo` |
| 6 | Deploy `minilm-l6-v1` and `minilm-l6-v2` side by side (vLLM CPU, `default-profile` customized to 4 CPU / 8Gi limits) |
| 7 | Registry linkage check: fixes any registry record that points at the wrong version |
| 8 | Verification (embeddings endpoints, auth, registry records) |

Sample output from Scripts 1 and 2 and the model registry add-on is in [`output-log/`](output-log/).
