#!/bin/bash
###############################################################################
# install-rhoai-operator.sh
#
# Install the Red Hat OpenShift AI (RHOAI) Operator pinned to a specific
# version, on a cluster where RHOAI is NOT installed yet. Run this before
# field-source-enable-all-features-35.sh, which expects the operator,
# DSCInitialization 'default-dsci' and DataScienceCluster 'default-dsc'.
#
# Target: RHOAI 3.x on OpenShift 4.22+
#
# --------------------------------------------------------------------------
# Key design decisions
# --------------------------------------------------------------------------
#
# 1. Pin with startingCSV + Manual approval.
#    The Subscription sets startingCSV: rhods-operator.<version> and
#    installPlanApproval: Manual. OLM creates an InstallPlan for exactly that
#    version; the script approves it only after checking that the plan
#    installs the requested CSV. Later upgrades (for example 3.5.3) create
#    new InstallPlans that wait for manual approval and are never approved
#    by this script.
#
# 2. Fresh installs only.
#    If an RHOAI operator (CSV or rhods-operator Subscription) already exists
#    on the cluster, the script reports it and exits without changing
#    anything -- before asking for a version. OLM cannot downgrade or switch
#    an installed operator, so re-running is always safe. One exception: if
#    the operator is Succeeded but no DataScienceCluster exists (for example
#    after an interrupted run), default-dsc is created with `oc create`.
#    An existing DSC (any name) is never modified or replaced.
#
# 3. Version must exist in the catalog.
#    The requested CSV is checked against the channel entries in the
#    redhat-operators catalog before anything is created. Older patch
#    versions are eventually removed from the catalog.
#
# 4. DSC from the operator's own default.
#    The operator creates 'default-dsci' itself. 'default-dsc' is created
#    from the CSV's initialization-resource (the same default the console
#    offers), so the component list always matches the installed version.
#    field-source-enable-all-features-35.sh then merge-patches the full
#    feature set on top.
#
# --------------------------------------------------------------------------
# Execution order
# --------------------------------------------------------------------------
#
#   Step  | What                                          | Risk
#   ------|-----------------------------------------------|------------------
#    1    | Prerequisites + version selection             | None
#    2    | Catalog check (version exists in channel)     | None
#    3    | Namespace + OperatorGroup + Subscription      | None
#    4    | Approve the pinned InstallPlan                | None
#    5    | Wait for the operator CSV (Succeeded)         | None
#    6    | DSCInitialization + DataScienceCluster        | None
#    7    | Verification + pending upgrade check          | None
#
# All steps are idempotent. Safe to re-run at any time.
#
# --------------------------------------------------------------------------
# Usage
# --------------------------------------------------------------------------
#
#   bash install-rhoai-operator.sh
#     -> prompts: press Enter for 3.5.2, or type another version to override
#
#   RHOAI_VERSION=3.5.2 bash install-rhoai-operator.sh     # no prompt
#   RHOAI_VERSION=3.5.2 RHOAI_CHANNEL=eus-3.5 bash install-rhoai-operator.sh
#
#   # Without a terminal (nohup, CI) the prompt is skipped and the default
#   # version is used unless RHOAI_VERSION is set.
#
# Environment variables:
#   RHOAI_VERSION   Version to install, e.g. 3.5.2 (default: prompt, 3.5.2)
#   RHOAI_CHANNEL   OLM channel (default: stable-<major>.<minor>, e.g. stable-3.5)
#
# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------
#
#   - oc login completed with cluster-admin
#   - redhat-operators catalog available in openshift-marketplace
#   - RHOAI not installed (the script exits if it is already present)
#
# Created: 15 Nov 2026
# Last modified: 25 Nov 2026
###############################################################################
set -euo pipefail

SCRIPT_START=$(date +%s)

DEFAULT_RHOAI_VERSION="3.5.2"
OPERATOR_NS="redhat-ods-operator"
PACKAGE="rhods-operator"
SUB_NAME="rhods-operator"
CATALOG="redhat-operators"
CATALOG_NS="openshift-marketplace"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
elapsed() { local now; now=$(date +%s); local e=$((now - SCRIPT_START)); printf '%dm%02ds' $((e/60)) $((e%60)); }
info()    { echo -e "${CYAN}[INFO]${NC} ($(elapsed)) $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

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
# Helper: resolve_version -- RHOAI_VERSION, else prompt (default 3.5.2)
# Reads from /dev/tty so the prompt also works with `curl ... | bash`.
###############################################################################
resolve_version() {
    local answer=""
    if [[ -z "${RHOAI_VERSION:-}" ]]; then
        if { exec 3<>/dev/tty; } 2>/dev/null; then
            echo "Press Enter to install the default version (${DEFAULT_RHOAI_VERSION}, tested), or type another version (for example 3.5.4) to override." >&3
            read -r -u 3 -p "RHOAI version to install [${DEFAULT_RHOAI_VERSION}]: " answer || true
            exec 3>&-
        else
            info "No terminal detected -- using default version ${DEFAULT_RHOAI_VERSION}"
        fi
        answer="${answer//[[:space:]]/}"
        RHOAI_VERSION="${answer:-$DEFAULT_RHOAI_VERSION}"
    fi
    RHOAI_VERSION="${RHOAI_VERSION#v}"
    if [[ ! "$RHOAI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "'${RHOAI_VERSION}' is not a valid version. Use the form X.Y.Z, for example ${DEFAULT_RHOAI_VERSION}."
        exit 1
    fi
}

###############################################################################
# Helper: installed_rhods_csv -- print the installed rhods-operator CSV name
# (empty if none). Uses jsonpath + bash matching instead of grep so that
# "no match" never trips set -e / pipefail.
###############################################################################
installed_rhods_csv() {
    local names n
    names=$(oc get csv -n "$OPERATOR_NS" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    while IFS= read -r n; do
        if [[ "$n" == "${PACKAGE}".* ]]; then
            echo "$n"
            return 0
        fi
    done <<<"$names"
    return 0
}

###############################################################################
# Helper: existing_rhods_subscription -- "namespace|installedCSV|approval" of
# any Subscription for the rhods-operator package (empty if none)
###############################################################################
existing_rhods_subscription() {
    local line ns pkg csv approval
    while IFS='|' read -r ns pkg csv approval; do
        if [[ "$pkg" == "$PACKAGE" ]]; then
            echo "${ns}|${csv}|${approval}"
            return 0
        fi
    done <<<"$(oc get subscriptions.operators.coreos.com -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.spec.name}{"|"}{.status.installedCSV}{"|"}{.spec.installPlanApproval}{"\n"}{end}' \
        2>/dev/null || true)"
    return 0
}

###############################################################################
# Helper: ensure_default_dsc <csv> <csv_namespace>
#
# Creates DataScienceCluster 'default-dsc' from the CSV's own default
# (initialization-resource) ONLY if no DataScienceCluster exists at all.
# Uses `oc create` (never apply), so an existing DSC is never modified.
# Returns 0 if default-dsc exists afterwards, 1 otherwise.
###############################################################################
ensure_default_dsc() {
    local csv="$1" csv_ns="$2" existing dsc_json
    existing=$(oc get datasciencecluster -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [[ " ${existing} " == *" default-dsc "* ]]; then
        info "DataScienceCluster default-dsc already exists -- leaving in place"
        return 0
    fi
    if [[ -n "$existing" ]]; then
        # RHOAI allows only one DSC; never create a second one.
        error "A different DataScienceCluster already exists: ${existing}"
        echo "  RHOAI allows only one DSC, so default-dsc was not created."
        echo "  field-source-enable-all-features-35.sh expects it to be named default-dsc."
        return 1
    fi

    dsc_json=$(oc get csv "$csv" -n "$csv_ns" \
        -o jsonpath='{.metadata.annotations.operatorframework\.io/initialization-resource}' 2>/dev/null || true)
    if [[ -n "$dsc_json" && "$dsc_json" == *'"DataScienceCluster"'* && "$dsc_json" == *'"default-dsc"'* ]]; then
        if oc create -f - >/dev/null <<<"$dsc_json"; then
            success "DataScienceCluster: default-dsc (operator default for ${csv#"${PACKAGE}".})"
            return 0
        fi
    else
        warn "CSV has no default DSC -- creating a minimal default-dsc"
        if oc create -f - >/dev/null <<EOF
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    workbenches:
      managementState: Managed
EOF
        then
            success "DataScienceCluster: default-dsc (minimal: dashboard + workbenches)"
            return 0
        fi
    fi
    # Lost a race with someone else creating it? Then that is fine too.
    if oc get datasciencecluster default-dsc &>/dev/null; then
        info "DataScienceCluster default-dsc was created by someone else -- leaving in place"
        return 0
    fi
    error "Could not create DataScienceCluster default-dsc"
    return 1
}

###############################################################################
# Helper: list_installplans -- "name|approved|csv1,csv2" per line
###############################################################################
list_installplans() {
    oc get installplan -n "$OPERATOR_NS" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.approved}{"|"}{range .spec.clusterServiceVersionNames[*]}{@}{","}{end}{"\n"}{end}' \
        2>/dev/null || true
}

echo "=============================================="
echo " RHOAI Field Source -- Install RHOAI Operator (pinned)"
echo "=============================================="
echo ""
echo -e "${BOLD}  Step  | What                                       | Risk${NC}"
echo -e "${BOLD}  ------|--------------------------------------------|-----------------${NC}"
echo "   1    | Prerequisites + version selection          | None"
echo "   2    | Catalog check (version exists in channel)  | None"
echo "   3    | Namespace + OperatorGroup + Subscription   | None"
echo "   4    | Approve the pinned InstallPlan             | None"
echo "   5    | Wait for the operator CSV (Succeeded)      | None"
echo "   6    | DSCInitialization + DataScienceCluster     | None"
echo "   7    | Verification + pending upgrade check       | None"
echo ""
info "Installs one pinned version. Upgrades wait for manual approval."
echo ""

###############################################################################
# Step 1: Prerequisites + version selection (abort if missing)
###############################################################################
info "=== Step 1/7: Prerequisites + version selection ==="

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

if [[ "$(oc auth can-i create subscriptions.operators.coreos.com -n "$OPERATOR_NS" 2>/dev/null || true)" != "yes" ]]; then
    error "Current user cannot create Subscriptions in ${OPERATOR_NS} (cluster-admin required)"
    exit 1
fi
success "cluster-admin permissions"

# Idempotency: an existing RHOAI install is never reinstalled, upgraded or
# reconfigured. The only thing added is a missing default-dsc (for example,
# after an interrupted run), and only once the operator is fully installed.
EXISTING_CSV=$(installed_rhods_csv)
EXISTING_SUB=$(existing_rhods_subscription)
if [[ -n "$EXISTING_CSV" || -n "$EXISTING_SUB" ]]; then
    IFS='|' read -r SUB_NS SUB_CSV SUB_APPROVAL <<<"${EXISTING_SUB:-||}"
    FOUND_CSV="${EXISTING_CSV:-$SUB_CSV}"
    CSV_NS="${SUB_NS:-$OPERATOR_NS}"
    warn "RHOAI operator is already present on this cluster -- not reinstalling."
    echo "  Version      : ${FOUND_CSV#"${PACKAGE}".}"
    if [[ -n "$EXISTING_SUB" ]]; then
        echo "  Subscription : ${SUB_NS}/${PACKAGE}"
    else
        echo "  Subscription : none (operator installed without a Subscription)"
    fi
    echo "  Approval     : ${SUB_APPROVAL:-unknown}"
    echo ""

    CSV_PHASE=""
    if [[ -n "$FOUND_CSV" ]]; then
        CSV_PHASE=$(oc get csv "$FOUND_CSV" -n "$CSV_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
    fi
    if [[ "$CSV_PHASE" != "Succeeded" ]]; then
        warn "Operator is not fully installed yet (${FOUND_CSV:-no CSV}: ${CSV_PHASE:-pending})."
        echo "  Nothing was changed. Re-run this script once it shows Succeeded:"
        echo "    oc get csv -n ${CSV_NS}"
        exit 0
    fi
    success "${FOUND_CSV} Succeeded"

    if ! wait_for 120 "DSCInitialization default-dsci" 'oc get dscinitialization default-dsci'; then
        error "default-dsci not found. The operator normally creates it; check the operator logs:"
        echo "    oc logs -n ${CSV_NS} deployment/rhods-operator"
        exit 1
    fi

    ensure_default_dsc "$FOUND_CSV" "$CSV_NS" || exit 1

    if [[ "${SUB_APPROVAL:-}" != "Manual" && -n "$EXISTING_SUB" ]]; then
        echo ""
        warn "Upgrades are automatic (not pinned). To stop automatic upgrades:"
        echo "    oc patch subscription ${PACKAGE} -n ${SUB_NS} --type merge -p '{\"spec\":{\"installPlanApproval\":\"Manual\"}}'"
    fi
    echo ""
    exit 0
fi
success "RHOAI operator not installed yet"

resolve_version
TARGET_CSV="${PACKAGE}.${RHOAI_VERSION}"
RHOAI_CHANNEL="${RHOAI_CHANNEL:-stable-${RHOAI_VERSION%.*}}"
success "Target: ${TARGET_CSV} (channel ${RHOAI_CHANNEL})"
echo ""


###############################################################################
# Step 2: Catalog check
###############################################################################
info "=== Step 2/7: Catalog check ==="

if ! oc get catalogsource "$CATALOG" -n "$CATALOG_NS" &>/dev/null; then
    error "CatalogSource '${CATALOG}' not found in ${CATALOG_NS}"
    exit 1
fi
success "CatalogSource: ${CATALOG}"

CHANNEL_ENTRIES=$(oc get packagemanifest "$PACKAGE" -n "$CATALOG_NS" \
    -o jsonpath="{.status.channels[?(@.name=='${RHOAI_CHANNEL}')].entries[*].name}" 2>/dev/null || true)
if [[ -z "$CHANNEL_ENTRIES" ]]; then
    error "Channel '${RHOAI_CHANNEL}' not found for ${PACKAGE}"
    echo "  Available 3.x channels:"
    oc get packagemanifest "$PACKAGE" -n "$CATALOG_NS" \
        -o jsonpath='{range .status.channels[*]}{.name}{" (latest: "}{.currentCSV}{")"}{"\n"}{end}' 2>/dev/null \
        | grep -E '^(stable|eus|fast)-3' | sed 's/^/    /' || true
    echo "  Set RHOAI_CHANNEL to one of these and re-run."
    exit 1
fi
if [[ " ${CHANNEL_ENTRIES} " != *" ${TARGET_CSV} "* ]]; then
    error "${TARGET_CSV} is not available in channel ${RHOAI_CHANNEL}"
    echo "  Versions in ${RHOAI_CHANNEL}: ${CHANNEL_ENTRIES//${PACKAGE}./}"
    exit 1
fi
success "${TARGET_CSV} is available in channel ${RHOAI_CHANNEL}"
echo ""

###############################################################################
# Step 3: Namespace + OperatorGroup + Subscription
###############################################################################
info "=== Step 3/7: Namespace + OperatorGroup + Subscription ==="

oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${OPERATOR_NS}
EOF
success "Namespace: ${OPERATOR_NS}"

# RHOAI watches all namespaces: OperatorGroup without targetNamespaces.
EXISTING_OG=$(oc get operatorgroup -n "$OPERATOR_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$EXISTING_OG" -eq 0 ]; then
    oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${OPERATOR_NS}-og
  namespace: ${OPERATOR_NS}
spec:
  upgradeStrategy: Default
EOF
    success "OperatorGroup: ${OPERATOR_NS}-og (all namespaces)"
else
    info "OperatorGroup already exists in ${OPERATOR_NS} -- skipping creation"
fi

oc apply -f - >/dev/null <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${OPERATOR_NS}
spec:
  channel: ${RHOAI_CHANNEL}
  installPlanApproval: Manual
  name: ${PACKAGE}
  source: ${CATALOG}
  sourceNamespace: ${CATALOG_NS}
  startingCSV: ${TARGET_CSV}
EOF
success "Subscription: ${SUB_NAME} (startingCSV ${TARGET_CSV}, Manual approval)"
echo ""

###############################################################################
# Step 4: Approve the pinned InstallPlan
###############################################################################
info "=== Step 4/7: Approve the pinned InstallPlan ==="

if ! wait_for 300 "InstallPlan for ${TARGET_CSV} created" \
    "oc get installplan -n ${OPERATOR_NS} -o jsonpath='{range .items[*]}{.spec.clusterServiceVersionNames}{\"\\n\"}{end}' | grep -qF '\"${TARGET_CSV}\"'"; then
    error "No InstallPlan for ${TARGET_CSV} after 300s"
    echo "  Check: oc get subscription ${SUB_NAME} -n ${OPERATOR_NS} -o yaml"
    exit 1
fi

PLAN_NAME=""
PLAN_APPROVED=""
while IFS='|' read -r p_name p_approved p_csvs; do
    [[ -n "$p_name" ]] || continue
    if [[ ",${p_csvs}" == *",${TARGET_CSV},"* ]]; then
        PLAN_NAME="$p_name"
        PLAN_APPROVED="$p_approved"
        break
    fi
done <<<"$(list_installplans)"

if [[ -z "$PLAN_NAME" ]]; then
    error "Could not find the InstallPlan name for ${TARGET_CSV}"
    exit 1
fi

if [[ "$PLAN_APPROVED" == "true" ]]; then
    success "InstallPlan ${PLAN_NAME} already approved"
else
    oc patch installplan "$PLAN_NAME" -n "$OPERATOR_NS" --type=merge \
        -p '{"spec":{"approved":true}}' >/dev/null
    success "Approved InstallPlan ${PLAN_NAME} (${TARGET_CSV} only)"
fi
echo ""

###############################################################################
# Step 5: Wait for the operator CSV
###############################################################################
info "=== Step 5/7: Wait for the operator CSV ==="

if ! wait_for 600 "${TARGET_CSV} Succeeded" \
    "[ \"\$(oc get csv ${TARGET_CSV} -n ${OPERATOR_NS} -o jsonpath='{.status.phase}' 2>/dev/null)\" = Succeeded ]"; then
    error "${TARGET_CSV} did not reach Succeeded"
    echo "  Check: oc get csv ${TARGET_CSV} -n ${OPERATOR_NS} -o jsonpath='{.status.message}'"
    exit 1
fi
echo ""



###############################################################################
# Step 6: DSCInitialization + DataScienceCluster
###############################################################################
info "=== Step 6/7: DSCInitialization + DataScienceCluster ==="

wait_for 180 "DataScienceCluster CRD" \
    'oc get crd datascienceclusters.datasciencecluster.opendatahub.io' || true

# The operator creates default-dsci on its own (DISABLE_DSC_CONFIG=false).
if ! wait_for 300 "DSCInitialization default-dsci (created by the operator)" \
    'oc get dscinitialization default-dsci'; then
    warn "Operator did not create default-dsci -- creating a minimal one"
    # Monitoring stays Removed here: enable-all patches it to Managed after
    # the Cluster Observability Operator is ready (avoids the stuck-DSCI bug).
    if oc apply -f - >/dev/null <<EOF
apiVersion: dscinitialization.opendatahub.io/v2
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: redhat-ods-applications
  monitoring:
    managementState: Removed
    namespace: redhat-ods-monitoring
  trustedCABundle:
    managementState: Managed
    customCABundle: ""
EOF
    then
        success "DSCInitialization: default-dsci (created)"
    else
        error "Could not create DSCInitialization default-dsci"
        exit 1
    fi
fi

ensure_default_dsc "$TARGET_CSV" "$OPERATOR_NS" || exit 1

# Short wait only: some default components (for example kserve, trainer) may
# not report Ready until field-source-enable-all-features-35.sh installs their
# supporting operators and patches the DSC. Not Ready here is expected.
wait_for 300 "DataScienceCluster default-dsc Ready" \
    "[ \"\$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null)\" = Ready ]" \
    || info "default-dsc is not Ready yet -- expected; enable-all-features finishes the setup"
echo ""

###############################################################################
# Step 7: Verification + pending upgrade check
###############################################################################
info "=== Step 7/7: Verification ==="

NOT_READY_COUNT=0
NOT_READY_ITEMS=()

FINAL_CSV=$(installed_rhods_csv)
FINAL_PHASE=$(oc get csv "$TARGET_CSV" -n "$OPERATOR_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ "$FINAL_CSV" == "$TARGET_CSV" && "$FINAL_PHASE" == "Succeeded" ]]; then
    echo -e "  ${GREEN}[OK]${NC} Operator      ${TARGET_CSV} (Succeeded)"
else
    echo -e "  ${RED}[!!]${NC} Operator      ${FINAL_CSV:-none} (${FINAL_PHASE:-unknown})"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("Operator")
fi

FINAL_APPROVAL=$(oc get subscription "$SUB_NAME" -n "$OPERATOR_NS" \
    -o jsonpath='{.spec.installPlanApproval}' 2>/dev/null || true)
if [[ "$FINAL_APPROVAL" == "Manual" ]]; then
    echo -e "  ${GREEN}[OK]${NC} Upgrades      Manual approval (pinned)"
else
    echo -e "  ${RED}[!!]${NC} Upgrades      ${FINAL_APPROVAL:-unknown} (not pinned)"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("Upgrades not pinned")
fi

if oc get dscinitialization default-dsci &>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC} DSCI          default-dsci"
else
    echo -e "  ${RED}[!!]${NC} DSCI          default-dsci missing"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("DSCI default-dsci")
fi

DSC_PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ "$DSC_PHASE" == "Ready" ]]; then
    echo -e "  ${GREEN}[OK]${NC} DSC           default-dsc (Ready)"
elif [[ -n "$DSC_PHASE" ]]; then
    echo -e "  ${YELLOW}[..]${NC} DSC           default-dsc (${DSC_PHASE}) -- still reconciling"
else
    echo -e "  ${RED}[!!]${NC} DSC           default-dsc missing"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("DSC default-dsc")
fi

# Upgrades that OLM has queued but which are waiting for approval.
PENDING_UPGRADES=""
while IFS='|' read -r p_name p_approved p_csvs; do
    [[ -n "$p_name" && "$p_approved" != "true" ]] || continue
    PENDING_UPGRADES+="${p_csvs%,} (${p_name}) "
done <<<"$(list_installplans)"
if [[ -n "$PENDING_UPGRADES" ]]; then
    echo -e "  ${YELLOW}[..]${NC} Pending       ${PENDING_UPGRADES}-- NOT approved (expected)"
fi

# Total elapsed time
SCRIPT_END=$(date +%s)
TOTAL_SEC=$((SCRIPT_END - SCRIPT_START))
TOTAL_MIN=$((TOTAL_SEC / 60))
TOTAL_REMAINDER=$((TOTAL_SEC % 60))

echo ""
echo "=============================================="
if [ "$NOT_READY_COUNT" -eq 0 ]; then
    success "RHOAI ${RHOAI_VERSION} installed and pinned. Total time: ${TOTAL_MIN}m${TOTAL_REMAINDER}s"
else
    warn "${NOT_READY_COUNT} item(s) NOT READY. Total time: ${TOTAL_MIN}m${TOTAL_REMAINDER}s"
    for item in "${NOT_READY_ITEMS[@]}"; do
        echo -e "  ${RED}[!!]${NC} ${item}"
    done
    echo "  Re-run this script to pick up where it left off."
fi
echo ""
echo "  Version  : ${RHOAI_VERSION}"
echo "  Channel  : ${RHOAI_CHANNEL}"
echo "  Approval : ${FINAL_APPROVAL:-unknown}"
echo ""
echo "  Next steps:"
echo "  - Enable all features: bash scripts/field-source-enable-all-features-35.sh"
echo "  - Then MaaS setup:     bash scripts/field-source-setup-maas-35.sh"
echo ""
echo "  - Upgrades wait for manual approval. Do not approve them during a workshop."
echo "    To upgrade later: oc get installplan -n ${OPERATOR_NS}"
echo "                      oc patch installplan <name> -n ${OPERATOR_NS} --type merge -p '{\"spec\":{\"approved\":true}}'"
echo "=============================================="

[ "$NOT_READY_COUNT" -eq 0 ] || exit 1
