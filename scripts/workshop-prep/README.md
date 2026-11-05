# Workshop Preparation Scripts (Administrators)

Created: 2026-11-04
Last modified: 2026-11-05

Scripts that prepare a Field Source OpenShift AI (RHOAI 3.5) cluster for a
hands-on workshop. Each participant gets their own **Workbench** and **Showroom**
(lab guide), and both live in one OpenShift AI project named after the user's
Keycloak username (`user1`, `user2`, ...).

Run these **after** the cluster setup scripts (`field-source-enable-all-features-35.sh`
and `field-source-setup-maas-35.sh`) have completed.

> **Run these scripts from your own terminal, already logged in to the cluster.**
> Log in with `oc login` as a cluster-admin before you start; the scripts do not
> log in for you and stop if `oc` is not logged in. Do not use the OpenShift Web
> Terminal: `spin-up-workernodes.sh` can wait up to 15 minutes, and
> `deploy-showroom.sh` changes the cluster's ingress settings, either of which can
> end a Web Terminal session part-way through.

## Run order

Run the four scripts in this order:

| Step | Script | What it does | Arguments to set | Time |
| ---- | ------ | ------------ | ---------------- | ---- |
| 1 | [`setup_workshop_users_rbac.sh`](setup_workshop_users_rbac.sh) | Grants each Keycloak user `cluster-admin` and adds them to `rhods-admins` | None | Seconds |
| 2 | [`spin-up-workernodes.sh`](spin-up-workernodes.sh) | Scales the worker MachineSets so the cluster has room for every user | `--users <n>` (see [Sizing](#sizing-how-many-worker-nodes)); preview first with `--dry-run` | 5–15 min |
| 3 | [`setup_workbench_by_users.sh`](setup_workbench_by_users.sh) | Creates a project, PVC, and Jupyter Workbench for each user | Optional: `WORKSHOP_USERS`, `WORKBENCH_SIZE` | 1–2 min |
| 4 | [`deploy-showroom.sh`](deploy-showroom.sh) | Deploys a Showroom lab guide per user, with Workbench, Console, and Dashboard tabs | **Required:** `WORKSHOPS`. Recommended: `SITE_TITLE`, `HOME_INDEX_FILE` | 5–10 min |

Why this order:

- **Step 2 before step 3.** Workbench pods start as soon as they are created.
  If the new nodes are not Ready yet, the first Workbenches crowd the existing
  workers and stay there, while the rest wait as Pending.
  `spin-up-workernodes.sh` waits until the new nodes are Ready, so step 3 spreads
  Workbenches across all of them.
- **Step 4 last.** `deploy-showroom.sh` adds a Workbench tab only when it finds
  a Workbench in the user's project.

All scripts are idempotent. Re-run any of them to add users or pick up changes.

> **SNO clusters:** [`add-worker-node.sh`](add-worker-node.sh) is for Single Node
> OpenShift, which has no worker MachineSets. Do not use it on a Field Source
> cluster. There it finds the existing `<infra-id>-worker-<az>` MachineSet and
> makes no change.

## Prerequisites

- A terminal on your own machine (macOS or Linux), with the `oc` CLI installed
- Already logged in to the cluster as a cluster-admin. Check with `oc whoami`
  (it should print your admin user) and `oc whoami --show-server` (it should
  print this cluster's API URL).
- RHOAI 3.5 installed with the workbenches component ready
- Workshop users already provisioned in Keycloak (a `KeycloakRealmImport` CR named
  `sso` in the `keycloak` namespace). Step 1 requires this. Steps 2–4 can
  instead take a user count or an explicit list (`--users`, `WORKSHOP_USERS`).
- `bash`, `curl`, and `sha256sum` or `shasum` (all present on macOS and most
  Linux distributions)

## Sizing: how many worker nodes

The Field Source base environment has **2 worker nodes** (`m5a.4xlarge`: 16 vCPU,
64 GiB each), spread over 3 worker MachineSets, one per availability zone. These
2 workers already run the RHOAI platform, so add capacity before a workshop.

| Users | Workbenches reserve | Total workers | Added to base | Command | Approx. extra cost |
| ----- | ------------------- | ------------- | ------------- | ------- | ------------------ |
| 10 | 10 CPU, 40 GiB | **3** | +1 | `bash spin-up-workernodes.sh --users 10` | ~$0.69/hour |
| 20 | 20 CPU, 80 GiB | **4** | +2 | `bash spin-up-workernodes.sh --users 20` | ~$1.38/hour |
| 30 | 30 CPU, 120 GiB | **6** | +4 | `bash spin-up-workernodes.sh --users 30` | ~$2.75/hour |

Costs are on-demand `m5a.4xlarge` in us-east, about $0.69/hour per node.

How the numbers are worked out:

```
total workers = 1 (platform) + ceil(users / 7)
```

- **Per user**, plan for about 2 CPU and 8 GiB requested: the Small Workbench
  (1 CPU / 4 GiB), the Showroom (about 0.1 CPU / 0.25 GiB), and headroom for
  what the labs deploy (agents, EvalHub jobs).
- **One `m5a.4xlarge`** has about 15.5 CPU and 58 GiB usable, which fits about
  **7 users**.
- **One worker's worth** is reserved for the platform pods that already run on
  the base workers (operators, MLflow, EvalHub, monitoring, Dev Spaces).

Adjust when your workshop differs:

| Situation | What to do |
| --------- | ---------- |
| Other user counts | `--users <n>` applies the same formula (for example, 15 users gives 4 workers) |
| Existing workers already more than 50% reserved (the script prints this) | Add one more: `--workers <recommended + 1>` |
| `WORKBENCH_SIZE=Medium` (2 CPU / 8 GiB per Workbench) | `USERS_PER_WORKER=4 bash spin-up-workernodes.sh --users <n>` |
| You want an exact node count | `--workers <n>` (total workers, not extra) |

GPU nodes for model serving are separate. See `../gpu_machineset_hardwareprofiles.sh`.

## Quick start

```bash
# Confirm you are logged in to the right cluster as a cluster-admin
oc whoami
oc whoami --show-server

cd scripts/workshop-prep

# Step 1: user permissions (cluster-admin + rhods-admins)
bash setup_workshop_users_rbac.sh

# Step 2: worker capacity (preview, then apply; waits until nodes are Ready)
bash spin-up-workernodes.sh --users 30 --dry-run
bash spin-up-workernodes.sh --users 30

# Step 3: per-user Workbenches (users discovered from Keycloak; admin is skipped)
bash setup_workbench_by_users.sh

# Step 4: per-user Showrooms
export SITE_TITLE="RHOAI Hands-on Workshop"
export HOME_INDEX_FILE="./my-home.adoc"
export WORKSHOPS="
basic-inference|https://github.com/jingggg-wenn/rhoai-basic-inference-workshop|main|content|Basic Inference
agentops|https://github.com/hyogrin/rhoai-basic-agentops-workshop|main|content|AgentOps Workshop
evalhub|https://github.com/hyogrin/rhoai-basic-evalhub-workshop|main|content|Eval Hub Workshop
"
bash deploy-showroom.sh
```

To target specific users instead of everyone in Keycloak, export the **same**
list before running steps 3 and 4, and pass the matching count to step 2:

```bash
export WORKSHOP_USERS="user1,user2,user3,user4"
bash spin-up-workernodes.sh --users 4
```

---

## Step 1: `setup_workshop_users_rbac.sh`

Gives every workshop user the permissions they need for the labs.

```bash
bash setup_workshop_users_rbac.sh
```

It:

1. Reads the users from the `KeycloakRealmImport` CR `sso` in the `keycloak` namespace
2. Creates a `cluster-admin-<username>` ClusterRoleBinding for each user
3. Adds each user to the `rhods-admins` group (creating the group if needed),
   which gives them admin access in the RHOAI dashboard

This script has no options. It always applies to **every** user in the
KeycloakRealmImport, including `admin`, and ignores `WORKSHOP_USERS`. If Keycloak
is not available, it exits with an error.

> **Note:** `field-source-setup-maas-35.sh` does not add users to `rhods-admins`.
> It relies on this script for that.

---

## Step 2: `spin-up-workernodes.sh`

Adds worker nodes by scaling the cluster's **existing** worker MachineSets. Each
new node goes to the MachineSet with the fewest replicas, so nodes spread across
availability zones. GPU MachineSets are skipped.

```bash
bash spin-up-workernodes.sh --users 30 --dry-run   # show the plan only
bash spin-up-workernodes.sh --users 30             # scale and wait for Ready
```

It:

1. Lists the worker MachineSets and their current replica counts
2. Works out the target from `--users` (or the Keycloak user count) or `--workers`
3. Prints how much CPU and memory the current workers already have reserved
4. Scales MachineSets up to the target. It never scales down.
5. Waits up to 15 minutes for the new nodes to be Ready, then prints the
   commands to scale back after the workshop

On the base environment, `--users 30` scales `us-east-2a`, `us-east-2b`, and
`us-east-2c` to 2 replicas each.

### Options

| Argument / variable | Default | Description |
| ------------------- | ------- | ----------- |
| `--users <n>` | Keycloak user count (minus `admin`) | Number of participants to size for |
| `--workers <n>` | *(from `--users`)* | Exact total worker count; overrides `--users` |
| `--dry-run` | off | Show the plan without scaling |
| `--no-wait` | off | Scale and exit without waiting for nodes |
| `USERS_PER_WORKER` | `7` | Users per added worker node |
| `PLATFORM_WORKERS` | `1` | Workers' worth reserved for the RHOAI platform |
| `WAIT_TIMEOUT` | `900` | Seconds to wait for nodes to be Ready |

If nodes are not Ready after 15 minutes, check `oc get machines -n openshift-machine-api`
for `Failed` machines. The usual cause is an AWS capacity or quota limit for
`m5a.4xlarge` in that zone.

---

## Step 3: `setup_workbench_by_users.sh`

Creates one OpenShift AI Workbench per participant, using the
**Jupyter | Data Science | CPU | Python 3.12** image.

```bash
# Auto-discover users from Keycloak (skips admin)
bash setup_workbench_by_users.sh

# Or give an explicit list
export WORKSHOP_USERS="user1,user2,user3,user4"
bash setup_workbench_by_users.sh
```

For each user it:

1. Creates the OpenShift AI project `<username>` (visible in the dashboard)
2. Grants the user `admin` on that project
3. Creates a `20Gi` PVC for notebook storage
4. Creates a `Notebook` CR named `my-workbench`, using `inject-auth` on
   Gateway-based clusters and `inject-oauth` on legacy clusters
5. Prints each Workbench URL

Existing Workbenches are left unchanged. To change the size or image of an
existing one, delete it (`oc delete notebook my-workbench -n <user>`) and re-run.

### Options

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `WORKSHOP_USERS` | *(auto)* | Comma-separated users; if unset, discovered from Keycloak |
| `SKIP_ADMIN` | `admin` | Comma-separated usernames to skip during discovery |
| `KC_NAMESPACE` | `keycloak` | Keycloak namespace |
| `KC_REALM_IMPORT_NAME` | `sso` | `KeycloakRealmImport` CR name |
| `WORKBENCH_NAME` | `my-workbench` | Notebook name |
| `WORKBENCH_SIZE` | `Small` | `Tiny` / `Small` / `Medium` / `Large` (affects [sizing](#sizing-how-many-worker-nodes)) |
| `PVC_SIZE` | `20Gi` | Workbench storage size |
| `STORAGE_CLASS` | *(cluster default)* | PVC StorageClass override |
| `IMAGE_STREAM` | *(auto)* | ImageStream name in `redhat-ods-applications` |
| `IMAGE_TAG` | *(auto)* | ImageStream tag |

### Check the result

A printed URL does not mean the Workbench is running. Before the workshop, check:

```bash
oc get notebooks -A
oc get pods -A -l notebook-name=my-workbench    # all should be Running, none Pending
```

Workbench URLs look like this:

```
# Gateway-based clusters
https://<data-science-gateway-host>/notebook/<username>/my-workbench/

# Legacy clusters (per-workbench Route)
https://my-workbench-<username>.<cluster-domain>/notebook/<username>/my-workbench/
```

If the script warns that an existing Workbench is missing `inject-auth`, that
Workbench was created before the cluster moved to the AI Gateway. Follow the
[OpenShift AI authentication migration procedure](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/upgrading_openshift_ai_self-managed/post-upgrade-steps-for-openshift-ai_upgrade),
or delete and re-create the Workbench.

---

## Step 4: `deploy-showroom.sh`

Deploys one Showroom lab guide per participant into the same `<username>`
project as their Workbench. Each Showroom is personalized with the user's
username, password, and login command, and shows the Workbench, OpenShift Console,
and RHOAI Dashboard as tabs next to the lab content.

No Helm, image build, or extra application is needed. Everything runs from
ConfigMaps and the upstream `quay.io/rhpds` images. The pods download the lab
content from Git and the Showroom theme from GitHub when they start, so the
cluster needs internet access.

```bash
export SITE_TITLE="RHOAI Hands-on Workshop"
export WORKSHOPS="
basic-inference|https://github.com/jingggg-wenn/rhoai-basic-inference-workshop|main|content|Basic Inference
"
bash deploy-showroom.sh
```

If Keycloak is not available, also set `WORKSHOP_USERS` and `USER_PASSWORD`.
When `USER_PASSWORD` is unset, each user's own password is read from their
Keycloak entry.

### `WORKSHOPS` format

One workshop per line, pipe-delimited: `name|git_url|git_ref|content_path[|title]`

| Field | Required | Description |
| ----- | -------- | ----------- |
| `name` | yes | URL path and Antora component name (`a-z0-9` and hyphens) |
| `git_url` | yes | HTTPS Git URL (no credentials) |
| `git_ref` | yes | Branch or tag (commit SHAs are not supported) |
| `content_path` | yes | Directory containing `antora.yml` (for example `content`) |
| `title` | no | Name shown on the home page (defaults to `name`) |

Blank lines and lines starting with `#` are ignored.

### Options

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `WORKSHOPS` | *(none)* | Workshop list (see format above). Required. |
| `SITE_TITLE` | `Workshop` | Title shown in the browser tab and on the home page |
| `WORKSHOP_USERS` | *(auto)* | Comma-separated users; if unset, discovered from Keycloak (`admin` skipped) |
| `USER_PASSWORD` | *(auto)* | One password for all users; otherwise each user's Keycloak password |
| `HOME_INDEX_FILE` | *(auto-generated)* | Custom home page `.adoc`, local path or `https://` URL. Used only with 2+ workshops. |
| `KC_NAMESPACE` | `keycloak` | Keycloak namespace |
| `KC_REALM_IMPORT_NAME` | `sso` | `KeycloakRealmImport` CR name |
| `MAX_PARALLEL` | `10` | Maximum rollouts waited on at once |
| `EXTRA_TABS` | *(none)* | Extra tabs, one per line: `name\|url\|external` |
| `SKIP_FRAME_PATCH` | *(off)* | Set to `true` to skip the ingress header changes for embedding |

### Custom home page

With more than one workshop, a home page listing them is generated for you. To
use your own, point `HOME_INDEX_FILE` at an AsciiDoc file. The sample
[`my-home.adoc`](my-home.adoc) in this folder is a starting point. Link to each
workshop with `xref:<name>::index.adoc[Title]`, where `<name>` matches the first
field of its `WORKSHOPS` line. With a single workshop there is no home page;
Showroom opens that workshop directly.

### Result

Each user gets a Showroom at:

```
https://showroom-showroom-<username>.<cluster-domain>
```

To refresh content after a Git change, re-run the script, or restart one user's pod:

```bash
oc rollout restart deployment/showroom -n user1
```

> **Note:** `deploy-showroom.sh` updates the default IngressController response
> headers so the Console and Dashboard can be embedded in Showroom. Only the
> Showroom origins from the current run are allowed, so always run it with the
> full participant list.

---

## Running without cloning the repo

None of the scripts need local files, so you can also run them straight from
GitHub with `curl | bash`. Run this in your own terminal, logged in to the
cluster, as above. Pass script arguments after `bash -s --`:

```bash
BASE=https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/refs/heads/main/scripts/workshop-prep

# Step 1
curl -sL "$BASE/setup_workshop_users_rbac.sh" | bash

# Step 2
curl -sL "$BASE/spin-up-workernodes.sh" | bash -s -- --users 30

# Step 3
curl -sL "$BASE/setup_workbench_by_users.sh" | bash

# Step 4
export SITE_TITLE="RHOAI Hands-on Workshop"
export HOME_INDEX_FILE="$BASE/my-home.adoc"
export WORKSHOPS="
basic-inference|https://github.com/jingggg-wenn/rhoai-basic-inference-workshop|main|content|Basic Inference
agentops|https://github.com/hyogrin/rhoai-basic-agentops-workshop|main|content|AgentOps Workshop
evalhub|https://github.com/hyogrin/rhoai-basic-evalhub-workshop|main|content|Eval Hub Workshop
"
curl -sL "$BASE/deploy-showroom.sh" | bash
```

## Cleanup after the workshop

**Scale workers back to the base environment** to stop the extra EC2 charges.
`spin-up-workernodes.sh` prints the exact commands at the end of its run. For
the base environment they are:

```bash
oc scale machineset <infra-id>-worker-us-east-2a -n openshift-machine-api --replicas=1
oc scale machineset <infra-id>-worker-us-east-2b -n openshift-machine-api --replicas=1
oc scale machineset <infra-id>-worker-us-east-2c -n openshift-machine-api --replicas=0
```

Do this after removing the Workbenches and Showrooms, so their pods are not
moved onto the remaining nodes.

**Remove only the Showroom resources.** This keeps each user's project,
Workbench, and storage:

```bash
for ns in user1 user2 user3 user4; do
  oc delete deployment/showroom service/showroom route/showroom configmap/showroom-config \
    -n "$ns" --ignore-not-found
done
```

To remove everything for a user, including their Workbench data, delete the
project: `oc delete project user1`.

**Remove the permissions granted in step 1:**

```bash
for u in user1 user2 user3 user4; do
  oc delete clusterrolebinding "cluster-admin-$u" --ignore-not-found
  oc adm groups remove-users rhods-admins "$u"
done
```
