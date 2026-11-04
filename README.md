# Workshop Preparation Scripts

Created: 2026-10-06
Last modified: 2026-11-04

Scripts to prepare an OpenShift cluster for the RHOAI Basic Inference Workshop.
Run these from a local terminal after logging in with `oc login`.

## Prerequisites

- `oc` CLI installed and logged in with cluster-admin privileges
- `htpasswd` CLI available (built-in on macOS, `httpd-tools` on RHEL)
- `python3` (for MachineSet JSON generation)
- Cluster running on AWS with RHOAI installed

## Scripts

> **Note:** Run these scripts from a **local terminal**, not the OpenShift Web Terminal.
> The Web Terminal container does not include `htpasswd`, and patching the OAuth
> configuration on first run triggers an OAuth pod restart that can disconnect
> an active Web Terminal session.

### 1. create_workshop_users.sh

Creates workshop user accounts with htpasswd authentication.
**Automatically adds a worker node** (m6a.4xlarge) to prevent pod/resource
exhaustion on the SNO master node — essential when 20+ users each run
workbenches, model serving, and pipelines simultaneously.

```bash
bash create_workshop_users.sh                  # creates user1..user20 + worker node
bash create_workshop_users.sh --num-users=5    # creates user1..user5 + worker node
bash create_workshop_users.sh --num-users=50   # creates user1..user50 + 3 worker nodes
bash create_workshop_users.sh --skip-worker-node   # users only, no worker node
bash create_workshop_users.sh --worker-instance-type=m6a.8xlarge  # bigger worker
```


| Argument                          | Default       | Description                                     |
| --------------------------------- | ------------- | ----------------------------------------------- |
| `--num-users=<N>`                 | 20            | Number of users to create (`user1` .. `userN`) |
| `--skip-worker-node`              | *(off)*       | Skip worker node addition                       |
| `--worker-instance-type=<type>`   | m6a.4xlarge   | EC2 instance type for worker node               |


What it does:

1. **Adds a worker node** to the SNO cluster (m6a.4xlarge, same region/AZ as master)
   - Scales worker count by user count: 1 worker per ~20 users
   - EC2 provisioning starts immediately; node joins while users are being set up
   - Calls `../add-worker-node.sh` under the hood
2. Generates users (`user1` through `userN`) with password `openshift`
3. Sets up htpasswd as an identity provider on the OAuth cluster resource (preserves existing IDPs)
4. Grants `cluster-admin` RBAC to each user
5. Adds all users to the `rhods-admins` group for RHOAI dashboard admin access
6. Waits for OAuth pods to roll out

> **Why a worker node?** SNO has a 250 pod per node limit. A single workshop
> user running a workbench + pipeline server + model serving already uses ~15
> pods. At 20 users, system + user pods easily exceed the limit, causing
> scheduling failures. The m6a.4xlarge (16 vCPU, 64 GiB) provides enough
> headroom for a typical workshop. Cost: ~$0.69/hr (us-east-1).

### 2. gpu_machineset_hardwareprofiles.sh

Configures GPU infrastructure for model serving workloads.

```bash
bash gpu_machineset_hardwareprofiles.sh
```

What it does:

- Creates a GPU MachineSet (`g6.2xlarge` / NVIDIA L4) with `replicas=0` (scale up manually when needed)
- Patches the `gpu-profile` HardwareProfile with nodeSelector (`nvidia.com/gpu.present`) and toleration (`nvidia.com/gpu:NoSchedule`) so workloads schedule onto GPU nodes
- Uses `scheduling.type: Node` (native Kubernetes scheduling) -- does not require Kueue

### 3. setup_workbench_by_users.sh

Create a per-user OpenShift AI workbench for each workshop participant.
Uses **Jupyter | Data Science | CPU | Python 3.12** (RHOAI 3.5).

```bash
# Auto-discover users from Keycloak (skips admin)
bash setup_workbench_by_users.sh

# Or explicit list
export WORKSHOP_USERS="user1,user2,user3,user4"
bash setup_workbench_by_users.sh
```

What it does (per user):

1. Creates OpenShift AI project/namespace `<username>` (dashboard-visible, shared with Showroom)
2. Grants the user `admin` on their project
3. Creates a PVC (`20Gi` by default)
4. Creates a `Notebook` CR named `my-workbench` with `inject-auth` on Gateway-based clusters, or `inject-oauth` on legacy clusters
5. Prints Gateway workbench URLs, or waits for legacy workbench Routes

Project names match the existing Keycloak login names exactly: `user1`, `user2`,
and so on. Authentication, project permissions, Notebook ownership, and Showroom
all use the same username. Workshop instructions should use these project names.
Automatic image selection matches the full Jupyter display name so Code Server
images with the same Data Science / Python labels are not selected.

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `WORKSHOP_USERS` | *(auto)* | Comma-separated users; else Keycloak discovery |
| `WORKBENCH_NAME` | `my-workbench` | Notebook / Route name |
| `WORKBENCH_SIZE` | `Small` | `Tiny` / `Small` / `Medium` / `Large` |
| `PVC_SIZE` | `20Gi` | Workbench storage size |
| `STORAGE_CLASS` | *(default)* | PVC StorageClass override |
| `IMAGE_STREAM` | *(auto)* | ImageStream name in `redhat-ods-applications` |
| `IMAGE_TAG` | *(auto)* | ImageStream tag (recommended if present) |

On Gateway-based clusters, Workbench URLs use the shared AI Gateway:

```
https://<data-science-gateway-host>/notebook/<username>/my-workbench/
```

Legacy per-workbench Route URLs use:

```
https://my-workbench-<username>.<cluster-domain>/notebook/<username>/my-workbench/
```

Generating a URL does not verify Workbench readiness. Check `oc get notebooks -A`
and the Workbench Pod status before the workshop. Existing Notebooks are preserved;
if they still use `inject-oauth` on a Gateway-based cluster, follow the
[OpenShift AI authentication migration procedure](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/upgrading_openshift_ai_self-managed/post-upgrade-steps-for-openshift-ai_upgrade).

### 4. deploy-showroom.sh

Deploy **per-user** Showroom instances for all workshop participants.
Each user gets a Showroom in their OpenShift AI project (`<username>`),
alongside their Workbench, with a Route and personalized Antora attributes
(username, password, login command). Use the same `WORKSHOP_USERS` list for both
scripts so each participant's Workbench and Showroom share one namespace and
one OpenShift AI project.
No Helm, Docker build, or separate application needed — all logic runs
via ConfigMap-embedded scripts using the upstream `quay.io/rhpds` images.

Users are discovered automatically from Keycloak or supplied explicitly.
Common ConfigMap files are generated once; only per-user attributes
differ. All rollouts are waited on in parallel for speed.

#### Auto-discover users from Keycloak

If the cluster has Keycloak with a `KeycloakRealmImport` CR,
users and passwords are discovered automatically (the `admin` user is excluded):

```bash
export SITE_TITLE="RHOAI Hands-on Workshop"
export WORKSHOPS="
basic-inference|https://github.com/jingggg-wenn/rhoai-basic-inference-workshop|main|content|Basic Inference
"
bash deploy-showroom.sh
```

#### Explicit user list

When Keycloak is not available, or you want to target specific users:

```bash
export WORKSHOP_USERS="user1,user2,user3,user4"
export USER_PASSWORD="openshift"
export SITE_TITLE="RHOAI Hands-on Workshop"
export WORKSHOPS="
basic-inference|https://github.com/jingggg-wenn/rhoai-basic-inference-workshop|main|content|Basic Inference
"
bash deploy-showroom.sh
```

#### Remote execution (Web Terminal)

The script can be run directly via `curl | bash` from an OpenShift Web Terminal:

```bash
export WORKSHOP_USERS="user1,user2,user3,user4"
export USER_PASSWORD="openshift"
export SITE_TITLE="RHOAI Hands-on Workshop"
export HOME_INDEX_FILE="https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/refs/heads/main/scripts/workshop-prep/my-home.adoc"
export WORKSHOPS="
basic-inference|https://github.com/jingggg-wenn/rhoai-basic-inference-workshop|main|content|Basic Inference
agentops|https://github.com/hyogrin/rhoai-basic-agentops-workshop|main|content|AgentOps Workshop
"
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/refs/heads/main/scripts/workshop-prep/deploy-showroom.sh | bash
```

#### WORKSHOPS format

Each line is pipe-delimited: `name|git_url|git_ref|content_path[|title]`

| Field          | Required | Description                                              |
| -------------- | -------- | -------------------------------------------------------- |
| `name`         | yes      | URL path and Antora component name (`a-z0-9` + hyphens) |
| `git_url`      | yes      | HTTPS Git URL (no credentials)                           |
| `git_ref`      | yes      | Branch, tag, or commit SHA                               |
| `content_path` | yes      | Directory containing `antora.yml` (relative, e.g. `content`) |
| `title`        | no       | Display name on home page (defaults to `name`)           |

Blank lines and `#` comments are ignored.

#### Environment variables

| Variable               | Default        | Description                                             |
| ---------------------- | -------------- | ------------------------------------------------------- |
| `WORKSHOPS`            | *(none)*       | Multi-workshop list (see format above)                  |
| `GIT_URL`              | *(none)*       | Single workshop URL (backward compat, used when `WORKSHOPS` is unset) |
| `GIT_REF`              | *(none)*       | Branch/tag for single workshop                          |
| `CONTENT_PATH`         | *(none)*       | Content directory for single workshop                   |
| `SITE_TITLE`           | `Workshop`     | Site title shown in browser tab and home page            |
| `WORKSHOP_USERS`       | *(auto)*       | Comma-separated user list; if unset, discovers from Keycloak |
| `USER_PASSWORD`        | *(auto)*       | Common password; if unset, discovers from Keycloak      |
| `KC_NAMESPACE`         | `keycloak`     | Keycloak namespace for auto-discovery                   |
| `KC_REALM_IMPORT_NAME` | `sso`          | KeycloakRealmImport CR name                             |
| `MAX_PARALLEL`         | `10`           | Max parallel rollout waits                              |
| `HOME_INDEX_FILE`      | *(none)*       | Custom home page `.adoc` — local path or `https://` URL |
| `EXTRA_TABS`           | *(none)*       | Additional nookbag tabs: `name\|url\|external` per line |
| `SKIP_FRAME_PATCH`     | *(off)*        | Skip Console/Dashboard Route framing patch              |

#### How it works

1. Parses `WORKSHOPS` (or `GIT_URL`) into a workshop list
2. Discovers users from Keycloak or `WORKSHOP_USERS`
3. Collects cluster info (domain, API URL, console URL, RHOAI dashboard URL)
4. Patches Console/Dashboard Routes so Showroom can iframe them
   (`Content-Security-Policy: frame-ancestors https://*.<domain>`, delete `X-Frame-Options`)
5. Generates common ConfigMap files once (modules.txt, clone.sh, build.sh, traefik)
6. For each user:
   - Reuses namespace `<username>` (creates it if missing) and applies `opendatahub.io/dashboard=true`
   - Detects a Notebook in the user's project and attaches an **inline Workbench** tab using the AI Gateway, or a legacy per-workbench Route
   - Generates per-user attributes / `site.yml` / `ui-config.yml`
   - Applies ConfigMap + Deployment + Service + Route
7. Waits for all rollouts in parallel (max `MAX_PARALLEL`)
8. Prints summary with all user URLs

Each Showroom pod has 3 containers:
- **init: clone** — clones all workshop repos + generates the home component
- **init: build** — normalizes Antora components, injects attributes, runs `antora`
- **proxy** — Traefik reverse proxy (port 8080) with inline Console/Dashboard iframes
- **content** — serves the built HTML via nookbag (Showroom UI)

#### Custom home page

In multi-workshop mode, a home page listing all workshops is auto-generated.
To customize it, point `HOME_INDEX_FILE` to your own AsciiDoc file (local path or URL):

```bash
export HOME_INDEX_FILE="./my-home.adoc"
# or from remote:
export HOME_INDEX_FILE="https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/refs/heads/main/scripts/workshop-prep/my-home.adoc"
```

A sample file [`my-home.adoc`](my-home.adoc) is included in this directory.
Use `xref:<name>::index.adoc[Display Title]` to link to each workshop,
where `<name>` must match the first field of the corresponding `WORKSHOPS` entry.

#### Updating content

Re-run the script (idempotent) or restart pods to re-clone and re-build:

```bash
# Re-run (updates all users)
bash deploy-showroom.sh

# Or restart a single user's pod
oc rollout restart deployment/showroom -n user1
```

No Docker image rebuild is needed — everything is driven by ConfigMap files.

#### Result

Each user gets a dedicated Showroom at:

```
https://showroom-<username>.<cluster-domain>
```

For example, with users `user1`–`user4` on `apps.ocp.example.com`:

| User  | URL                                                     |
| ----- | ------------------------------------------------------- |
| user1 | `https://showroom-user1.apps.ocp.example.com`  |
| user2 | `https://showroom-user2.apps.ocp.example.com`  |
| user3 | `https://showroom-user3.apps.ocp.example.com`  |
| user4 | `https://showroom-user4.apps.ocp.example.com`  |

Existing Workbenches in namespaces such as `user1` are reused. Resources in
other namespaces, such as `showroom-user1` or `user-01`, are not moved or deleted
automatically. Re-running these scripts deploys to `user1` and prints the new
URLs. Existing Workbench PVC data in other namespaces must be migrated separately
before removing any old project.

## Run Order

Run the scripts in the order listed above. User accounts (+ worker node) should
be set up before participants access the cluster. GPU infrastructure can be
configured at any time before model deployment exercises.

```bash
oc login --server=https://api.<cluster-domain>:6443
bash create_workshop_users.sh            # users + worker node (or setup_workshop_users_rbac.sh)
bash gpu_machineset_hardwareprofiles.sh  # GPU MachineSet + HardwareProfile
bash setup_workbench_by_users.sh         # per-user workbenches
bash deploy-showroom.sh                  # per-user Showrooms
```

## Post-Workshop Cleanup

Scale down worker nodes and remove Showroom to stop EC2 charges:

```bash
# Scale worker nodes to 0
oc get machinesets -n openshift-machine-api
oc scale machineset <worker-ms-name> -n openshift-machine-api --replicas=0

# Delete only Showroom resources; retain projects, Workbenches, and their storage
for ns in user1 user2 user3 user4; do
  oc delete deployment/showroom service/showroom route/showroom configmap/showroom-config -n "$ns" --ignore-not-found
done
```
