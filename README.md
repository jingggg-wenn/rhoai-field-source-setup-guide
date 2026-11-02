# Workshop Preparation Scripts

Created: 2026-10-06
Last modified: 2026-11-02

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

### 3. add-worker-node.sh (standalone)

The worker node script can also be used independently outside the workshop context:

```bash
bash ../add-worker-node.sh                                   # m6a.4xlarge (default)
bash ../add-worker-node.sh --instance-type m6a.8xlarge       # bigger instance
bash ../add-worker-node.sh --replicas 2                      # two worker nodes
bash ../add-worker-node.sh --dry-run                         # preview without applying
```

### 4. deploy-showroom.sh

Deploy **per-user** Showroom instances for all workshop participants.
Each user gets their own namespace (`showroom-<username>`), Route, and
personalized Antora attributes (username, password, login command).
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

#### How it works

1. Parses `WORKSHOPS` (or `GIT_URL`) into a workshop list
2. Discovers users from Keycloak or `WORKSHOP_USERS`
3. Collects cluster info (domain, API URL, console URL, RHOAI dashboard URL)
4. Generates common ConfigMap files once (modules.txt, clone.sh, build.sh, traefik, ui-config)
5. For each user:
   - Creates namespace `showroom-<username>`
   - Generates per-user attributes (username, password, login command)
   - Generates per-user `site.yml` (with user-specific URL)
   - Applies ConfigMap + Deployment + Service + Route
6. Waits for all rollouts in parallel (max `MAX_PARALLEL`)
7. Prints summary with all user URLs

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
oc rollout restart deployment/showroom -n showroom-user1
```

No Docker image rebuild is needed — everything is driven by ConfigMap files.

#### Result

Each user gets a dedicated Showroom at:

```
https://showroom-showroom-<username>.<cluster-domain>
```

For example, with users `user1`–`user4` on `apps.ocp.example.com`:

| User  | URL                                                     |
| ----- | ------------------------------------------------------- |
| user1 | `https://showroom-showroom-user1.apps.ocp.example.com`  |
| user2 | `https://showroom-showroom-user2.apps.ocp.example.com`  |
| user3 | `https://showroom-showroom-user3.apps.ocp.example.com`  |
| user4 | `https://showroom-showroom-user4.apps.ocp.example.com`  |


## Run Order

Run the scripts in the order listed above. User accounts (+ worker node) should
be set up before participants access the cluster. GPU infrastructure can be
configured at any time before model deployment exercises.

```bash
oc login --server=https://api.<cluster-domain>:6443
bash create_workshop_users.sh            # users + worker node
bash gpu_machineset_hardwareprofiles.sh  # GPU MachineSet + HardwareProfile
bash deploy-showroom.sh                  # per-user Showrooms
```

## Post-Workshop Cleanup

Scale down worker nodes and remove Showroom to stop EC2 charges:

```bash
# Scale worker nodes to 0
oc get machinesets -n openshift-machine-api
oc scale machineset <worker-ms-name> -n openshift-machine-api --replicas=0

# Delete all per-user Showrooms
for u in user1 user2 user3 user4; do oc delete namespace showroom-$u; done
```
