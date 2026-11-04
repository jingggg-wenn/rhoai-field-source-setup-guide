# Workshop Preparation Scripts

Created: 2026-11-04
Last modified: 2026-11-04

Scripts that prepare an OpenShift AI (RHOAI 3.5) cluster for a hands-on workshop.
Each participant gets their own **Workbench** and **Showroom** (lab guide), and both
live in one OpenShift AI project named after the user's Keycloak username
(`user1`, `user2`, ...).

You run two scripts, in this order:

| Step | Script | What it creates |
| ---- | ------ | --------------- |
| 1 | [`setup_workbench_by_users.sh`](setup_workbench_by_users.sh) | A project, PVC, and Jupyter Workbench for each user |
| 2 | [`deploy-showroom.sh`](deploy-showroom.sh) | A Showroom lab guide for each user, with Workbench, Console, and Dashboard tabs |

Run step 1 first. `deploy-showroom.sh` looks for a Workbench in each user's project
and adds a Workbench tab only when it finds one.

## Prerequisites

- `oc` CLI, logged in with cluster-admin privileges (`oc login ...`)
- RHOAI 3.5 installed with the workbenches component ready
- Workshop users already provisioned in Keycloak (a `KeycloakRealmImport` CR named
  `sso` in the `keycloak` namespace), **or** an explicit user list passed in
  `WORKSHOP_USERS`
- `bash`, `curl`, and `sha256sum` or `shasum` (all present on macOS and in the
  OpenShift Web Terminal)

> **Optional: grant users admin rights first.** If participants need cluster-admin
> and RHOAI dashboard admin access, run
> [`setup_workshop_users_rbac.sh`](setup_workshop_users_rbac.sh) before step 1.
> It reads the users from Keycloak, grants each one `cluster-admin`, and adds them
> all to the `rhods-admins` group. It is safe to re-run.
>
> ```bash
> bash setup_workshop_users_rbac.sh
> ```

## Quick start

```bash
oc login --server=https://api.<cluster-domain>:6443

cd scripts/workshop-prep

# Step 1: per-user Workbenches (users discovered from Keycloak; admin is skipped)
bash setup_workbench_by_users.sh

# Step 2: per-user Showrooms
export SITE_TITLE="RHOAI Hands-on Workshop"
export HOME_INDEX_FILE="./my-home.adoc"
export WORKSHOPS="
basic-inference|https://github.com/jingggg-wenn/rhoai-basic-inference-workshop|main|content|Basic Inference
agentops|https://github.com/hyogrin/rhoai-basic-agentops-workshop|main|content|AgentOps Workshop
"
bash deploy-showroom.sh
```

To target specific users instead of everyone in Keycloak, export the **same**
list before running both scripts:

```bash
export WORKSHOP_USERS="user1,user2,user3,user4"
```

Both scripts are idempotent. Re-run them to add users or pick up changes.

---

## Step 1: `setup_workbench_by_users.sh`

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

### Options

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `WORKSHOP_USERS` | *(auto)* | Comma-separated users; if unset, discovered from Keycloak |
| `SKIP_ADMIN` | `admin` | Comma-separated usernames to skip during discovery |
| `KC_NAMESPACE` | `keycloak` | Keycloak namespace |
| `KC_REALM_IMPORT_NAME` | `sso` | `KeycloakRealmImport` CR name |
| `WORKBENCH_NAME` | `my-workbench` | Notebook name |
| `WORKBENCH_SIZE` | `Small` | `Tiny` / `Small` / `Medium` / `Large` |
| `PVC_SIZE` | `20Gi` | Workbench storage size |
| `STORAGE_CLASS` | *(cluster default)* | PVC StorageClass override |
| `IMAGE_STREAM` | *(auto)* | ImageStream name in `redhat-ods-applications` |
| `IMAGE_TAG` | *(auto)* | ImageStream tag |

### Check the result

A printed URL does not mean the Workbench is running. Before the workshop, check:

```bash
oc get notebooks -A
oc get pods -n user1
```

Workbench URLs look like this:

```
# Gateway-based clusters
https://<data-science-gateway-host>/notebook/<username>/my-workbench/

# Legacy clusters (per-workbench Route)
https://my-workbench-<username>.<cluster-domain>/notebook/<username>/my-workbench/
```

---

## Step 2: `deploy-showroom.sh`

Deploys one Showroom lab guide per participant into the same `<username>`
project as their Workbench. Each Showroom is personalized with the user's
username, password, and login command, and shows the Workbench, OpenShift Console,
and RHOAI Dashboard as tabs next to the lab content.

No Helm, image build, or extra application is needed. Everything runs from
ConfigMaps and the upstream `quay.io/rhpds` images.

```bash
export SITE_TITLE="RHOAI Hands-on Workshop"
export HOME_INDEX_FILE="./my-home.adoc"
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
| `git_ref` | yes | Branch, tag, or commit SHA |
| `content_path` | yes | Directory containing `antora.yml` (for example `content`) |
| `title` | no | Name shown on the home page (defaults to `name`) |

Blank lines and lines starting with `#` are ignored.

### Options

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `WORKSHOPS` | *(none)* | Workshop list (see format above). Required. |
| `SITE_TITLE` | `Workshop` | Title shown in the browser tab and on the home page |
| `WORKSHOP_USERS` | *(auto)* | Comma-separated users; if unset, discovered from Keycloak |
| `USER_PASSWORD` | *(auto)* | One password for all users; otherwise each user's Keycloak password |
| `HOME_INDEX_FILE` | *(auto-generated)* | Custom home page `.adoc`, local path or `https://` URL |
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
field of its `WORKSHOPS` line.

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

## Running from the OpenShift Web Terminal

Neither script needs local files, so both can be run with `curl | bash` from the
OpenShift Web Terminal:

```bash
BASE=https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/refs/heads/main/scripts/workshop-prep

# Step 1
curl -sL "$BASE/setup_workbench_by_users.sh" | bash

# Step 2
export SITE_TITLE="RHOAI Hands-on Workshop"
export HOME_INDEX_FILE="$BASE/my-home.adoc"
export WORKSHOPS="
basic-inference|https://github.com/jingggg-wenn/rhoai-basic-inference-workshop|main|content|Basic Inference
agentops|https://github.com/hyogrin/rhoai-basic-agentops-workshop|main|content|AgentOps Workshop
"
curl -sL "$BASE/deploy-showroom.sh" | bash
```

## Cleanup after the workshop

Remove only the Showroom resources. This keeps each user's project, Workbench,
and storage:

```bash
for ns in user1 user2 user3 user4; do
  oc delete deployment/showroom service/showroom route/showroom configmap/showroom-config \
    -n "$ns" --ignore-not-found
done
```

To remove everything for a user, including their Workbench data, delete the
project: `oc delete project user1`.
