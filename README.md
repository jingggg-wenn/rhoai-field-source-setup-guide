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

Sample output from Scripts 1 and 2 is in [`output-log/`](output-log/).
