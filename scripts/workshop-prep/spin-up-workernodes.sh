#!/bin/bash
###############################################################################
# spin-up-workernodes.sh
#
# Add worker capacity to a Field Source (multi-node) cluster before a workshop
# by scaling the EXISTING worker MachineSets. New nodes are spread across
# availability zones (the MachineSet with the fewest replicas is scaled first).
#
# Optional: only needed if the environment was ordered with fewer workers than
# the sizing guide recommends. A multinode Field Source environment has 3 worker
# MachineSets (one per AZ). Single Node OpenShift (SNO) clusters are not supported.
#
# Sizing (total worker nodes, including the existing ones):
#   target = PLATFORM_WORKERS + ceil(users / USERS_PER_WORKER)
#   Defaults: PLATFORM_WORKERS=1, USERS_PER_WORKER=7
#     10 users -> 3 workers | 20 users -> 4 workers | 30 users -> 6 workers
#   Assumes m5a.4xlarge workers (16 vCPU, 64 GiB) and, per user: a Small
#   Workbench (1 CPU / 4 GiB requested), a Showroom, and lab workloads.
#
# The script never scales down. It is idempotent -- safe to re-run.
#
# Usage:
#   bash spin-up-workernodes.sh                  # size from Keycloak user count
#   bash spin-up-workernodes.sh --users 30       # size for 30 users
#   bash spin-up-workernodes.sh --workers 5      # exact total worker count
#   bash spin-up-workernodes.sh --users 30 --dry-run
#
# Options:
#   --users <n>     Number of workshop participants (default: Keycloak users, minus admin)
#   --workers <n>   Total worker nodes wanted (overrides --users sizing)
#   --dry-run       Show the plan without scaling anything
#   --no-wait       Scale and exit without waiting for nodes to become Ready
#
# Environment variables:
#   USERS_PER_WORKER      Users per added worker node (default: 7)
#   PLATFORM_WORKERS      Workers reserved for the RHOAI platform itself (default: 1)
#   WAIT_TIMEOUT          Seconds to wait for nodes to be Ready (default: 900)
#   KC_NAMESPACE          Keycloak namespace (default: keycloak)
#   KC_REALM_IMPORT_NAME  KeycloakRealmImport CR name (default: sso)
#
# Prerequisites:
#   - oc login with cluster-admin
#   - Cluster with existing worker MachineSets (IPI on AWS, as in Field Source)
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }
fail()    { error "$*"; exit 1; }

USERS=""
WORKERS=""
DRY_RUN=false
NO_WAIT=false
USERS_PER_WORKER="${USERS_PER_WORKER:-7}"
PLATFORM_WORKERS="${PLATFORM_WORKERS:-1}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900}"
KC_NAMESPACE="${KC_NAMESPACE:-keycloak}"
KC_REALM_IMPORT_NAME="${KC_REALM_IMPORT_NAME:-sso}"
MAPI_NS="openshift-machine-api"

usage() { sed -n '/^# Usage:/,/^# Prerequisites:/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --users)   USERS="${2:-}"; shift 2 ;;
        --workers) WORKERS="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-wait) NO_WAIT=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)" ;;
    esac
done

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }
[[ -z "$USERS" ]]   || is_int "$USERS"   || fail "--users must be a whole number (got '$USERS')"
[[ -z "$WORKERS" ]] || is_int "$WORKERS" || fail "--workers must be a whole number (got '$WORKERS')"
is_int "$USERS_PER_WORKER" && [[ "$USERS_PER_WORKER" -gt 0 ]] || fail "USERS_PER_WORKER must be a positive number"
is_int "$PLATFORM_WORKERS" || fail "PLATFORM_WORKERS must be a whole number"

echo "=============================================="
echo " Field Source -- Spin Up Worker Nodes"
echo "=============================================="
echo ""

###############################################################################
# Step 1: Prerequisites
###############################################################################
info "=== Step 1/5: Prerequisites ==="
oc whoami &>/dev/null || fail "Not logged in to an OpenShift cluster. Run 'oc login' first."
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"
[[ "$DRY_RUN" == true ]] && info "Mode: DRY RUN (no changes will be made)"
echo ""

###############################################################################
# Step 2: Find general-purpose worker MachineSets (GPU MachineSets excluded)
###############################################################################
info "=== Step 2/5: Find worker MachineSets ==="

MS_NAMES=(); MS_REPLICAS=(); MS_TYPES=()
while IFS='|' read -r name role replicas itype; do
    [[ -z "$name" ]] && continue
    [[ "$role" == "worker" ]] || continue
    # Skip GPU MachineSets (gpu_machineset_hardwareprofiles.sh names them *-worker-gpu-*)
    [[ "$name" == *gpu* ]] && continue
    [[ "$itype" =~ ^(g[0-9]|p[0-9]) ]] && continue
    MS_NAMES+=("$name"); MS_REPLICAS+=("${replicas:-0}"); MS_TYPES+=("$itype")
done < <(oc get machinesets -n "$MAPI_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.template.metadata.labels.machine\.openshift\.io/cluster-api-machine-role}{"|"}{.spec.replicas}{"|"}{.spec.template.spec.providerSpec.value.instanceType}{"\n"}{end}' 2>/dev/null || true)

[[ ${#MS_NAMES[@]} -gt 0 ]] || fail "No worker MachineSets found in $MAPI_NS. This script needs a multinode cluster (SNO is not supported)."

CURRENT=0
for i in "${!MS_NAMES[@]}"; do
    printf '  %-45s %-14s replicas=%s\n' "${MS_NAMES[$i]}" "${MS_TYPES[$i]}" "${MS_REPLICAS[$i]}"
    CURRENT=$((CURRENT + MS_REPLICAS[i]))
done
success "${#MS_NAMES[@]} worker MachineSet(s), $CURRENT worker node(s) configured"
echo ""

###############################################################################
# Step 3: Work out the target worker count
###############################################################################
info "=== Step 3/5: Size the cluster ==="

if [[ -n "$WORKERS" ]]; then
    TARGET="$WORKERS"
    info "Using explicit target: $TARGET worker node(s)"
else
    if [[ -z "$USERS" ]]; then
        if oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" &>/dev/null; then
            USERS=0
            for u in $(oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" \
                    -o jsonpath='{.spec.realm.users[*].username}' 2>/dev/null || true); do
                [[ "$u" == "admin" ]] || USERS=$((USERS + 1))
            done
            info "Counted $USERS workshop user(s) in Keycloak (admin excluded)"
        else
            fail "No Keycloak users found. Pass --users <n> or --workers <n>."
        fi
    fi
    [[ "$USERS" -gt 0 ]] || fail "User count is 0. Pass --users <n> or --workers <n>."
    TARGET=$(( PLATFORM_WORKERS + (USERS + USERS_PER_WORKER - 1) / USERS_PER_WORKER ))
    info "Sizing for $USERS user(s): $PLATFORM_WORKERS platform + ceil($USERS / $USERS_PER_WORKER) = $TARGET worker node(s)"
fi

# Show how busy the current workers already are (best effort)
info "Current worker usage (requested / allocatable):"
for name in "${MS_NAMES[@]}"; do
    for node in $(oc get machines -n "$MAPI_NS" -l "machine.openshift.io/cluster-api-machineset=$name" \
            -o jsonpath='{range .items[*]}{.status.nodeRef.name}{"\n"}{end}' 2>/dev/null || true); do
        oc describe node "$node" 2>/dev/null | awk -v n="$node" '
            /^Allocated resources:/ {s=1; next}
            s && $1=="cpu"    {cpu=$2" "$3}
            s && $1=="memory" {mem=$2" "$3; printf "  %-45s cpu %-14s memory %s\n", n, cpu, mem; exit}' || true
    done
done
echo ""

if [[ "$TARGET" -le "$CURRENT" ]]; then
    success "Already at $CURRENT worker node(s) (target $TARGET) -- nothing to scale."
    info "This script never scales down. To reduce: oc scale machineset <name> -n $MAPI_NS --replicas=<n>"
    exit 0
fi

###############################################################################
# Step 4: Spread the extra nodes across MachineSets (fewest replicas first)
###############################################################################
info "=== Step 4/5: Scale MachineSets ($CURRENT -> $TARGET) ==="

NEW_REPLICAS=("${MS_REPLICAS[@]}")
TO_ADD=$((TARGET - CURRENT))
while [[ "$TO_ADD" -gt 0 ]]; do
    min_i=0
    for i in "${!NEW_REPLICAS[@]}"; do
        [[ "${NEW_REPLICAS[$i]}" -lt "${NEW_REPLICAS[$min_i]}" ]] && min_i=$i
    done
    NEW_REPLICAS[$min_i]=$((NEW_REPLICAS[min_i] + 1))
    TO_ADD=$((TO_ADD - 1))
done

for i in "${!MS_NAMES[@]}"; do
    [[ "${NEW_REPLICAS[$i]}" -eq "${MS_REPLICAS[$i]}" ]] && continue
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] ${MS_NAMES[$i]}: ${MS_REPLICAS[$i]} -> ${NEW_REPLICAS[$i]}"
    else
        oc scale machineset "${MS_NAMES[$i]}" -n "$MAPI_NS" --replicas="${NEW_REPLICAS[$i]}" >/dev/null
        success "${MS_NAMES[$i]}: ${MS_REPLICAS[$i]} -> ${NEW_REPLICAS[$i]}"
    fi
done
echo ""

if [[ "$DRY_RUN" == true ]]; then
    info "Dry run complete. Re-run without --dry-run to apply."
    exit 0
fi

###############################################################################
# Step 5: Wait for the new nodes to be Ready
###############################################################################
if [[ "$NO_WAIT" == true ]]; then
    info "=== Step 5/5: Wait for nodes [SKIPPED -- --no-wait] ==="
    info "Monitor with: oc get machines -n $MAPI_NS -w"
else
    info "=== Step 5/5: Wait for $TARGET worker node(s) to be Ready (up to $((WAIT_TIMEOUT / 60)) min) ==="
    info "New EC2 instances usually take 5-10 minutes to boot and join."
    elapsed=0; ready=0
    while [[ "$elapsed" -lt "$WAIT_TIMEOUT" ]]; do
        ready=0
        for name in "${MS_NAMES[@]}"; do
            r=$(oc get machineset "$name" -n "$MAPI_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
            ready=$((ready + ${r:-0}))
        done
        [[ "$ready" -ge "$TARGET" ]] && break
        printf '\r  %d/%d worker node(s) Ready (%ds elapsed)   ' "$ready" "$TARGET" "$elapsed"
        sleep 15; elapsed=$((elapsed + 15))
    done
    printf '\r%-60s\r' " "
    if [[ "$ready" -ge "$TARGET" ]]; then
        success "$ready/$TARGET worker node(s) Ready"
    else
        warn "$ready/$TARGET worker node(s) Ready after $((WAIT_TIMEOUT / 60)) min -- EC2 may still be provisioning."
        warn "Check: oc get machines -n $MAPI_NS   (look for Failed machines or quota errors)"
    fi
fi
echo ""

###############################################################################
# Summary
###############################################################################
echo "=============================================="
success "Worker scale-up complete."
echo ""
echo "  Worker nodes : $CURRENT -> $TARGET"
for i in "${!MS_NAMES[@]}"; do
    printf '    %-45s replicas=%s\n' "${MS_NAMES[$i]}" "${NEW_REPLICAS[$i]}"
done
echo ""
echo "  Next: bash gpu_machineset_hardwareprofiles.sh   (then setup_workbench_by_users.sh)"
echo ""
echo "  After the workshop, scale back to the original $CURRENT worker(s):"
for i in "${!MS_NAMES[@]}"; do
    printf '    oc scale machineset %s -n %s --replicas=%s\n' "${MS_NAMES[$i]}" "$MAPI_NS" "${MS_REPLICAS[$i]}"
done
echo "=============================================="
