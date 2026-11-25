# Add-on Scripts

Created: 25 Nov 2026
Last modified: 25 Nov 2026

Optional scripts that set up a feature and give the cluster **sample workloads**,
so there is something to show in the dashboard during a platform walkthrough.

**Run them last**, after the main setup is complete:

| Order | Script | Purpose |
| ----- | ------ | ------- |
| 1 | [`field-source-enable-all-features-35.sh`](../field-source-enable-all-features-35.sh) | Enables all RHOAI components (required) |
| 2 | [`field-source-setup-maas-35.sh`](../field-source-setup-maas-35.sh) | Sets up Models-as-a-Service |
| 3 | **Add-on scripts (this folder)** | Set up features and fill the cluster with sample workloads |

All scripts are safe to re-run. A re-run skips anything that already exists.

| Script | What you get |
| ------ | ------------ |
| [`field-source-setup-model-registry-35.sh`](field-source-setup-model-registry-35.sh) | Model registry with model `minilm-l6` (versions v1 and v2), both deployed in the `demo` project |

---

## Model registry: `field-source-setup-model-registry-35.sh`

### 1. Log in to the cluster

Use **one** of these:

- **Web Terminal** (easiest): in the OpenShift console, click the **>_** icon in the top-right. `oc` is already logged in.
- **Your own terminal:** in the OpenShift console, click your user name → **Copy login command** → **Display token**, then run the `oc login --token=... --server=...` command shown.

Check that you're logged in:

```bash
oc whoami
```

> The script needs a **token** login (`oc whoami -t` must print a token). A kubeconfig `system:admin` login won't work.

### 2. Run the script

**Option A: straight from GitHub** (nothing to download)

```bash
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/main/scripts/add-on-scripts/field-source-setup-model-registry-35.sh | bash
```

**Option B: from a clone of this repo**

```bash
bash scripts/add-on-scripts/field-source-setup-model-registry-35.sh
```

It takes about **3 minutes** the first time and about 1 minute on a re-run. It ends with `All checks passed`.

### 3. See it in the dashboard

The dashboard URL is printed at the end of the script.

| Where | What you see |
| ----- | ------------ |
| **AI hub** → **Models** → **Registry** → `demo-model-registry` → `minilm-l6` | The model with versions **v1** and **v2**, each with 1 deployment |
| **Projects** → `demo` → **Deployments** | `minilm-l6-v1` and `minilm-l6-v2`, both running |

### What it creates

| Item | Name |
| ---- | ---- |
| Model registry | `demo-model-registry` (default database, non-production) |
| Registered model | `minilm-l6`: a small text embedding model (384-dimension vectors) |
| Version v1 | `oci://registry.redhat.io/rhai/modelcar-all-minilm-l6-v2:1.5` |
| Version v2 | `oci://registry.redhat.io/rhai/modelcar-all-minilm-l6-v2:3.0-1793793003` |
| Project | `demo` |
| Deployments | `minilm-l6-v1`, `minilm-l6-v2` (CPU only, no GPU needed) |

### Already have a `demo` project?

That's fine. The script only adds its own objects and never changes anything else in the project. If something in `demo` (or a model in the registry) already uses one of the names above and wasn't created by this script, the script **stops before changing anything** and tells you what clashed. Re-run with a different name:

```bash
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/main/scripts/add-on-scripts/field-source-setup-model-registry-35.sh | MODEL_NAME=minilm-l6-demo bash
```

You can also use `TARGET_NS=<project>` to deploy into a different project.

### If something goes wrong

- **Re-run the same command.** Completed steps are skipped, and the script picks up where it stopped.
- If a check still shows `[!!]`, look at the pods: `oc get pods -n demo`
- Sample output is in [`output-log/field-source-setup-model-registry-35-output.log`](../../output-log/field-source-setup-model-registry-35-output.log).
