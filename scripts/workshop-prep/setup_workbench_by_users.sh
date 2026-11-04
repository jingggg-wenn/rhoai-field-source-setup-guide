#!/bin/bash
###############################################################################
# setup_workbench_by_users.sh
#
# Create a per-user OpenShift AI workbench (Notebook) for workshop participants.
# Discovers users from Keycloak (auto) or WORKSHOP_USERS, then for each user:
#   1. Creates a project/namespace
#   2. Creates a PVC for notebook storage
#   3. Creates a Notebook CR (Jupyter | Data Science | CPU | Python 3.12)
#   4. Grants the user admin on their project
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
#
# Prerequisites:
#   - oc login with cluster-admin
#   - OpenShift AI / workbenches component ready
#   - Users already provisioned (Keycloak or htpasswd)
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
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
DASHBOARD_HOST="$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -z "$DASHBOARD_HOST" ]]; then
  DASHBOARD_HOST="$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || true)"
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
      if [[ "$disp" == *"Data Science"* && "$disp" == *"Python 3.12"* ]]; then
        is_name="$name"
        break
      fi
      # Fallback: name-based match for RHOAI 3.5 naming
      if [[ "$name" == *datascience*cpu*py312* || "$name" == *jupyter-datascience* ]]; then
        is_name="$name"
      fi
    done < <(oc get imagestreams -n "$ODH_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  fi

  if [[ -z "$is_name" ]]; then
    warn "Could not find ImageStream for '$IMAGE_DISPLAY_NAME' in $ODH_NS."
    warn "Falling back to registry image path."
    echo "registry.redhat.io/rhoai/odh-workbench-jupyter-datascience-cpu-py312-rhel9:latest"
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
  echo "$image"
}

NOTEBOOK_IMAGE="$(resolve_image)"
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
    openshift.io/display-name="${user} project" \
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
  oc apply -f - >/dev/null <<PVC
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
  success "$ns: PVC $pvc created"
}

ensure_notebook() {
  local user="$1" ns="$1"
  local base_url="/notebook/${ns}/${WORKBENCH_NAME}"
  local logout_url=""
  [[ -z "$DASHBOARD_URL" ]] || logout_url="${DASHBOARD_URL}/projects/${ns}?notebookLogout=${WORKBENCH_NAME}"

  if oc get notebook "$WORKBENCH_NAME" -n "$ns" &>/dev/null; then
    info "$ns: Notebook $WORKBENCH_NAME exists — leaving in place"
    return 0
  fi

  oc apply -f - >/dev/null <<NB
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  name: ${WORKBENCH_NAME}
  namespace: ${ns}
  annotations:
    notebooks.opendatahub.io/inject-oauth: "true"
    opendatahub.io/image-display-name: "${IMAGE_DISPLAY_NAME}"
    openshift.io/display-name: "Workbench"
    openshift.io/description: "Workshop workbench for ${user}"
    notebooks.opendatahub.io/last-image-selection: "${LAST_IMAGE_SELECTION}"
    notebooks.opendatahub.io/last-size-selection: "${WORKBENCH_SIZE}"
    opendatahub.io/username: "${user}"
    notebooks.opendatahub.io/oauth-logout-url: "${logout_url}"
  labels:
    app: ${WORKBENCH_NAME}
    opendatahub.io/dashboard: "true"
spec:
  template:
    spec:
      containers:
        - name: ${WORKBENCH_NAME}
          image: ${NOTEBOOK_IMAGE}
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
              value: ${NOTEBOOK_IMAGE}
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
  success "$ns: Notebook $WORKBENCH_NAME created"
}

###############################################################################
# Step 3: Create workbenches
###############################################################################
info "=== Step 3/4: Create per-user workbenches ==="

CREATED=0
EXISTED=0
FAILED=()

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
  else
    if ensure_notebook "$USERNAME"; then
      CREATED=$((CREATED + 1))
    else
      FAILED+=("$USERNAME"); continue
    fi
  fi
done
echo ""

###############################################################################
# Step 4: Wait for routes (best-effort)
###############################################################################
info "=== Step 4/4: Wait for workbench routes (up to 5 min each) ==="

declare -a URLS=()
for USERNAME in "${USERS[@]}"; do
  # Skip failed
  skip=false
  for f in "${FAILED[@]+"${FAILED[@]}"}"; do
    [[ "$f" == "$USERNAME" ]] && skip=true && break
  done
  [[ "$skip" == true ]] && continue

  host=""
  for _ in $(seq 1 60); do
    host="$(oc get route "$WORKBENCH_NAME" -n "$USERNAME" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "$host" ]] && break
    sleep 5
  done
  if [[ -n "$host" ]]; then
    URLS+=("${USERNAME}|https://${host}")
    success "$USERNAME → https://${host}"
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
echo "  Workbench name : $WORKBENCH_NAME"
echo "  Image          : $IMAGE_DISPLAY_NAME"
echo "  Size           : $WORKBENCH_SIZE (${CPU_REQ}–${CPU_LIM} CPU, ${MEM_REQ}–${MEM_LIM})"
echo "  PVC            : $PVC_SIZE"
echo "  Created        : $CREATED"
echo "  Already existed: $EXISTED"
[[ ${#FAILED[@]} -eq 0 ]] || echo "  Failed         : ${FAILED[*]}"
echo ""
echo "  URLs:"
for entry in "${URLS[@]+"${URLS[@]}"}"; do
  u="${entry%%|*}"
  url="${entry#*|}"
  printf '    %-12s → %s\n' "$u" "$url"
done
echo ""
echo "  Next: re-run deploy-showroom.sh with Workbench tabs (optional)"
echo "  Delete: for u in ${USERS[*]}; do oc delete notebook $WORKBENCH_NAME -n \$u; done"
echo "=============================================="
