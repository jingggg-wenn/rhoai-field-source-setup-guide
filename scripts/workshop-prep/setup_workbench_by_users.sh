#!/bin/bash
###############################################################################
# setup_workbench_by_users.sh
#
# Create a per-user OpenShift AI workbench (Notebook) for workshop participants.
# Discovers users from Keycloak (auto) or WORKSHOP_USERS, then for each user:
#   1. Creates an OpenShift AI project/namespace (<username>), shared with Showroom
#   2. Creates a PVC for notebook storage
#   3. Creates a Notebook CR (Jupyter | Data Science | CPU | Python 3.12)
#   4. Grants the user admin on their project
# Gateway-based clusters use inject-auth; legacy clusters use inject-oauth.
# Enables provisioned projects as EvalHub tenants before URL lookup.
#
# This script is idempotent — safe to re-run at any time.
#
# Usage:
#   bash setup_workbench_by_users.sh
#
#   export WORKSHOP_USERS="user1,user2,user3,user4"
#   bash setup_workbench_by_users.sh
#
# Environment variables:
#   WORKSHOP_USERS       Comma-separated user list; if unset, discovers from Keycloak
#   KC_NAMESPACE         Keycloak namespace (default: keycloak)
#   KC_REALM_IMPORT_NAME KeycloakRealmImport CR name (default: sso)
#   WORKBENCH_NAME       Notebook / workbench name (default: my-workbench)
#   WORKBENCH_SIZE       Size preset: Tiny|Small|Medium|Large (default: Small)
#   PVC_SIZE             PVC size (default: 20Gi)
#   STORAGE_CLASS        StorageClass name (default: cluster default)
#   IMAGE_STREAM         Override ImageStream name in redhat-ods-applications
#   IMAGE_TAG            Override ImageStream tag (default: recommended / latest)
#   SKIP_ADMIN           Comma-separated usernames to skip (default: admin)
#   ENABLE_EVALHUB_TENANTS  Configure EvalHub tenants after provisioning (default: true)
#   EVALHUB_NS           Shared EvalHub namespace (default: redhat-ods-applications)
#
# Prerequisites:
#   - oc login with cluster-admin
#   - OpenShift AI / workbenches component ready
#   - Users already provisioned (Keycloak or htpasswd)
#   - Shared EvalHub and TrustyAI ClusterRoles ready (unless tenant setup is disabled)
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
# Log to stderr so command substitutions never capture ANSI / log lines into YAML values
info()    { echo -e "${CYAN}[INFO]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC}   $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
fail()    { error "$*"; exit 1; }

KC_NAMESPACE="${KC_NAMESPACE:-keycloak}"
KC_REALM_IMPORT_NAME="${KC_REALM_IMPORT_NAME:-sso}"
WORKBENCH_NAME="${WORKBENCH_NAME:-my-workbench}"
WORKBENCH_SIZE="${WORKBENCH_SIZE:-Small}"
PVC_SIZE="${PVC_SIZE:-20Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
IMAGE_DISPLAY_NAME="Jupyter | Data Science | CPU | Python 3.12"
SKIP_ADMIN="${SKIP_ADMIN:-admin}"
ODH_NS="redhat-ods-applications"
ENABLE_EVALHUB_TENANTS="${ENABLE_EVALHUB_TENANTS:-true}"
case "$ENABLE_EVALHUB_TENANTS" in
  true|false) ;;
  *) fail "ENABLE_EVALHUB_TENANTS must be true or false." ;;
esac

###############################################################################
# Size presets (match dashboard Small-ish defaults)
###############################################################################
case "$WORKBENCH_SIZE" in
  Tiny)   CPU_REQ="0.5"; CPU_LIM="1";   MEM_REQ="1Gi"; MEM_LIM="2Gi" ;;
  Small)  CPU_REQ="1";   CPU_LIM="2";   MEM_REQ="4Gi"; MEM_LIM="8Gi" ;;
  Medium) CPU_REQ="2";   CPU_LIM="4";   MEM_REQ="8Gi"; MEM_LIM="16Gi" ;;
  Large)  CPU_REQ="4";   CPU_LIM="8";   MEM_REQ="16Gi"; MEM_LIM="32Gi" ;;
  *) fail "Unknown WORKBENCH_SIZE='$WORKBENCH_SIZE' (use Tiny|Small|Medium|Large)" ;;
esac

###############################################################################
# Prerequisite checks
###############################################################################
if ! oc whoami &>/dev/null; then
  fail "Not logged in to an OpenShift cluster. Run 'oc login' first."
fi
info "Logged in as: $(oc whoami)"

if ! oc api-resources --api-group=kubeflow.org 2>/dev/null | grep -q notebooks; then
  fail "Notebook CRD (kubeflow.org) not found. Is OpenShift AI workbenches installed?"
fi

DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
DASHBOARD_HOST="$(oc get route data-science-gateway -n openshift-ingress -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -z "$DASHBOARD_HOST" ]]; then
  DASHBOARD_HOST="$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || true)"
fi
GATEWAY_URL=""
[[ -z "$DASHBOARD_HOST" ]] || GATEWAY_URL="https://${DASHBOARD_HOST}"
if [[ -z "$DASHBOARD_HOST" ]]; then
  DASHBOARD_HOST="$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || true)"
fi
DASHBOARD_URL=""
[[ -z "$DASHBOARD_HOST" ]] || DASHBOARD_URL="https://${DASHBOARD_HOST}"

echo ""

###############################################################################
# Step 1: Discover users
###############################################################################
info "=== Step 1/4: Discover workshop users ==="

USERS=()
if [[ -n "${WORKSHOP_USERS:-}" ]]; then
  IFS=',' read -ra USERS <<< "$WORKSHOP_USERS"
  info "Using explicit user list: ${USERS[*]}"
elif oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" &>/dev/null; then
  KC_RAW=$(oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" \
      -o jsonpath='{.spec.realm.users[*].username}' 2>/dev/null || true)
  for u in $KC_RAW; do
    skip=false
    IFS=',' read -ra _skip_list <<< "$SKIP_ADMIN"
    for s in "${_skip_list[@]}"; do
      [[ "$u" == "$s" ]] && skip=true && break
    done
    [[ "$skip" == true ]] && continue
    USERS+=("$u")
  done
  info "Auto-discovered ${#USERS[@]} user(s) from Keycloak: ${USERS[*]}"
else
  fail "Set WORKSHOP_USERS or ensure KeycloakRealmImport '$KC_REALM_IMPORT_NAME' exists in '$KC_NAMESPACE'."
fi

[[ ${#USERS[@]} -gt 0 ]] || fail "No users found."
echo ""

###############################################################################
# Step 2: Resolve Data Science Python 3.12 image
###############################################################################
info "=== Step 2/4: Resolve workbench image ($IMAGE_DISPLAY_NAME) ==="

resolve_image() {
  local is_name="" is_tag="" image=""

  if [[ -n "${IMAGE_STREAM:-}" ]]; then
    is_name="$IMAGE_STREAM"
  else
    # Prefer ImageStreams labeled as notebook images whose display name matches.
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local disp
      disp="$(oc get imagestream "$name" -n "$ODH_NS" \
        -o jsonpath='{.metadata.annotations.opendatahub\.io/notebook-image-name}' 2>/dev/null || true)"
      if [[ "$disp" == "$IMAGE_DISPLAY_NAME" ]]; then
        is_name="$name"
        break
      fi
      # Fallback: name-based match for RHOAI 3.5 naming
      if [[ "$name" == "s2i-generic-data-science-notebook" || "$name" == *jupyter-datascience*cpu*py312* ]]; then
        is_name="$name"
      fi
    done < <(oc get imagestreams -n "$ODH_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  fi

  if [[ -z "$is_name" ]]; then
    # stdout must be ONLY the image ref (captured by caller)
    warn "Could not find ImageStream for '$IMAGE_DISPLAY_NAME' in $ODH_NS."
    warn "Falling back to registry image path."
    printf '%s\n' "registry.redhat.io/rhoai/odh-workbench-jupyter-datascience-cpu-py312-rhel9:latest"
    return 0
  fi

  if [[ -n "${IMAGE_TAG:-}" ]]; then
    is_tag="$IMAGE_TAG"
  else
    # Prefer tag annotated as recommended
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      local rec
      rec="$(oc get imagestream "$is_name" -n "$ODH_NS" \
        -o jsonpath="{.spec.tags[?(@.name==\"$tag\")].annotations.opendatahub\.io/workbench-image-recommended}" 2>/dev/null || true)"
      if [[ "$rec" == "true" ]]; then
        is_tag="$tag"
        break
      fi
    done < <(oc get imagestream "$is_name" -n "$ODH_NS" -o jsonpath='{range .spec.tags[*]}{.name}{"\n"}{end}' 2>/dev/null || true)
    # Else first / latest-ish tag
    if [[ -z "$is_tag" ]]; then
      is_tag="$(oc get imagestream "$is_name" -n "$ODH_NS" -o jsonpath='{.spec.tags[0].name}' 2>/dev/null || true)"
    fi
  fi

  [[ -n "$is_tag" ]] || fail "ImageStream '$is_name' has no tags."
  image="image-registry.openshift-image-registry.svc:5000/${ODH_NS}/${is_name}:${is_tag}"
  info "Using ImageStream ${is_name}:${is_tag}"
  printf '%s\n' "$image"
}

NOTEBOOK_IMAGE="$(resolve_image)"
# Guard against accidental log noise in the captured image ref
NOTEBOOK_IMAGE="$(printf '%s' "$NOTEBOOK_IMAGE" | tr -d '\000-\011\013-\037' | tail -n1)"
[[ "$NOTEBOOK_IMAGE" == *[:/]* ]] || fail "Resolved notebook image looks invalid: '$NOTEBOOK_IMAGE'"
success "Image: $NOTEBOOK_IMAGE"
# last-image-selection uses imagestream:tag when possible
LAST_IMAGE_SELECTION="${NOTEBOOK_IMAGE##*/}"
if [[ "$NOTEBOOK_IMAGE" == image-registry.openshift-image-registry.svc:5000/* ]]; then
  LAST_IMAGE_SELECTION="${NOTEBOOK_IMAGE#image-registry.openshift-image-registry.svc:5000/${ODH_NS}/}"
fi
echo ""

###############################################################################
# Helpers
###############################################################################
ensure_project() {
  local user="$1" ns="$1"
  if oc get namespace "$ns" &>/dev/null; then
    info "$ns: namespace exists"
  else
    oc create namespace "$ns" >/dev/null
    success "$ns: namespace created"
  fi
  oc label namespace "$ns" \
    opendatahub.io/dashboard=true \
    modelmesh-enabled=true \
    --overwrite >/dev/null
  oc annotate namespace "$ns" \
    openshift.io/display-name="${ns}" \
    openshift.io/description="Workshop project for ${user}" \
    --overwrite >/dev/null
  # User admin on their project
  oc policy add-role-to-user admin "$user" -n "$ns" >/dev/null 2>&1 || \
    oc adm policy add-role-to-user admin "$user" -n "$ns" >/dev/null
}

ensure_pvc() {
  local ns="$1" pvc="$WORKBENCH_NAME"
  if oc get pvc "$pvc" -n "$ns" &>/dev/null; then
    info "$ns: PVC $pvc exists"
    return 0
  fi
  local sc_line=""
  [[ -z "$STORAGE_CLASS" ]] || sc_line="  storageClassName: ${STORAGE_CLASS}"
  if ! oc apply -f - <<PVC; then
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${ns}
  labels:
    app: ${WORKBENCH_NAME}
spec:
  accessModes: [ReadWriteOnce]
${sc_line}
  resources:
    requests:
      storage: ${PVC_SIZE}
PVC
    error "$ns: failed to create PVC $pvc"
    return 1
  fi
  success "$ns: PVC $pvc created"
}

ensure_notebook() {
  local user="$1" ns="$1"
  local base_url="/notebook/${ns}/${WORKBENCH_NAME}"
  local logout_url=""
  local auth_annotations='    notebooks.opendatahub.io/inject-auth: "true"'
  [[ -z "$DASHBOARD_URL" ]] || logout_url="${DASHBOARD_URL}/projects/${ns}?notebookLogout=${WORKBENCH_NAME}"
  if [[ -z "$GATEWAY_URL" ]]; then
    auth_annotations="    notebooks.opendatahub.io/inject-oauth: \"true\"
    notebooks.opendatahub.io/oauth-logout-url: \"${logout_url}\""
  fi

  if oc get notebook "$WORKBENCH_NAME" -n "$ns" &>/dev/null; then
    info "$ns: Notebook $WORKBENCH_NAME exists — leaving in place"
    return 0
  fi

  if ! oc apply -f - <<NB; then
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  name: ${WORKBENCH_NAME}
  namespace: ${ns}
  annotations:
${auth_annotations}
    opendatahub.io/image-display-name: "${IMAGE_DISPLAY_NAME}"
    openshift.io/display-name: "Workbench"
    openshift.io/description: "Workshop workbench for ${user}"
    notebooks.opendatahub.io/last-image-selection: "${LAST_IMAGE_SELECTION}"
    notebooks.opendatahub.io/last-size-selection: "${WORKBENCH_SIZE}"
    opendatahub.io/username: "${user}"
  labels:
    app: ${WORKBENCH_NAME}
    opendatahub.io/dashboard: "true"
spec:
  template:
    spec:
      containers:
        - name: ${WORKBENCH_NAME}
          image: "${NOTEBOOK_IMAGE}"
          imagePullPolicy: IfNotPresent
          workingDir: /opt/app-root/src
          ports:
            - containerPort: 8888
              name: notebook-port
              protocol: TCP
          env:
            - name: NOTEBOOK_ARGS
              value: |
                --ServerApp.port=8888
                --ServerApp.token=''
                --ServerApp.password=''
                --ServerApp.base_url=${base_url}
                --ServerApp.quit_button=False
            - name: JUPYTER_IMAGE
              value: "${NOTEBOOK_IMAGE}"
          resources:
            requests:
              cpu: "${CPU_REQ}"
              memory: ${MEM_REQ}
            limits:
              cpu: "${CPU_LIM}"
              memory: ${MEM_LIM}
          volumeMounts:
            - name: ${WORKBENCH_NAME}
              mountPath: /opt/app-root/src
            - name: shm
              mountPath: /dev/shm
          readinessProbe:
            failureThreshold: 3
            httpGet:
              path: ${base_url}/api
              port: notebook-port
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 5
            successThreshold: 1
            timeoutSeconds: 1
          livenessProbe:
            failureThreshold: 3
            httpGet:
              path: ${base_url}/api
              port: notebook-port
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 5
            successThreshold: 1
            timeoutSeconds: 1
      serviceAccountName: ${WORKBENCH_NAME}
      volumes:
        - name: ${WORKBENCH_NAME}
          persistentVolumeClaim:
            claimName: ${WORKBENCH_NAME}
        - name: shm
          emptyDir:
            medium: Memory
NB
    error "$ns: failed to create Notebook $WORKBENCH_NAME"
    return 1
  fi
  success "$ns: Notebook $WORKBENCH_NAME created"
}

###############################################################################
# EvalHub tenant setup, isolated from the Workbench shell.
# Keep this inline so curl | bash does not need local helper files or downloads.
###############################################################################
setup_evalhub_tenants() (
  local EVALHUB_NS="${EVALHUB_NS:-redhat-ods-applications}"
  local EVALHUB_SA="evalhub-service" JOB_SA="evalhub-${EVALHUB_NS}-job"
  local role ns rc=0
  local tenant_failed=()

  # Only the caller's provisioned users are accepted; never rediscover users.
  [[ $# -gt 0 ]] || fail "No provisioned projects supplied for EvalHub tenant setup."
  oc get sa "$EVALHUB_SA" -n "$EVALHUB_NS" >/dev/null 2>&1 || \
    fail "ServiceAccount ${EVALHUB_SA} not found in ${EVALHUB_NS}. Deploy EvalHub first or set EVALHUB_NS."
  for role in \
    trustyai-service-operator-evalhub-mlflow-access \
    trustyai-service-operator-evalhub-jobs-writer \
    trustyai-service-operator-evalhub-job-config \
    trustyai-service-operator-evalhub-mlflow-jobs-access; do
    oc get clusterrole "$role" >/dev/null 2>&1 || \
      fail "Required ClusterRole ${role} is unavailable. Complete the TrustyAI/EvalHub installation first."
  done

  evalhub_check_permission() {
    local ns="$1" svc="$2" verb="$3" resource="$4"
    if oc auth can-i "$verb" "$resource" -n "$ns" --as="$svc" >/dev/null 2>&1; then
      success "$ns: ${svc##*:} can $verb $resource"
    else
      warn "$ns: ${svc##*:} cannot $verb $resource"
      return 1
    fi
  }

  evalhub_check_mlflow() {
    local ns="$1" svc="$2" verb="$3" allowed svc_ns
    svc_ns="${svc#system:serviceaccount:}"
    svc_ns="${svc_ns%%:*}"
    # MLflow experiments are virtual resources; query authorization directly.
    allowed=$(oc create -o jsonpath='{.status.allowed}' -f - 2>/dev/null <<EOF || true
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: ${svc}
  groups: ["system:serviceaccounts", "system:serviceaccounts:${svc_ns}", "system:authenticated"]
  resourceAttributes:
    namespace: ${ns}
    group: mlflow.kubeflow.org
    resource: experiments
    verb: ${verb}
EOF
)
    if [[ "$allowed" == true ]]; then
      success "$ns: ${svc##*:} can $verb MLflow experiments"
    else
      warn "$ns: ${svc##*:} cannot $verb MLflow experiments"
      return 1
    fi
  }

  evalhub_verify_tenant() {
    local ns="$1" failed=0 attempt ca_bundle=""
    local central_svc="system:serviceaccount:${EVALHUB_NS}:${EVALHUB_SA}"
    local job_svc="system:serviceaccount:${ns}:${JOB_SA}"

    evalhub_check_mlflow "$ns" "$central_svc" create || failed=1
    evalhub_check_mlflow "$ns" "$central_svc" get || failed=1
    evalhub_check_permission "$ns" "$central_svc" create jobs.batch || failed=1
    evalhub_check_permission "$ns" "$central_svc" create configmaps || failed=1
    evalhub_check_permission "$ns" "$central_svc" get secrets || failed=1
    evalhub_check_mlflow "$ns" "$job_svc" create || failed=1
    evalhub_check_mlflow "$ns" "$job_svc" get || failed=1
    evalhub_check_permission "$ns" "$job_svc" create pods || failed=1
    evalhub_check_permission "$ns" "$job_svc" get configmaps || failed=1
    evalhub_check_permission "$ns" "$job_svc" get secrets || failed=1

    # Service CA injection is asynchronous. Fail if it is still empty after 10s.
    for attempt in 1 2 3 4 5; do
      ca_bundle=$(oc get configmap evalhub-service-ca -n "$ns" \
        -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true)
      [[ -z "$ca_bundle" ]] || break
      sleep 2
    done
    if [[ -z "$ca_bundle" ]]; then
      ca_bundle=$(oc get configmap evalhub-service-ca -n "$ns" \
        -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null || true)
    fi
    if [[ -n "$ca_bundle" ]]; then
      success "$ns: evalhub-service-ca populated"
    else
      warn "$ns: evalhub-service-ca is empty after waiting for injection. Rerun when the service-ca operator is ready."
      failed=1
    fi

    [[ "$failed" -eq 0 ]] || return 1
    success "Namespace '${ns}' has EvalHub RBAC and CA configured"
  }

  evalhub_setup_tenant() {
    local ns="$1"
    if [[ ${#ns} -gt 63 || ! "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ || "$ns" == "$EVALHUB_NS" ]]; then
      warn "Invalid participant namespace for EvalHub: ${ns}"
      return 1
    fi
    oc get namespace "$ns" >/dev/null 2>&1 || {
      warn "Participant namespace ${ns} is unavailable for EvalHub tenant setup."
      return 1
    }
    info "Configuring EvalHub tenant RBAC in '${ns}'..."
    oc apply -f - >/dev/null <<EOF || return 1
# EvalHub service: create MLflow experiments in this namespace's workspace.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-mlflow-access
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-mlflow-access
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NS}
---
# EvalHub service: create and delete evaluation Jobs.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-jobs-writer
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-jobs-writer
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NS}
---
# EvalHub service: manage per-job ConfigMaps.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-job-config
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-job-config
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NS}
---
# EvalHub service: manage evaluation job credentials in this namespace.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: evalhub-secret-access
  namespace: ${ns}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-secret-access
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: evalhub-secret-access
subjects:
- kind: ServiceAccount
  name: ${EVALHUB_SA}
  namespace: ${EVALHUB_NS}
---
# Identity used by evaluation job pods in this namespace.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${JOB_SA}
  namespace: ${ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-job-edit
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
- kind: ServiceAccount
  name: ${JOB_SA}
  namespace: ${ns}
---
# Job pods: log to MLflow experiments in this namespace's workspace.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-job-mlflow-access
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-mlflow-jobs-access
subjects:
- kind: ServiceAccount
  name: ${JOB_SA}
  namespace: ${ns}
---
# Service CA bundle so job pods can verify EvalHub/MLflow HTTPS endpoints.
# OpenShift's service-ca operator fills in service-ca.crt automatically.
apiVersion: v1
kind: ConfigMap
metadata:
  name: evalhub-service-ca
  namespace: ${ns}
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
EOF
    evalhub_verify_tenant "$ns"
  }

  for ns in "$@"; do
    if ! evalhub_setup_tenant "$ns"; then
      tenant_failed+=("$ns")
      rc=1
    fi
  done
  if [[ "$rc" -ne 0 ]]; then
    warn "EvalHub tenant setup failed for: ${tenant_failed[*]}. Applied resources are retained; correct the error and rerun."
    exit "$rc"
  fi
  # EvalHub caches a failed MLflow workspace probe until it restarts.
  local probe_logs
  probe_logs=$(oc logs deployment/evalhub -c evalhub -n "$EVALHUB_NS" --request-timeout=10s) || exit 1
  if printf '%s\n' "$probe_logs" | grep -E '"MLflow workspace support probed".*"workspaces_enabled"[[:space:]]*:[[:space:]]*false' >/dev/null; then
    oc rollout status deployment/mlflow -n "$EVALHUB_NS" --timeout=120s || exit 1
    oc get --raw "/api/v1/namespaces/${EVALHUB_NS}/services/https:mlflow:8443/proxy/mlflow/api/3.0/mlflow/server-info" --request-timeout=10s \
      | grep -E '"workspaces_enabled"[[:space:]]*:[[:space:]]*true' >/dev/null \
      || fail "MLflow is not ready to provide workspace support. Rerun after MLflow is ready."
    warn "Restarting EvalHub to refresh its MLflow workspace probe. Re-register custom providers afterward if using the default in-memory SQLite database."
    oc rollout restart deployment/evalhub -n "$EVALHUB_NS" || exit 1
    oc rollout status deployment/evalhub -n "$EVALHUB_NS" --timeout=120s || exit 1
    oc logs deployment/evalhub -c evalhub -n "$EVALHUB_NS" --request-timeout=10s \
      | grep -E '"MLflow workspace support probed".*"workspaces_enabled"[[:space:]]*:[[:space:]]*true' >/dev/null \
      || fail "EvalHub still has not detected MLflow workspace support. Check the EvalHub startup logs."
  fi
  exit 0
)

###############################################################################
# Step 3: Create workbenches
###############################################################################
info "=== Step 3/4: Create per-user workbenches ==="

CREATED=0
EXISTED=0
FAILED=()
PROVISIONED_USERS=()

for USERNAME in "${USERS[@]}"; do
  printf '\n━━━ [%s] ━━━\n' "$USERNAME"
  if ! ensure_project "$USERNAME"; then
    FAILED+=("$USERNAME"); continue
  fi
  if ! ensure_pvc "$USERNAME"; then
    FAILED+=("$USERNAME"); continue
  fi
  if oc get notebook "$WORKBENCH_NAME" -n "$USERNAME" &>/dev/null; then
    EXISTED=$((EXISTED + 1))
    if [[ -n "$GATEWAY_URL" ]]; then
      _existing_auth="$(oc get notebooks.kubeflow.org "$WORKBENCH_NAME" -n "$USERNAME" \
        -o jsonpath='{.metadata.annotations.notebooks\.opendatahub\.io/inject-auth}' 2>/dev/null || true)"
      [[ "$_existing_auth" == "true" ]] || \
        warn "$USERNAME/$WORKBENCH_NAME: missing inject-auth annotation; existing workbench needs authentication migration (see README)."
    fi
  else
    if ensure_notebook "$USERNAME"; then
      CREATED=$((CREATED + 1))
    else
      FAILED+=("$USERNAME"); continue
    fi
  fi
  PROVISIONED_USERS+=("$USERNAME")
done
echo ""

###############################################################################
# Configure EvalHub only after all participant projects exist.
###############################################################################
EVALHUB_TENANT_STATUS="disabled"
EVALHUB_TENANT_FAILED=0
if [[ "$ENABLE_EVALHUB_TENANTS" == true ]]; then
  info "=== Configure EvalHub tenants ==="
  if [[ ${#PROVISIONED_USERS[@]} -eq 0 ]]; then
    EVALHUB_TENANT_STATUS="failed (no provisioned projects)"
    EVALHUB_TENANT_FAILED=1
    warn "Skipping EvalHub tenant setup: no Workbench projects were provisioned successfully."
  elif setup_evalhub_tenants "${PROVISIONED_USERS[@]}"; then
    EVALHUB_TENANT_STATUS="ready (${#PROVISIONED_USERS[@]} namespace(s))"
  else
    EVALHUB_TENANT_STATUS="failed (see tenant errors above)"
    EVALHUB_TENANT_FAILED=1
    warn "EvalHub tenant setup failed. Continuing to Workbench URLs and summary."
  fi
  echo ""
fi

###############################################################################
# Step 4: Resolve access URLs (Gateway or legacy Route)
###############################################################################
info "=== Step 4/4: Resolve workbench access URLs ==="

declare -a URLS=()
for USERNAME in "${USERS[@]}"; do
  # Skip failed
  skip=false
  for f in "${FAILED[@]+"${FAILED[@]}"}"; do
    [[ "$f" == "$USERNAME" ]] && skip=true && break
  done
  [[ "$skip" == true ]] && continue

  if [[ -n "$GATEWAY_URL" ]]; then
    url="${GATEWAY_URL}/notebook/${USERNAME}/${WORKBENCH_NAME}/"
    URLS+=("${USERNAME}|${url}")
    success "$USERNAME → $url (Gateway; readiness not checked)"
    continue
  fi

  host=""
  for _ in $(seq 1 60); do
    host="$(oc get route "$WORKBENCH_NAME" -n "$USERNAME" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "$host" ]] && break
    sleep 5
  done
  if [[ -n "$host" ]]; then
    url="https://${host}/notebook/${USERNAME}/${WORKBENCH_NAME}/"
    URLS+=("${USERNAME}|${url}")
    success "$USERNAME → $url"
  else
    warn "$USERNAME: route not ready yet (Notebook may still be starting)"
    URLS+=("${USERNAME}|(pending)")
  fi
done
echo ""

###############################################################################
# Summary
###############################################################################
echo "=============================================="
success "Per-user workbench setup complete."
echo ""
echo "  Users          : ${USERS[*]}"
echo "  Projects       : ${USERS[*]}"
echo "  Workbench name : $WORKBENCH_NAME"
echo "  Image          : $IMAGE_DISPLAY_NAME"
echo "  Size           : $WORKBENCH_SIZE (${CPU_REQ}–${CPU_LIM} CPU, ${MEM_REQ}–${MEM_LIM})"
echo "  PVC            : $PVC_SIZE"
echo "  Created        : $CREATED"
echo "  Already existed: $EXISTED"
[[ ${#FAILED[@]} -eq 0 ]] || echo "  Failed         : ${FAILED[*]}"
echo "  EvalHub tenants: $EVALHUB_TENANT_STATUS"
echo ""
echo "  URLs:"
for entry in "${URLS[@]+"${URLS[@]}"}"; do
  u="${entry%%|*}"
  url="${entry#*|}"
  printf '    %-12s → %s\n' "$u" "$url"
done
echo ""
echo "  Next: re-run deploy-showroom.sh with Workbench tabs (optional)"
echo "  Delete: for ns in ${USERS[*]}; do oc delete notebook $WORKBENCH_NAME -n \$ns; done"
echo "=============================================="

# Report setup errors after printing the Workbench URLs.
if [[ "$ENABLE_EVALHUB_TENANTS" == true ]]; then
  [[ "$EVALHUB_TENANT_FAILED" -eq 0 && ${#FAILED[@]} -eq 0 ]] || exit 1
fi
