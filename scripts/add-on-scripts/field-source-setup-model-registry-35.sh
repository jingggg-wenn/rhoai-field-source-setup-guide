#!/bin/bash
###############################################################################
# field-source-setup-model-registry-35.sh
#
# Enable the RHOAI 3.5 model registry, create a registry instance, register
# a small CPU embedding model with two versions (v1, v2), and deploy BOTH
# versions side by side in the 'demo' project. Every deployment is linked to
# the registry, so the platform walkthrough shows the full loop:
#
#   Catalog-style modelcar -> Registry (model + 2 versions) -> 2 live
#   deployments -> registry records which version is deployed where
#
# Target: RHOAI 3.5.2 on OpenShift 4.22+ (CPU only, no GPU required)
#
# --------------------------------------------------------------------------
# What gets created
# --------------------------------------------------------------------------
#
#   Registry instance : demo-model-registry (in the DSC registriesNamespace,
#                       default rhoai-model-registries), operator-managed
#                       PostgreSQL ("Default database (non-production)")
#   Registered model  : minilm-l6 (sentence-transformers all-MiniLM-L6-v2)
#     v1              : oci://registry.redhat.io/rhai/modelcar-all-minilm-l6-v2:1.5
#     v2              : oci://registry.redhat.io/rhai/modelcar-all-minilm-l6-v2:3.0-1793793003
#   Project           : demo
#   Deployments       : minilm-l6-v1, minilm-l6-v2 (both active)
#                       vLLM CPU (x86) runtime, default-profile customized to
#                       requests 2 CPU / 4Gi, limits 4 CPU / 8Gi
#
# --------------------------------------------------------------------------
# Key design decisions
# --------------------------------------------------------------------------
#
# 1. Standalone and idempotent.
#    Every step checks current state first and only creates or patches what
#    is missing. Re-running converges to the same end state without
#    duplicating registry entries or restarting healthy deployments.
#    Nothing outside the resources listed above is modified.
#
# 2. Component patch is a targeted merge patch.
#    Only spec.components.modelregistry.managementState is patched, and
#    only if it is not already Managed. registriesNamespace is read from
#    the DSC, never overwritten.
#
# 3. Registry entries via REST API, looked up by name.
#    The registered model and versions are found by name before creation,
#    so re-runs return the same IDs. Descriptions are re-applied on every
#    run so they always match this script.
#
# 4. ServingRuntime generated from the cluster's own template.
#    Each deployment gets its own ServingRuntime (same as the dashboard
#    does), generated with 'oc process vllm-cpu-x86-runtime-template'. The
#    image therefore always matches the installed RHOAI version; no image
#    digest is hard-coded.
#
# 5. 8Gi memory limit (OOM prevention).
#    default-profile defaults to 4Gi, and vLLM's warm-up compile on CPU
#    can exceed that (OOMKilled, exit 137). The deployments use
#    default-profile customized to its maximum: limits 4 CPU / 8Gi.
#    VLLM_CPU_KVCACHE_SPACE=1 keeps the KV cache small (embedding models
#    barely use it).
#
# 6. Registry linkage is verified and self-healed.
#    The model registry operator records a deployment once, when the
#    InferenceService first gets its registry labels. It does not follow
#    later version changes. Step 7 checks each record and, if a record
#    points at the wrong version, PATCHes it to match what is running.
#
# 7. Modelcar pulls use the cluster pull secret.
#    registry.redhat.io credentials come from the cluster-wide pull secret
#    on the nodes, so no per-project OCI connection is created.
#
# 8. No clashes with existing content in the project.
#    Everything this script creates is labelled
#    app.kubernetes.io/managed-by=field-source-setup-model-registry (the
#    registered model carries the same value as a custom property). Before
#    changing anything, Step 1 checks the target project: if an
#    InferenceService or ServingRuntime with the same name exists but was
#    not created by this script, the script aborts and changes nothing.
#    The same applies to an existing registered model with the same name.
#    Other content in the project is never touched. To run next to
#    existing content, override MODEL_NAME or TARGET_NS.
#
# --------------------------------------------------------------------------
# Execution order
# --------------------------------------------------------------------------
#
#   Step  | What                                          | Risk
#   ------|-----------------------------------------------|------------------
#    1    | Prerequisites check                           | None
#    2    | Model registry component (patch if needed)    | None
#    3    | Registry instance demo-model-registry         | None
#    4    | Register model minilm-l6 (v1, v2)             | None
#    5    | Project 'demo'                                | None
#    6    | Deploy minilm-l6-v1 and minilm-l6-v2          | None
#    7    | Registry linkage check (self-heal)            | None
#    8    | Verification (endpoints + registry)           | None
#
# All steps are idempotent. Safe to re-run at any time.
#
# --------------------------------------------------------------------------
# Usage
# --------------------------------------------------------------------------
#
#   bash field-source-setup-model-registry-35.sh
#
#   # Override names if needed:
#   REGISTRY_NAME=my-registry TARGET_NS=my-project bash field-source-setup-model-registry-35.sh
#
#   # In Web Terminal, run with nohup to survive disconnections:
#   nohup bash field-source-setup-model-registry-35.sh > /tmp/model-registry.log 2>&1 &
#   tail -f /tmp/model-registry.log
#
# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------
#
#   - oc login completed with cluster-admin, using a token-based login
#     (oc whoami -t must return a token; the registry REST API needs it)
#   - RHOAI 3.5.2 Operator installed, DataScienceCluster 'default-dsc' exists
#   - KServe Managed (Script 1, field-source-enable-all-features-35.sh)
#   - HardwareProfile 'default-profile' in redhat-ods-applications
#   - curl and jq available (both are in the OpenShift Web Terminal)
#
# Created: 25 Nov 2026
# Last modified: 25 Nov 2026
###############################################################################
set -euo pipefail

SCRIPT_START=$(date +%s)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
elapsed() { local now; now=$(date +%s); local e=$((now - SCRIPT_START)); printf '%dm%02ds' $((e/60)) $((e%60)); }
info()    { echo -e "${CYAN}[INFO]${NC} ($(elapsed)) $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

###############################################################################
# Configuration (override with environment variables)
###############################################################################
REGISTRY_NAME="${REGISTRY_NAME:-demo-model-registry}"
TARGET_NS="${TARGET_NS:-demo}"
MODEL_NAME="${MODEL_NAME:-minilm-l6}"
HW_PROFILE="${HW_PROFILE:-default-profile}"
HW_PROFILE_NS="${HW_PROFILE_NS:-redhat-ods-applications}"
RUNTIME_TEMPLATE="${RUNTIME_TEMPLATE:-vllm-cpu-x86-runtime-template}"

MODEL_DESC="all-MiniLM-L6-v2 sentence-transformers embedding model (22M parameters, 384-dimension vectors, max 512 tokens, Apache 2.0). Maps sentences and paragraphs to a dense vector space for semantic search, clustering and RAG retrieval. Packaged by Red Hat AI as an OCI modelcar; runs on CPU with the vLLM CPU (x86) runtime."

# Version definitions: name | modelcar URI | description
declare -a VER_NAMES=( "v1" "v2" )
declare -a VER_URIS=(
    "oci://registry.redhat.io/rhai/modelcar-all-minilm-l6-v2:1.5"
    "oci://registry.redhat.io/rhai/modelcar-all-minilm-l6-v2:3.0-1793793003"
)
declare -a VER_DESCS=(
    "v1: Red Hat AI modelcar build 1.5 (modelcar-all-minilm-l6-v2:1.5). Initial baseline version."
    "v2: Red Hat AI modelcar build 3.0 (modelcar-all-minilm-l6-v2:3.0-1793793003). Newer RHAI 3.0 rebuild of the same model; deployed side by side with v1."
)

# Deployment resources (default-profile max is 4 CPU / 8Gi)
CPU_REQUEST="2"; MEM_REQUEST="4Gi"
CPU_LIMIT="4";   MEM_LIMIT="8Gi"
KVCACHE_GIB="1"

# Ownership marker: every object this script creates carries it. Existing
# objects with the same name but WITHOUT the marker are treated as someone
# else's and are never modified (the script aborts instead).
MANAGED_BY_KEY="app.kubernetes.io/managed-by"
MANAGED_BY="field-source-setup-model-registry"
RAW_URL="https://raw.githubusercontent.com/jingggg-wenn/rhoai-field-source-setup-guide/main/scripts/add-on-scripts/field-source-setup-model-registry-35.sh"

echo "=============================================="
echo " RHOAI 3.5.2 Field Source -- Model Registry"
echo "=============================================="
echo ""
echo -e "${BOLD}  Step  | What                                       | Risk${NC}"
echo -e "${BOLD}  ------|--------------------------------------------|-----------------${NC}"
echo "   1    | Prerequisites check                        | None"
echo "   2    | Model registry component (patch if needed) | None"
echo "   3    | Registry instance (default PostgreSQL)     | None"
echo "   4    | Register model + versions v1, v2           | None"
echo "   5    | Project                                    | None"
echo "   6    | Deploy v1 and v2 (both active)             | None"
echo "   7    | Registry linkage check (self-heal)         | None"
echo "   8    | Verification (endpoints + registry)        | None"
echo ""
info "Registry: ${REGISTRY_NAME} | Model: ${MODEL_NAME} | Project: ${TARGET_NS}"
echo ""

###############################################################################
# Helper: wait_for -- run a check command in a loop with a progress bar
#
# Usage:
#   wait_for <timeout_sec> <label> <check_command>
#
# The check_command is eval'd each iteration. Returns 0 when the check
# passes, or 1 if the timeout is reached.
###############################################################################
wait_for() {
    local timeout="$1"
    local label="$2"
    shift 2
    local check_cmd="$*"

    local elapsed=0
    local interval=5
    local spin_chars='|/-\'
    local spin_idx=0
    local bar_width=30

    while [ $elapsed -lt "$timeout" ]; do
        if bash -c "$check_cmd" &>/dev/null; then
            printf '\r%-70s\r' " "
            success "$label"
            return 0
        fi

        local pct=$(( elapsed * 100 / timeout ))
        local filled=$(( pct * bar_width / 100 ))
        local empty=$(( bar_width - filled ))
        local spin_char="${spin_chars:$spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % 4 ))

        local bar=""
        for (( _b=0; _b<filled; _b++ )); do bar+="="; done
        if [ $filled -lt $bar_width ]; then bar+=">"; fi
        for (( _b=0; _b<empty-1; _b++ )); do bar+=" "; done

        printf '\r  %s [%-*s] %3d%% (%ds/%ds) %s' \
            "$spin_char" "$bar_width" "$bar" "$pct" "$elapsed" "$timeout" "$label"

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    printf '\r%-70s\r' " "
    warn "$label -- timeout after ${timeout}s"
    return 1
}

###############################################################################
# Helper: registry REST API
#
# Builds a CA bundle (system CAs + OpenShift ingress CA) so the token is
# never sent with curl -k. reg() wraps curl with the bearer token.
###############################################################################
CA_BUNDLE=$(mktemp)
trap 'rm -f "$CA_BUNDLE"' EXIT

build_ca_bundle() {
    : > "$CA_BUNDLE"
    for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do
        if [ -f "$f" ]; then cat "$f" >> "$CA_BUNDLE"; break; fi
    done
    oc get configmap default-ingress-cert -n openshift-config-managed \
        -o jsonpath='{.data.ca-bundle\.crt}' >> "$CA_BUNDLE" 2>/dev/null || true
}

reg() {
    curl -sf --cacert "$CA_BUNDLE" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" "$@"
}

# reg_upsert_desc <path-to-object> <description>
# Re-apply the description only if it differs (keeps re-runs quiet).
reg_upsert_desc() {
    local path="$1" desc="$2" current
    current=$(reg "${REGISTRY_API}/${path}" | jq -r '.description // ""')
    if [ "$current" != "$desc" ]; then
        reg -X PATCH "${REGISTRY_API}/${path}" -d "$(jq -n --arg d "$desc" '{description:$d}')" >/dev/null
        echo "updated"
    else
        echo "unchanged"
    fi
}

###############################################################################
# Helper: k8s_owner_state <kind> <name> <expected-storage-uri>
#
# Prints one of:
#   free    -- object does not exist
#   ours    -- object carries our managed-by label
#   adopt   -- created by an earlier version of this script (no label yet):
#              InferenceService linked to our registry with our modelcar URI,
#              or a ServingRuntime from the vLLM CPU template
#   foreign -- exists and belongs to someone else (do not touch)
###############################################################################
k8s_owner_state() {
    local kind="$1" name="$2" uri="$3" json
    json=$(oc get "$kind" "$name" -n "$TARGET_NS" -o json 2>/dev/null) || { echo free; return; }
    if [ "$(echo "$json" | jq -r --arg k "$MANAGED_BY_KEY" '.metadata.labels[$k] // ""')" = "$MANAGED_BY" ]; then
        echo ours; return
    fi
    case "$kind" in
        inferenceservice)
            if [ "$(echo "$json" | jq -r '.metadata.labels["modelregistry.opendatahub.io/name"] // ""')" = "$REGISTRY_NAME" ] && \
               [ "$(echo "$json" | jq -r '.spec.predictor.model.storageUri // ""')" = "$uri" ]; then
                echo adopt; return
            fi ;;
        servingruntime)
            local isvc_state
            isvc_state=$(k8s_owner_state inferenceservice "$name" "$uri")
            if [ "$(echo "$json" | jq -r '.metadata.annotations["opendatahub.io/template-name"] // ""')" = "$RUNTIME_TEMPLATE" ] && \
               [ "$isvc_state" != "foreign" ]; then
                echo adopt; return
            fi ;;
    esac
    echo foreign
}

###############################################################################
# Step 1: Prerequisites (abort if missing)
###############################################################################
info "=== Step 1/8: Prerequisites ==="

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

TOKEN=$(oc whoami -t 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
    error "No OAuth token for this login (oc whoami -t is empty)"
    echo "  The registry REST API needs a token. Log in with: oc login --token=... or oc login -u <user>"
    exit 1
fi
success "OAuth token available"

for bin in curl jq; do
    if ! command -v "$bin" &>/dev/null; then
        error "'$bin' not found in PATH"
        exit 1
    fi
done
success "curl and jq available"

RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $1}' || true)
if [ -z "$RHOAI_CSV" ]; then
    error "RHOAI Operator not installed"
    echo "  Install it first: bash scripts/workshop-prep/install-rhoai-operator.sh"
    exit 1
fi
success "RHOAI: $(echo "$RHOAI_CSV" | sed 's/rhods-operator\.//')"

if ! oc get datasciencecluster default-dsc &>/dev/null; then
    error "DataScienceCluster 'default-dsc' not found"
    exit 1
fi
success "DSC: default-dsc"

KSERVE_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || true)
if [ "$KSERVE_STATE" != "Managed" ]; then
    error "KServe is '${KSERVE_STATE:-unset}' (needs Managed). Run field-source-enable-all-features-35.sh first."
    exit 1
fi
success "KServe: Managed"

if ! oc get hardwareprofile "$HW_PROFILE" -n "$HW_PROFILE_NS" &>/dev/null; then
    error "HardwareProfile '${HW_PROFILE}' not found in ${HW_PROFILE_NS}"
    exit 1
fi
HW_MAX_MEM=$(oc get hardwareprofile "$HW_PROFILE" -n "$HW_PROFILE_NS" \
    -o jsonpath='{.spec.identifiers[?(@.identifier=="memory")].maxCount}' 2>/dev/null || true)
success "HardwareProfile: ${HW_PROFILE} (memory max ${HW_MAX_MEM:-n/a})"

if ! oc get template "$RUNTIME_TEMPLATE" -n redhat-ods-applications &>/dev/null; then
    error "Runtime template '${RUNTIME_TEMPLATE}' not found in redhat-ods-applications"
    exit 1
fi
RUNTIME_VERSION=$(oc get template "$RUNTIME_TEMPLATE" -n redhat-ods-applications \
    -o jsonpath='{.objects[0].metadata.annotations.opendatahub\.io/runtime-version}' 2>/dev/null || true)
success "Runtime template: ${RUNTIME_TEMPLATE} (vLLM ${RUNTIME_VERSION:-unknown})"

# Pre-flight: make sure nothing in the target project would be overwritten
if oc get namespace "$TARGET_NS" &>/dev/null; then
    CLASHES=()
    for i in "${!VER_NAMES[@]}"; do
        DEPLOY="${MODEL_NAME}-${VER_NAMES[$i]}"
        for kind in inferenceservice servingruntime; do
            STATE=$(k8s_owner_state "$kind" "$DEPLOY" "${VER_URIS[$i]}")
            if [ "$STATE" = "foreign" ]; then
                CLASHES+=("${kind}/${DEPLOY}")
            fi
        done
    done
    if [ ${#CLASHES[@]} -gt 0 ]; then
        error "Project '${TARGET_NS}' already has objects with the same names that were NOT created by this script:"
        for c in "${CLASHES[@]}"; do echo "    - ${c}"; done
        echo "  Nothing was changed. Re-run with different names, for example:"
        echo "    curl -sL ${RAW_URL} | MODEL_NAME=minilm-l6-demo bash"
        echo "    curl -sL ${RAW_URL} | TARGET_NS=demo-registry-walkthrough bash"
        exit 1
    fi
    success "Project '${TARGET_NS}' exists; no name clashes (other content is left untouched)"
    if oc get resourcequota -n "$TARGET_NS" --no-headers 2>/dev/null | grep -q .; then
        warn "ResourceQuota found in '${TARGET_NS}' -- 2 deployments need requests 4 CPU / 8Gi and limits 8 CPU / 16Gi in total"
    fi
else
    success "Project '${TARGET_NS}' does not exist yet (will be created)"
fi
echo ""

###############################################################################
# Step 2: Model registry component
###############################################################################
info "=== Step 2/8: Model registry component ==="

MR_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.modelregistry.managementState}' 2>/dev/null || true)
if [ "$MR_STATE" = "Managed" ]; then
    success "modelregistry already Managed"
else
    warn "modelregistry is '${MR_STATE:-unset}' -- patching to Managed"
    oc patch datasciencecluster default-dsc --type=merge \
        -p '{"spec":{"components":{"modelregistry":{"managementState":"Managed"}}}}' >/dev/null
    success "modelregistry patched to Managed"
fi

wait_for 300 "ModelRegistryReady condition" \
    '[ "$(oc get datasciencecluster default-dsc -o jsonpath="{.status.conditions[?(@.type==\"ModelRegistryReady\")].status}")" = "True" ]' || {
    error "Model registry component did not become ready"
    exit 1
}

MR_NS=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.modelregistry.registriesNamespace}' 2>/dev/null || true)
MR_NS="${MR_NS:-rhoai-model-registries}"
wait_for 120 "Registries namespace '${MR_NS}'" "oc get namespace ${MR_NS}" || {
    error "Namespace ${MR_NS} not created by the operator"
    exit 1
}
echo ""

###############################################################################
# Step 3: Registry instance
###############################################################################
info "=== Step 3/8: Registry instance '${REGISTRY_NAME}' ==="

if oc get modelregistries.modelregistry.opendatahub.io "$REGISTRY_NAME" -n "$MR_NS" &>/dev/null; then
    if [ "$(oc get modelregistries.modelregistry.opendatahub.io "$REGISTRY_NAME" -n "$MR_NS" \
            -o jsonpath="{.metadata.labels.app\.kubernetes\.io/managed-by}" 2>/dev/null)" = "$MANAGED_BY" ]; then
        success "ModelRegistry '${REGISTRY_NAME}' already exists"
    else
        success "ModelRegistry '${REGISTRY_NAME}' already exists (not created by this script; reused as-is, only a model is added)"
    fi
else
    info "Creating ModelRegistry '${REGISTRY_NAME}' (operator-managed PostgreSQL)..."
    oc apply -f - <<EOF >/dev/null
apiVersion: modelregistry.opendatahub.io/v1beta1
kind: ModelRegistry
metadata:
  name: ${REGISTRY_NAME}
  namespace: ${MR_NS}
  labels:
    ${MANAGED_BY_KEY}: ${MANAGED_BY}
  annotations:
    openshift.io/display-name: ${REGISTRY_NAME}
    openshift.io/description: "Demo model registry for the platform walkthrough (default PostgreSQL, non-production)"
spec:
  postgres:
    generateDeployment: true
  rest: {}
  kubeRBACProxy: {}
EOF
    success "ModelRegistry '${REGISTRY_NAME}' created"
fi

# Full resource name: the short name 'modelregistry' resolves to a different CRD
wait_for 300 "ModelRegistry Available" \
    "oc wait modelregistries.modelregistry.opendatahub.io/${REGISTRY_NAME} -n ${MR_NS} --for=condition=Available --timeout=5s" || {
    error "ModelRegistry '${REGISTRY_NAME}' not Available"
    exit 1
}
wait_for 120 "Registry route ${REGISTRY_NAME}-https" \
    "oc get route ${REGISTRY_NAME}-https -n ${MR_NS}" || {
    error "Route ${REGISTRY_NAME}-https not found"
    exit 1
}

build_ca_bundle
REGISTRY_HOST=$(oc get route "${REGISTRY_NAME}-https" -n "$MR_NS" -o jsonpath='{.spec.host}')
REGISTRY_API="https://${REGISTRY_HOST}/api/model_registry/v1alpha3"

# REST API can lag the Available condition by a few seconds
wait_for 120 "Registry REST API reachable" \
    "curl -sf --cacert ${CA_BUNDLE} -H 'Authorization: Bearer ${TOKEN}' ${REGISTRY_API}/registered_models" || {
    error "Registry REST API not reachable at ${REGISTRY_API}"
    exit 1
}
ANON_CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_BUNDLE" "${REGISTRY_API}/registered_models" || true)
if [ "$ANON_CODE" = "401" ]; then
    success "Anonymous access rejected (401)"
else
    warn "Anonymous access returned ${ANON_CODE} (expected 401)"
fi
echo ""

###############################################################################
# Step 4: Register model + versions
###############################################################################
info "=== Step 4/8: Register model '${MODEL_NAME}' ==="

MARKER_JSON=$(jq -n --arg v "$MANAGED_BY" '{managed_by:{metadataType:"MetadataStringValue", string_value:$v}}')
RM_JSON=$(reg "${REGISTRY_API}/registered_model?name=${MODEL_NAME}" 2>/dev/null || true)
RM_ID=$(echo "$RM_JSON" | jq -r '.id // empty' 2>/dev/null || true)
if [ -n "$RM_ID" ]; then
    RM_MARK=$(echo "$RM_JSON" | jq -r '.customProperties.managed_by.string_value // ""')
    RM_DESC=$(echo "$RM_JSON" | jq -r '.description // ""')
    if [ "$RM_MARK" = "$MANAGED_BY" ]; then
        success "Registered model '${MODEL_NAME}' exists (id ${RM_ID}), description $(reg_upsert_desc "registered_models/${RM_ID}" "$MODEL_DESC")"
    elif [ "$RM_DESC" = "$MODEL_DESC" ]; then
        # created by an earlier version of this script: adopt by adding the marker
        reg -X PATCH "${REGISTRY_API}/registered_models/${RM_ID}" -d "$(jq -n --argjson c "$MARKER_JSON" '{customProperties:$c}')" >/dev/null
        success "Registered model '${MODEL_NAME}' exists (id ${RM_ID}), ownership marker added"
    else
        error "Registered model '${MODEL_NAME}' already exists in '${REGISTRY_NAME}' (id ${RM_ID}) and was NOT created by this script."
        echo "  It was not modified. Re-run with a different name, for example:"
        echo "    curl -sL ${RAW_URL} | MODEL_NAME=minilm-l6-demo bash"
        exit 1
    fi
else
    RM_ID=$(reg -X POST "${REGISTRY_API}/registered_models" \
        -d "$(jq -n --arg n "$MODEL_NAME" --arg d "$MODEL_DESC" --arg o "$(oc whoami)" --argjson c "$MARKER_JSON" \
            '{name:$n, description:$d, owner:$o, customProperties:$c}')" | jq -r '.id')
    success "Registered model '${MODEL_NAME}' created (id ${RM_ID})"
fi

declare -a MV_IDS=()
for i in "${!VER_NAMES[@]}"; do
    VNAME="${VER_NAMES[$i]}"; VURI="${VER_URIS[$i]}"; VDESC="${VER_DESCS[$i]}"

    MV_ID=$(reg "${REGISTRY_API}/model_version?name=${VNAME}&parentResourceId=${RM_ID}" 2>/dev/null | jq -r '.id // empty' || true)
    if [ -n "$MV_ID" ]; then
        success "Version ${VNAME} exists (id ${MV_ID}), description $(reg_upsert_desc "model_versions/${MV_ID}" "$VDESC")"
    else
        MV_ID=$(reg -X POST "${REGISTRY_API}/model_versions" \
            -d "$(jq -n --arg n "$VNAME" --arg rm "$RM_ID" --arg d "$VDESC" --arg a "$(oc whoami)" \
                '{name:$n, registeredModelId:$rm, description:$d, author:$a}')" | jq -r '.id')
        success "Version ${VNAME} created (id ${MV_ID})"
    fi

    ART_COUNT=$(reg "${REGISTRY_API}/model_versions/${MV_ID}/artifacts" | jq -r '.size // 0')
    if [ "$ART_COUNT" = "0" ]; then
        reg -X POST "${REGISTRY_API}/model_versions/${MV_ID}/artifacts" \
            -d "$(jq -n --arg n "${MODEL_NAME}-${VNAME}-modelcar" --arg u "$VURI" --arg d "Modelcar image for ${MODEL_NAME} ${VNAME}" \
                '{artifactType:"model-artifact", name:$n, uri:$u, description:$d, modelFormatName:"vLLM", modelFormatVersion:"1"}')" >/dev/null
        success "  artifact -> ${VURI}"
    else
        EXISTING_URI=$(reg "${REGISTRY_API}/model_versions/${MV_ID}/artifacts" | jq -r '.items[0].uri')
        if [ "$EXISTING_URI" = "$VURI" ]; then
            success "  artifact unchanged -> ${VURI}"
        else
            warn "  artifact URI differs (registry: ${EXISTING_URI}); leaving it as is"
        fi
    fi
    MV_IDS+=("$MV_ID")
done
echo ""

###############################################################################
# Step 5: Project
###############################################################################
info "=== Step 5/8: Project '${TARGET_NS}' ==="

if oc get namespace "$TARGET_NS" &>/dev/null; then
    success "Namespace '${TARGET_NS}' exists"
else
    oc create namespace "$TARGET_NS" >/dev/null
    success "Namespace '${TARGET_NS}' created"
fi
oc label namespace "$TARGET_NS" opendatahub.io/dashboard=true --overwrite >/dev/null
success "'${TARGET_NS}' labeled as a Data Science Project"
echo ""

###############################################################################
# Step 6: Deploy v1 and v2 (side by side, both active)
###############################################################################
info "=== Step 6/8: Deploy ${MODEL_NAME}-v1 and ${MODEL_NAME}-v2 ==="

for i in "${!VER_NAMES[@]}"; do
    VNAME="${VER_NAMES[$i]}"; VURI="${VER_URIS[$i]}"; MV_ID="${MV_IDS[$i]}"
    DEPLOY="${MODEL_NAME}-${VNAME}"

    # ServingRuntime: generated from the cluster's template, renamed per deployment
    # (the dashboard also creates one runtime per deployment)
    oc process "$RUNTIME_TEMPLATE" -n redhat-ods-applications -o json \
      | jq --arg name "$DEPLOY" --arg mk "$MANAGED_BY_KEY" --arg mv "$MANAGED_BY" '.items[0]
            | .metadata.name = $name
            | .metadata.labels += {($mk): $mv}
            | .metadata.annotations += {
                "opendatahub.io/template-name": "vllm-cpu-x86-runtime-template",
                "opendatahub.io/template-display-name": "vLLM CPU (x86) ServingRuntime for KServe",
                "opendatahub.io/serving-runtime-scope": "global",
                "opendatahub.io/apiProtocol": "REST"}' \
      | oc apply -n "$TARGET_NS" -f - >/dev/null
    success "ServingRuntime ${DEPLOY}"

    # InferenceService: registry labels + default-profile (customized) + 8Gi limit
    APPLY_OUT=$(oc apply -f - <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ${DEPLOY}
  namespace: ${TARGET_NS}
  labels:
    ${MANAGED_BY_KEY}: ${MANAGED_BY}
    opendatahub.io/dashboard: "true"
    networking.kserve.io/visibility: exposed
    modelregistry.opendatahub.io/name: ${REGISTRY_NAME}
    modelregistry.opendatahub.io/registered-model-id: "${RM_ID}"
    modelregistry.opendatahub.io/model-version-id: "${MV_ID}"
  annotations:
    openshift.io/display-name: "${MODEL_NAME} - ${VNAME}"
    openshift.io/description: "${VER_DESCS[$i]}"
    serving.kserve.io/deploymentMode: Standard
    security.opendatahub.io/enable-auth: "true"
    opendatahub.io/hardware-profile-name: ${HW_PROFILE}
    opendatahub.io/hardware-profile-namespace: ${HW_PROFILE_NS}
    opendatahub.io/model-type: generative
    modelFormat: vLLM
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 1
    deploymentStrategy:
      type: RollingUpdate
    model:
      modelFormat:
        name: vLLM
      runtime: ${DEPLOY}
      storageUri: ${VURI}
      env:
      - name: VLLM_CPU_KVCACHE_SPACE
        value: "${KVCACHE_GIB}"
      resources:
        requests:
          cpu: "${CPU_REQUEST}"
          memory: ${MEM_REQUEST}
        limits:
          cpu: "${CPU_LIMIT}"
          memory: ${MEM_LIMIT}
EOF
)
    success "InferenceService ${DEPLOY} ($(echo "$APPLY_OUT" | awk '{print $NF}')) -> ${VURI##*/}"
done

info "Waiting for both deployments (first run pulls images; ~2-4 min)..."
for VNAME in "${VER_NAMES[@]}"; do
    wait_for 900 "${MODEL_NAME}-${VNAME} Ready" \
        "[ \"\$(oc get isvc ${MODEL_NAME}-${VNAME} -n ${TARGET_NS} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = \"True\" ]" || \
        warn "${MODEL_NAME}-${VNAME} not Ready yet -- check: oc get pods -n ${TARGET_NS}"
done
echo ""

###############################################################################
# Step 7: Registry linkage check (self-heal)
###############################################################################
info "=== Step 7/8: Registry linkage ==="

for i in "${!VER_NAMES[@]}"; do
    VNAME="${VER_NAMES[$i]}"; MV_ID="${MV_IDS[$i]}"; DEPLOY="${MODEL_NAME}-${VNAME}"

    wait_for 120 "${DEPLOY} recorded by the registry operator" \
        "[ -n \"\$(oc get isvc ${DEPLOY} -n ${TARGET_NS} -o jsonpath='{.metadata.labels.modelregistry\.opendatahub\.io/inference-service-id}')\" ]" || continue

    IS_ID=$(oc get isvc "$DEPLOY" -n "$TARGET_NS" -o jsonpath='{.metadata.labels.modelregistry\.opendatahub\.io/inference-service-id}')
    REC_MV=$(reg "${REGISTRY_API}/inference_services/${IS_ID}" | jq -r '.modelVersionId // empty')
    if [ "$REC_MV" = "$MV_ID" ]; then
        success "  record ${IS_ID}: ${DEPLOY} -> version ${VNAME} (id ${MV_ID})"
    else
        warn "  record ${IS_ID} points at version id ${REC_MV:-none}, expected ${MV_ID} -- fixing"
        reg -X PATCH "${REGISTRY_API}/inference_services/${IS_ID}" \
            -d "$(jq -n --arg mv "$MV_ID" '{modelVersionId:$mv}')" >/dev/null
        success "  record ${IS_ID} updated to version ${VNAME} (id ${MV_ID})"
    fi
done
echo ""

###############################################################################
# Step 8: Verification
###############################################################################
info "=== Step 8/8: Verification ==="
NOT_READY_COUNT=0
NOT_READY_ITEMS=()

check() {  # check <label> <condition-result 0/1> [detail]
    if [ "$2" = "0" ]; then
        echo -e "  ${GREEN}[OK]${NC} $1${3:+ ($3)}"
    else
        echo -e "  ${RED}[!!]${NC} $1${3:+ ($3)}"
        NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
        NOT_READY_ITEMS+=("$1")
    fi
}
ok() { if "$@" &>/dev/null; then echo 0; else echo 1; fi; }   # set -e safe test

info "Platform:"
S=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="ModelRegistryReady")].status}' 2>/dev/null || true)
check "ModelRegistryReady (DSC)" "$(ok [ "$S" = "True" ])"
check "ModelRegistry ${REGISTRY_NAME}" "$(ok oc wait modelregistries.modelregistry.opendatahub.io/"$REGISTRY_NAME" -n "$MR_NS" --for=condition=Available --timeout=5s)" "${MR_NS}"

echo ""
info "Registry content:"
VERS=$(reg "${REGISTRY_API}/registered_models/${RM_ID}/versions" | jq -r '[.items[] | select(.state=="LIVE") | .name] | sort | join(",")')
check "Model ${MODEL_NAME} (id ${RM_ID}) versions" "$(ok [ "$VERS" = "v1,v2" ])" "${VERS:-none}"

echo ""
info "Deployments and endpoints:"
for VNAME in "${VER_NAMES[@]}"; do
    DEPLOY="${MODEL_NAME}-${VNAME}"
    R=$(oc get isvc "$DEPLOY" -n "$TARGET_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    check "${DEPLOY} Ready" "$(ok [ "$R" = "True" ])"

    URL=$(oc get isvc "$DEPLOY" -n "$TARGET_NS" -o jsonpath='{.status.url}' 2>/dev/null || true)
    if [ "$R" = "True" ] && [ -n "$URL" ]; then
        CODE=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_BUNDLE" "${URL}/v1/models" || true)
        check "${DEPLOY} rejects anonymous calls" "$(ok [ "$CODE" = "401" ])" "HTTP ${CODE}"
        DIMS=$(curl -s --cacert "$CA_BUNDLE" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
            "${URL}/v1/embeddings" -d "{\"model\":\"${DEPLOY}\",\"input\":[\"OpenShift AI model registry\"]}" \
            | jq -r '.data[0].embedding | length' 2>/dev/null || true)
        check "${DEPLOY} /v1/embeddings" "$(ok [ "$DIMS" = "384" ])" "${DIMS:-no} dims"
    fi
done

echo ""
info "Registry records (deployments seen by the registry):"
reg "${REGISTRY_API}/inference_services" | jq -r --arg rm "$RM_ID" \
    '.items[] | select(.registeredModelId==$rm) | "\(.id)\t\(.name|split("/")[0])\tversion-id=\(.modelVersionId)\t\(.desiredState)"' \
    | while IFS=$'\t' read -r id name ver state; do
        echo "  #${id}  ${name}  ${ver}  ${state}"
    done
for i in "${!VER_NAMES[@]}"; do
    DEPLOY="${MODEL_NAME}-${VER_NAMES[$i]}"
    OK=$(reg "${REGISTRY_API}/inference_services" | jq -r --arg n "$DEPLOY" --arg mv "${MV_IDS[$i]}" \
        '[.items[] | select((.name|split("/")[0])==$n and .modelVersionId==$mv and .desiredState=="DEPLOYED")] | length')
    check "${DEPLOY} recorded as DEPLOYED (version ${VER_NAMES[$i]})" "$(ok [ "${OK:-0}" -ge 1 ])"
done

echo ""
info "Dashboard URL:"
echo "  https://$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '(check manually)')"

SCRIPT_END=$(date +%s)
TOTAL_SEC=$((SCRIPT_END - SCRIPT_START))
TOTAL_MIN=$((TOTAL_SEC / 60))
TOTAL_REMAINDER=$((TOTAL_SEC % 60))

echo ""
echo "=============================================="
if [ $NOT_READY_COUNT -eq 0 ]; then
    success "All checks passed. Total time: ${TOTAL_MIN}m${TOTAL_REMAINDER}s"
else
    warn "${NOT_READY_COUNT} item(s) NOT READY. Total time: ${TOTAL_MIN}m${TOTAL_REMAINDER}s"
    for item in "${NOT_READY_ITEMS[@]}"; do
        echo -e "  ${RED}[!!]${NC} ${item}"
    done
    echo "  Re-run this script to pick up where it left off."
fi
echo ""
echo "  Walkthrough in the dashboard:"
echo "  - AI hub -> Models -> Registry -> ${REGISTRY_NAME} -> ${MODEL_NAME}"
echo "      Versions tab: v1 and v2, each with 1 deployment"
echo "  - Projects -> ${TARGET_NS} -> Deployments: ${MODEL_NAME}-v1, ${MODEL_NAME}-v2"
echo "  - Settings -> Model resources and operations -> Model registry settings"
echo "      'No project permissions' is expected; grant a project there only if"
echo "      its workbenches/pipelines (service accounts) need registry access."
echo "=============================================="
