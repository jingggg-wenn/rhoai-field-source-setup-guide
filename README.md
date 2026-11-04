# RHOAI 3.5 Field Source Setup Guide

Created: 04 Nov 2026
Last modified: 04 Nov 2026

Scripts that enable all Red Hat OpenShift AI 3.5 features on a **Field Source** cluster
(the RHDP sandbox base environment with Keycloak users, cert-manager pre-installed, and
no GPU operators or Kueue). This includes Models-as-a-Service (MaaS), observability, and
evaluation tooling, plus optional scripts to prepare the cluster for a multi-user workshop.

- **Repository:** [https://github.com/jingggg-wenn/rhoai-field-source-setup-guide](https://github.com/jingggg-wenn/rhoai-field-source-setup-guide)
- **Tested on:** RHOAI 3.5.2 on OpenShift 4.22

---

## Disclaimer

This is an **unofficial** setup script, not maintained or endorsed by Red Hat. It is tested
on a specific version (currently RHOAI 3.5.2) and may not work on other versions without
modification. Use at your own discretion.

---

## Quick start

Follow the step-by-step guide. It covers logging in, installing the Web Terminal, and
running the two setup scripts:

- English: [`scripts/WORKSHOP-SETUP.md`](scripts/WORKSHOP-SETUP.md)
- 한국어: [`scripts/WORKSHOP-SETUP_KR.md`](scripts/WORKSHOP-SETUP_KR.md)

In short, from the OpenShift Web Terminal:

```bash
# 1. Enable all RHOAI 3.5 features
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/main/scripts/field-source-enable-all-features-35.sh | bash

# 2. Set up MaaS (after step 1 completes)
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/main/scripts/field-source-setup-maas-35.sh | bash
```

All scripts are **idempotent**, so they are safe to re-run if interrupted or if operators
are still installing in the background.

---

## Repository layout

```
scripts/
├── WORKSHOP-SETUP.md / WORKSHOP-SETUP_KR.md   Step-by-step setup guide (EN / KR)
├── field-source-enable-all-features-35.sh     Script 1: enable all features
├── field-source-setup-maas-35.sh              Script 2: MaaS infrastructure
├── gpu_machineset_hardwareprofiles.sh         Optional: GPU MachineSet + HardwareProfile
└── workshop-prep/                             Optional: multi-user workshop setup
output-log/                                    Sample output from both setup scripts
images/                                        Screenshots used in the guides
```

---

## What gets configured

### Script 1: `field-source-enable-all-features-35.sh`

Installs supporting operators first, then enables all RHOAI 3.5 DSC components and
dashboard features.

| Step | What it does |
| ---- | ------------ |
| 1 | Prerequisites check |
| 2 | User Workload Monitoring |
| 3a | Install operators: NFD, NVIDIA GPU Operator, cert-manager, LWS, OpenTelemetry, Tempo, Cluster Observability, Dev Spaces |
| 3b | Wait for operators and create their CRs (NodeFeatureDiscovery, ClusterPolicy, LWS, UIPlugins, CheCluster) |
| 4 | DSCI patch (monitoring configuration) |
| 5 | DSC patch (activate all components) |
| 6 | MLflow server, demo project, and EvalHub |
| 7 | MaaS Gateway CRs |
| 8 | Dashboard menu flags and accelerator metrics rules |
| 9 | Install RHCL, Kuadrant, and Authorino TLS |
| 10 | Dashboard restart |
| 11 | Verification (flags anything not ready) |

> **Note:** Step 9 (RHCL / Service Mesh) can briefly disconnect the Web Terminal.
> Operators keep installing in the background. Reconnect and re-run the same command;
> completed steps are skipped.

### Script 2: `field-source-setup-maas-35.sh`

Configures the MaaS infrastructure. Run it after Script 1 completes.

| Step | What it does |
| ---- | ------------ |
| 1 | PostgreSQL database (POC deployment, or `--postgres-connection <url>` for an external DB) |
| 2 | Kuadrant CR and Authorino TLS in `kuadrant-system` |
| 3 | Rate limiting with Redis and EnvoyFilters (skip with `--skip-rate-limiting`) |
| 4 | Kuadrant AuthPolicy reconciliation |
| 5 | Verification |

### Optional: `gpu_machineset_hardwareprofiles.sh`

Field Source clusters have no GPU nodes. This script creates a GPU MachineSet
(`g6.2xlarge` / NVIDIA L4) with `replicas=0`, and creates the `gpu-profile`
HardwareProfile with the matching nodeSelector and toleration. Scale the MachineSet up
when you need GPUs. Requires `python3`.

```bash
bash scripts/gpu_machineset_hardwareprofiles.sh
oc scale machineset <gpu-machineset-name> -n openshift-machine-api --replicas=1
```

### Optional: workshop prep (`scripts/workshop-prep/`)

Scripts for running a multi-user workshop on the cluster, in this order:

| Script | What it does |
| ------ | ------------ |
| `setup_workshop_users_rbac.sh` | Grants each Keycloak user `cluster-admin` and adds them to `rhods-admins` |
| `setup_workbench_by_users.sh` | Creates a project and Jupyter Workbench for each user |
| `deploy-showroom.sh` | Deploys a Showroom lab guide for each user, with Workbench, Console, and Dashboard tabs |

See [`scripts/workshop-prep/README.md`](scripts/workshop-prep/README.md) for usage and options.

---

## Sample output

Full output from successful runs of both setup scripts is in
[`output-log/`](output-log/). Compare against it if a run looks different.
