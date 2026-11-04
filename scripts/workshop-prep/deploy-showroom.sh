#!/usr/bin/env bash
###############################################################################
# deploy-showroom.sh
#
# Deploy per-user Showroom instances for workshop participants on OpenShift.
# Each user gets their own namespace (showroom-<username>), Route, and
# personalized Antora attributes (username, password, login command).
#
# Users are discovered from Keycloak (auto) or supplied explicitly.
#
# Usage (auto-discover users from Keycloak):
#   export SITE_TITLE="RHOAI Hands-on Workshop"
#   export WORKSHOPS="
#   basic-inference|https://github.com/org/repo.git|main|content|Basic Inference
#   "
#   bash deploy-showroom.sh
#
# Usage (explicit user list):
#   export WORKSHOP_USERS="user1,user2,user3,user4"
#   export USER_PASSWORD="openshift"
#   export SITE_TITLE="RHOAI Hands-on Workshop"
#   export WORKSHOPS="
#   basic-inference|https://github.com/org/repo.git|main|content|Basic Inference
#   "
#   bash deploy-showroom.sh
#
# WORKSHOPS format (pipe-delimited, one per line):
#   name|git_url|git_ref|content_path[|title]
#   - name:         URL path / Antora component name (a-z0-9 and hyphens)
#   - git_url:      HTTPS Git URL
#   - git_ref:      branch, tag, or commit SHA
#   - content_path: directory containing antora.yml (relative, e.g. 'content')
#   - title:        display name on the home page (optional; falls back to name)
#   Blank lines and lines starting with # are ignored.
#
# Environment variables:
#   WORKSHOPS          Multi-workshop list (required unless GIT_URL is set)
#   GIT_URL / GIT_REF / CONTENT_PATH   Single-workshop mode (backward compat)
#   SITE_TITLE         Site title (default: "Workshop")
#   WORKSHOP_USERS     Comma-separated user list; if unset, discovers from Keycloak
#   USER_PASSWORD      Common password; if unset, discovers from Keycloak
#   KC_NAMESPACE       Keycloak namespace for auto-discovery (default: "keycloak")
#   KC_REALM_IMPORT_NAME  KeycloakRealmImport CR name (default: "sso")
#   MAX_PARALLEL       Max parallel rollout waits (default: 10)
#   HOME_INDEX_FILE    Custom home page .adoc — local path or https:// URL
#   EXTRA_TABS         Additional nookbag tabs: name|url|external (one per line)
#   SKIP_FRAME_PATCH   Set to "true" to skip Console/Dashboard/Workbench Route framing patch
#
# If a Notebook+Route exists in the user's project namespace (e.g. from
# setup_workbench_by_users.sh), a Workbench tab is attached inline automatically.
#
# Requirements: bash, oc, curl, sha256sum (or shasum), mktemp, date, tr.
###############################################################################
set -euo pipefail

_red='\033[0;31m'; _green='\033[0;32m'; _yellow='\033[1;33m'
_cyan='\033[0;36m'; _nc='\033[0m'
showroom_info()    { printf "${_cyan}[INFO]${_nc} %s\n" "$*"; }
showroom_success() { printf "${_green}[ OK ]${_nc} %s\n" "$*"; }
showroom_warn()    { printf "${_yellow}[WARN]${_nc} %s\n" "$*"; }
showroom_fail()    { printf "${_red}[ERR ]${_nc} %s\n" "$*" >&2; exit 1; }

# sha256sum or shasum (macOS)
if command -v sha256sum >/dev/null 2>&1; then
  _sha256() { sha256sum; }
elif command -v shasum >/dev/null 2>&1; then
  _sha256() { shasum -a 256; }
else
  showroom_fail "Required command missing: sha256sum (or shasum)"
fi

for _cmd in oc curl tr mktemp date; do
  command -v "$_cmd" >/dev/null 2>&1 || showroom_fail "Required command missing: $_cmd"
done

###############################################################################
# 1. Parse workshop inputs
###############################################################################
declare -a ws_names=() ws_urls=() ws_refs=() ws_paths=() ws_titles=()
ws_count=0

if [[ -n "${WORKSHOPS:-}" ]]; then
  while IFS= read -r _line; do
    _line="${_line%%#*}"
    _line="$(echo "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$_line" ]] && continue

    IFS='|' read -r _name _url _ref _path _title <<< "$_line"
    _name="$(echo "$_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _url="$(echo "$_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _ref="$(echo "$_ref" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _path="$(echo "$_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _title="$(echo "${_title:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    [[ "$_name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
      showroom_fail "Workshop name must be lowercase alphanumeric with hyphens: '$_name'"
    [[ "$_name" != "home" ]] || showroom_fail "Workshop name 'home' is reserved."
    [[ "$_url" =~ ^https://[^/@[:space:]]+/[^[:space:]?#]+$ ]] || \
      showroom_fail "Workshop '$_name': git_url must be HTTPS without credentials: '$_url'"
    [[ "$_ref" != -* && ! "$_ref" =~ [[:space:]] ]] || \
      showroom_fail "Workshop '$_name': git_ref is invalid: '$_ref'"
    [[ "$_path" =~ ^[A-Za-z0-9._/-]+$ && "$_path" != /* && ! "$_path" =~ (^|/)\.\.(/|$) ]] || \
      showroom_fail "Workshop '$_name': content_path must be relative without ..: '$_path'"

    for _existing in "${ws_names[@]+"${ws_names[@]}"}"; do
      [[ "$_existing" != "$_name" ]] || showroom_fail "Duplicate workshop name: '$_name'"
    done

    ws_names+=("$_name"); ws_urls+=("$_url"); ws_refs+=("$_ref")
    ws_paths+=("$_path"); ws_titles+=("${_title:-$_name}")
    ws_count=$((ws_count + 1))
  done <<< "$WORKSHOPS"
  [[ $ws_count -gt 0 ]] || showroom_fail "WORKSHOPS is set but contains no valid entries."

elif [[ -n "${GIT_URL:-}" ]]; then
  : "${GIT_REF:?Set GIT_REF to a branch, tag, or commit}"
  : "${CONTENT_PATH:?Set CONTENT_PATH to the directory containing antora.yml}"
  [[ "$GIT_URL" =~ ^https://[^/@[:space:]]+/[^[:space:]?#]+$ ]] || \
    showroom_fail 'GIT_URL must be an HTTPS Git URL without embedded credentials.'
  [[ "$GIT_REF" != -* && ! "$GIT_REF" =~ [[:space:]] ]] || \
    showroom_fail 'GIT_REF must not start with a dash or contain whitespace.'
  [[ "$CONTENT_PATH" =~ ^[A-Za-z0-9._/-]+$ && "$CONTENT_PATH" != /* && ! "$CONTENT_PATH" =~ (^|/)\.\.(/|$) ]] || \
    showroom_fail 'CONTENT_PATH must be a relative directory without .. segments.'
  ws_names+=("workshop"); ws_urls+=("$GIT_URL"); ws_refs+=("$GIT_REF")
  ws_paths+=("$CONTENT_PATH"); ws_titles+=("Workshop"); ws_count=1
else
  showroom_fail 'Set WORKSHOPS (multi-workshop) or GIT_URL (single workshop). See script header.'
fi

SITE_TITLE="${SITE_TITLE:-Workshop}"

showroom_info "Showroom: \"$SITE_TITLE\" ($ws_count workshop(s))"
for _i in $(seq 0 $((ws_count - 1))); do
  printf '  %d. %-24s %s @ %s (%s)\n' "$((_i+1))" "${ws_names[$_i]}" "${ws_urls[$_i]}" "${ws_refs[$_i]}" "${ws_paths[$_i]}"
done
echo ""

###############################################################################
# 2. Discover users
###############################################################################
KC_NAMESPACE="${KC_NAMESPACE:-keycloak}"
KC_REALM_IMPORT_NAME="${KC_REALM_IMPORT_NAME:-sso}"
MAX_PARALLEL="${MAX_PARALLEL:-10}"

declare -a showroom_users=()

if [[ -n "${WORKSHOP_USERS:-}" ]]; then
  IFS=',' read -ra showroom_users <<< "$WORKSHOP_USERS"
  showroom_info "Using explicit user list: ${showroom_users[*]}"
elif oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" &>/dev/null; then
  _kc_raw=$(oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" \
      -o jsonpath='{.spec.realm.users[*].username}' 2>/dev/null || true)
  for _u in $_kc_raw; do
    [[ "$_u" == "admin" ]] && continue
    showroom_users+=("$_u")
  done
  showroom_info "Auto-discovered ${#showroom_users[@]} workshop user(s) from Keycloak: ${showroom_users[*]}"
else
  showroom_fail "Set WORKSHOP_USERS or ensure Keycloak is deployed with KeycloakRealmImport '$KC_REALM_IMPORT_NAME' in namespace '$KC_NAMESPACE'."
fi

[[ ${#showroom_users[@]} -gt 0 ]] || showroom_fail "No users found."

# Discover password
if [[ -z "${USER_PASSWORD:-}" ]]; then
  if oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" &>/dev/null; then
    _kc_pw=$(oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" \
      -o jsonpath='{.spec.realm.users[0].credentials[0].value}' 2>/dev/null || true)
    if [[ -n "$_kc_pw" ]]; then
      USER_PASSWORD="$_kc_pw"
      showroom_info "Auto-discovered password from Keycloak."
    fi
  fi
fi
USER_PASSWORD="${USER_PASSWORD:-Use the credentials provided by your instructor}"

###############################################################################
# 3. Cluster information
###############################################################################
showroom_info "Collecting cluster information..."
showroom_logged_in_as="$(oc whoami 2>/dev/null)" || showroom_fail 'Log in with oc login first.'
showroom_api="$(oc whoami --show-server)"
showroom_domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
[[ "$showroom_domain" =~ ^[a-zA-Z0-9.-]+$ ]] || showroom_fail 'Could not determine the cluster ingress domain.'
[[ "$(oc auth can-i create namespaces)" == yes ]] || showroom_fail 'This account needs permission to create namespaces.'

showroom_console_host="$(oc get route console -n openshift-console --ignore-not-found \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)"
showroom_console="https://${showroom_console_host:-console-openshift-console.${showroom_domain}}"

showroom_ai_host="$(oc get route data-science-gateway -n redhat-ods-applications --ignore-not-found \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -z "$showroom_ai_host" ]]; then
  showroom_ai_host="$(oc get route rhods-dashboard -n redhat-ods-applications --ignore-not-found \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
fi
showroom_ai_url=""
[[ -z "$showroom_ai_host" ]] || showroom_ai_url="https://${showroom_ai_host}/"

showroom_info "Logged in as: $showroom_logged_in_as"
showroom_info "Cluster domain: $showroom_domain"
showroom_info "Users: ${showroom_users[*]}"
echo ""

###############################################################################
# 3b. Allow Showroom to iframe Console / AI Dashboard (RHDP-style)
###############################################################################
# RHDP workshop clusters inject:
#   Content-Security-Policy: frame-ancestors 'self' https://*.apps.<domain>
# and do not send X-Frame-Options: DENY — so Showroom can embed Console directly.
# OpenTLC sandboxes typically block framing; patch the Routes once (idempotent).
_patch_route_framing() {
  local _ns="$1" _name="$2"
  if ! oc get route "$_name" -n "$_ns" &>/dev/null; then
    showroom_warn "Route $_ns/$_name not found — skipping framing patch."
    return 0
  fi
  if oc patch route "$_name" -n "$_ns" --type=merge -p "$(cat <<PATCH_EOF
{
  "metadata": {
    "annotations": {
      "showroom-bootstrap/frame-ancestors": "https://*.${showroom_domain}"
    }
  },
  "spec": {
    "httpHeaders": {
      "actions": {
        "response": [
          {
            "name": "Content-Security-Policy",
            "action": {
              "type": "Set",
              "set": {
                "value": "frame-ancestors 'self' https://*.${showroom_domain}"
              }
            }
          },
          {
            "name": "X-Frame-Options",
            "action": {
              "type": "Delete"
            }
          }
        ]
      }
    }
  }
}
PATCH_EOF
)" &>/dev/null; then
    showroom_success "Framing enabled on route ${_ns}/${_name}"
  else
    showroom_warn "Could not patch route ${_ns}/${_name} for framing (inline Console may not work)."
  fi
}

if [[ "${SKIP_FRAME_PATCH:-}" != "true" ]]; then
  showroom_info "Patching Console/Dashboard routes for iframe embedding..."
  _patch_route_framing openshift-console console
  if [[ -n "$showroom_ai_host" ]]; then
    # Prefer the route we actually discovered
    if oc get route data-science-gateway -n redhat-ods-applications &>/dev/null; then
      _patch_route_framing redhat-ods-applications data-science-gateway
    elif oc get route rhods-dashboard -n redhat-ods-applications &>/dev/null; then
      _patch_route_framing redhat-ods-applications rhods-dashboard
    fi
  fi
  echo ""
fi

###############################################################################
# 4. Generate common ConfigMap files (once)
###############################################################################
showroom_tmp="$(mktemp -d)"
trap 'rm -rf -- "$showroom_tmp"' EXIT

_use_home=false
[[ $ws_count -gt 1 ]] && _use_home=true

# ── modules.txt ──
: > "$showroom_tmp/modules.txt"
for _i in $(seq 0 $((ws_count - 1))); do
  printf '%s %s %s %s\n' "${ws_names[$_i]}" "${ws_urls[$_i]}" "${ws_refs[$_i]}" "${ws_paths[$_i]}" \
    >> "$showroom_tmp/modules.txt"
done

# ── clone.sh ──
cat > "$showroom_tmp/clone.sh" <<'CLONE_SCRIPT'
#!/bin/sh
set -eu
export HOME=/tmp
git config --global --add safe.directory '*'
SOURCES=/showroom/sources; REPO=/showroom/repo
mkdir -p "$SOURCES" "$REPO"
while read -r key url ref path; do
  [ -n "$key" ] || continue
  echo "[clone] $key <- $url ($ref)"
  rm -rf "${SOURCES:?}/$key"
  git clone --quiet --depth 1 --branch "$ref" "$url" "$SOURCES/$key"
  if [ ! -f "$SOURCES/$key/$path/antora.yml" ]; then
    echo "[clone] ERROR: $key — $path/antora.yml not found" >&2; exit 1
  fi
done < /config/modules.txt
if [ -f /config/home-antora.yml ]; then
  echo "[clone] Generating home component..."
  mkdir -p "$REPO/home/modules/ROOT/pages"
  cp /config/home-antora.yml "$REPO/home/antora.yml"
  cp /config/home-index.adoc "$REPO/home/modules/ROOT/pages/index.adoc"
  cp /config/home-nav.adoc   "$REPO/home/modules/ROOT/nav.adoc"
fi
cp /config/site.yml "$REPO/site.yml"
cd "$REPO"; rm -rf .git; git init --quiet; git add -A
git -c user.name=showroom -c user.email=showroom@localhost commit --quiet -m "showroom"
echo "[clone] All content ready."
CLONE_SCRIPT

# ── build.sh ──
cat > "$showroom_tmp/build.sh" <<'BUILD_SCRIPT'
#!/bin/bash
set -euo pipefail
SOURCES=/showroom/sources; REPO=/showroom/repo
while read -r key url ref path; do
  [ -n "$key" ] || continue
  descriptor="$SOURCES/$key/$path/antora.yml"
  if [ ! -f "$descriptor" ]; then
    echo "[build] ERROR: $key — $path/antora.yml not found" >&2; exit 1
  fi
  echo "[build] $key: rename component, inject attributes from attrs-$key.yml"
  yq -i ".name = \"$key\" | .version = \"main\" | .asciidoc.attributes *= load(\"/config/attrs-$key.yml\")" "$descriptor"
done < /config/modules.txt
echo "[build] Running Antora..."
antora --stacktrace "$REPO/site.yml"
if [ -d /showroom/www ]; then
  _page_count="$(find /showroom/www -name '*.html' | wc -l)"
  echo "[build] Done — $_page_count HTML pages generated."
else
  echo "[build] ERROR: /showroom/www not created" >&2; exit 1
fi
BUILD_SCRIPT

# ── Home component (multi-workshop only) ──
if [[ "$_use_home" == true ]]; then
  cat > "$showroom_tmp/home-antora.yml" <<'HOME_ANTORA'
name: home
version: main
nav:
  - modules/ROOT/nav.adoc
HOME_ANTORA

  if [[ -n "${HOME_INDEX_FILE:-}" && "${HOME_INDEX_FILE}" == https://* ]]; then
    showroom_info "Downloading custom home page: $HOME_INDEX_FILE"
    curl -fsSL "$HOME_INDEX_FILE" -o "$showroom_tmp/home-index.adoc" || \
      showroom_fail "Failed to download HOME_INDEX_FILE: $HOME_INDEX_FILE"
  elif [[ -n "${HOME_INDEX_FILE:-}" && -f "$HOME_INDEX_FILE" ]]; then
    cp "$HOME_INDEX_FILE" "$showroom_tmp/home-index.adoc"
    showroom_info "Using custom home page: $HOME_INDEX_FILE"
  else
    {
      printf '= %s\n\n' "$SITE_TITLE"
      printf 'Select a workshop to get started.\n\n'
      for _i in $(seq 0 $((ws_count - 1))); do
        printf '* xref:%s::index.adoc[%s]\n' "${ws_names[$_i]}" "${ws_titles[$_i]}"
      done
      printf '\n'
    } > "$showroom_tmp/home-index.adoc"
  fi

  {
    printf '* xref:index.adoc[Workshop Home]\n'
    for _i in $(seq 0 $((ws_count - 1))); do
      printf '* xref:%s::index.adoc[%s]\n' "${ws_names[$_i]}" "${ws_titles[$_i]}"
    done
  } > "$showroom_tmp/home-nav.adoc"
fi

# ── traefik-static.yml (same for all users) ──
cat > "$showroom_tmp/traefik-static.yml" <<'TRAEFIK_STATIC'
api:
  dashboard: false
  insecure: false
entryPoints:
  web:
    address: ":8080"
ping:
  entryPoint: web
providers:
  file:
    filename: /etc/traefik/dynamic.yml
    watch: false
serversTransport:
  insecureSkipVerify: true
log:
  level: WARN
global:
  checkNewVersion: false
  sendAnonymousUsage: false
TRAEFIK_STATIC

# ── traefik-dynamic.yml (same for all users — cluster-level URLs) ──
cat > "$showroom_tmp/traefik-dynamic.yml" <<TRAEFIK_DYNAMIC
http:
  routers:
    showroom:
      rule: "PathPrefix(\`/\`)"
      entryPoints: [web]
      service: showroom
      priority: 1
    console-proxy:
      rule: "PathPrefix(\`/proxy/console\`)"
      entryPoints: [web]
      service: console
      middlewares: [strip-frame-headers, console-stripprefix]
      priority: 100
    dashboard-proxy:
      rule: "PathPrefix(\`/proxy/dashboard\`)"
      entryPoints: [web]
      service: dashboard
      middlewares: [strip-frame-headers, dashboard-stripprefix]
      priority: 100
  services:
    showroom:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8000"
    console:
      loadBalancer:
        passHostHeader: false
        servers:
          - url: "${showroom_console}"
    dashboard:
      loadBalancer:
        passHostHeader: false
        servers:
          - url: "${showroom_ai_url:-${showroom_console}}"
  middlewares:
    strip-frame-headers:
      headers:
        customResponseHeaders:
          X-Frame-Options: ""
          Content-Security-Policy: ""
    console-stripprefix:
      stripPrefix:
        prefixes: ["/proxy/console"]
    dashboard-stripprefix:
      stripPrefix:
        prefixes: ["/proxy/dashboard"]
TRAEFIK_DYNAMIC

# Discover first Notebook+Route in the user's project namespace.
# Prints: <notebook-name>|https://<host>
_lookup_workbench() {
  local _wb_ns="$1"
  local _wb_name="" _wb_host=""

  _wb_name="$(oc get notebook -n "$_wb_ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$_wb_name" ]] || return 1

  _wb_host="$(oc get route "$_wb_name" -n "$_wb_ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "$_wb_host" ]] || return 1

  printf '%s|https://%s' "$_wb_name" "$_wb_host"
  return 0
}

# Write per-user ui-config.yml (optional inline Workbench tab)
_write_ui_config() {
  local _out="$1"
  local _user="$2"
  local _workbench_url="${3:-}"

  {
    cat <<UI_HEAD
type: showroom
default_width: 30
persist_url_state: true
antora:
  dir: www
  name: www
  modules:
UI_HEAD

    if [[ "$_use_home" == true ]]; then
      printf '    - name: home/main/index\n'
    else
      printf '    - name: %s/main/index\n' "${ws_names[0]}"
    fi

    printf 'tabs:\n'
    # Direct URLs (RHDP style) — inline iframes once Route framing patch is applied.
    if [[ -n "$showroom_ai_url" ]]; then
      printf '  - name: OpenShift AI Dashboard\n'
      printf '    url: "%s"\n' "$showroom_ai_url"
    fi
    printf '  - name: OpenShift Console\n'
    printf '    url: "%s"\n' "$showroom_console"

    # Workbench — always inline (no external: true)
    if [[ -n "$_workbench_url" ]]; then
      printf '  - name: Workbench\n'
      printf '    url: "%s"\n' "$_workbench_url"
    fi

    if [[ -n "${EXTRA_TABS:-}" ]]; then
      while IFS= read -r _tab_line; do
        _tab_line="$(echo "$_tab_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$_tab_line" || "$_tab_line" == \#* ]] && continue
        IFS='|' read -r _tab_name _tab_url _tab_ext <<< "$_tab_line"
        _tab_name="$(echo "$_tab_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        _tab_url="$(echo "$_tab_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        _tab_ext="$(echo "${_tab_ext:-true}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        _tab_url="${_tab_url//\{user\}/${_user}}"
        printf '  - name: %s\n' "$_tab_name"
        printf '    url: "%s"\n' "$_tab_url"
        [[ "$_tab_ext" == "true" ]] && printf '    external: true\n'
      done <<< "$EXTRA_TABS"
    fi
  } > "$_out"
}

###############################################################################
# 5. Deploy per-user Showrooms
###############################################################################
printf '\n'
printf '══════════════════════════════════════════════════\n'
printf ' Deploying Showroom for %d user(s)\n' "${#showroom_users[@]}"
printf '══════════════════════════════════════════════════\n\n'

declare -a _deployed_users=() _failed_users=() _workbench_attached=()

for _username in "${showroom_users[@]}"; do
  printf '━━━ [%s] Deploying... ━━━\n' "$_username"

  _ns="showroom-${_username}"
  _host="showroom-${_ns}.${showroom_domain}"
  _url="https://${_host}"
  _run="$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
  _user_tmp="$showroom_tmp/$_username"
  mkdir -p "$_user_tmp"

  # ── Detect per-user workbench and attach as inline tab ──
  _workbench_url=""
  _workbench_nb=""
  _wb_lookup=""
  if _wb_lookup="$(_lookup_workbench "$_username")"; then
    _workbench_nb="${_wb_lookup%%|*}"
    _workbench_url="${_wb_lookup#*|}"
    showroom_success "$_username — workbench found (inline): $_workbench_url"
    _workbench_attached+=("$_username")
    if [[ "${SKIP_FRAME_PATCH:-}" != "true" ]]; then
      _patch_route_framing "$_username" "$_workbench_nb"
    fi
  else
    showroom_info "$_username — no workbench in ns '${_username}' (tab skipped)"
  fi

  # ── Per-user ui-config (may include inline Workbench tab) ──
  _write_ui_config "$_user_tmp/ui-config.yml" "$_username" "$_workbench_url"

  # ── Per-user attrs ──
  for _i in $(seq 0 $((ws_count - 1))); do
    cat > "$_user_tmp/attrs-${ws_names[$_i]}.yml" <<ATTRS_EOF
user: "${_username}"
username: "${_username}"
guid: "${_username}"
password: "${USER_PASSWORD}"
openshift_cluster_ingress_domain: "${showroom_domain}"
openshift_api_url: "${showroom_api}"
openshift_api_server_url: "${showroom_api}"
openshift_cluster_console_url: "${showroom_console}"
page-openshift_cluster_console_url: "${showroom_console}"
login_command: "oc login -u ${_username} ${showroom_api}"
ATTRS_EOF
    if [[ -n "$showroom_ai_url" ]]; then
      cat >> "$_user_tmp/attrs-${ws_names[$_i]}.yml" <<RHOAI_ATTRS
rhoai_dashboard_url: "${showroom_ai_url}"
page-rhoai_dashboard_url: "${showroom_ai_url}"
RHOAI_ATTRS
    fi
    if [[ -n "$_workbench_url" ]]; then
      cat >> "$_user_tmp/attrs-${ws_names[$_i]}.yml" <<WB_ATTRS
workbench_url: "${_workbench_url}"
page-workbench_url: "${_workbench_url}"
WB_ATTRS
    fi
  done

  # ── Per-user site.yml (URL differs per user) ──
  {
    cat <<SITE_HEAD
site:
  title: "${SITE_TITLE}"
  url: "${_url}"
SITE_HEAD
    if [[ "$_use_home" == true ]]; then
      printf '  start_page: home::index.adoc\n'
    else
      printf '  start_page: %s::index.adoc\n' "${ws_names[0]}"
    fi
    printf 'content:\n  sources:\n'
    if [[ "$_use_home" == true ]]; then
      cat <<'HOME_SRC'
    - url: /showroom/repo
      branches: HEAD
      start_path: home
HOME_SRC
    fi
    for _i in $(seq 0 $((ws_count - 1))); do
      printf '    - url: /showroom/sources/%s\n' "${ws_names[$_i]}"
      printf '      branches: HEAD\n'
      printf '      start_path: %s\n' "${ws_paths[$_i]}"
    done
    cat <<'SITE_TAIL'
ui:
  bundle:
    url: https://github.com/rhpds/rhdp_showroom_theme/releases/download/latest/ui-bundle.zip
    snapshot: true
runtime:
  cache_dir: /tmp/.cache/antora
output:
  dir: /showroom/www
SITE_TAIL
  } > "$_user_tmp/site.yml"

  # ── Namespace ──
  _existing="$(oc get namespace "$_ns" --ignore-not-found -o jsonpath='{.metadata.name}')"
  if [[ -n "$_existing" ]]; then
    _owner="$(oc get namespace "$_ns" \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
    if [[ "$_owner" != "showroom-bootstrap" ]]; then
      showroom_warn "$_ns: namespace exists but not managed by this script — adding label."
      oc label namespace "$_ns" app.kubernetes.io/managed-by=showroom-bootstrap --overwrite
    fi
  else
    oc create namespace "$_ns"
    oc label namespace "$_ns" app.kubernetes.io/managed-by=showroom-bootstrap
  fi

  # ── ConfigMap (common files + per-user attrs/site/ui-config) ──
  _cm_args=(showroom-config -n "$_ns" --dry-run=client -o yaml)
  _cm_args+=(--from-file=modules.txt="$showroom_tmp/modules.txt")
  _cm_args+=(--from-file=clone.sh="$showroom_tmp/clone.sh")
  _cm_args+=(--from-file=build.sh="$showroom_tmp/build.sh")
  _cm_args+=(--from-file=site.yml="$_user_tmp/site.yml")
  _cm_args+=(--from-file=ui-config.yml="$_user_tmp/ui-config.yml")
  _cm_args+=(--from-file=traefik-static.yml="$showroom_tmp/traefik-static.yml")
  _cm_args+=(--from-file=traefik-dynamic.yml="$showroom_tmp/traefik-dynamic.yml")

  if [[ "$_use_home" == true ]]; then
    _cm_args+=(--from-file=home-antora.yml="$showroom_tmp/home-antora.yml")
    _cm_args+=(--from-file=home-index.adoc="$showroom_tmp/home-index.adoc")
    _cm_args+=(--from-file=home-nav.adoc="$showroom_tmp/home-nav.adoc")
  fi
  for _i in $(seq 0 $((ws_count - 1))); do
    _cm_args+=(--from-file="attrs-${ws_names[$_i]}.yml=$_user_tmp/attrs-${ws_names[$_i]}.yml")
  done

  if ! oc create configmap "${_cm_args[@]}" | oc apply -f -; then
    showroom_warn "$_username — ConfigMap apply failed, skipping."
    _failed_users+=("$_username"); continue
  fi

  # ── Workload (Deployment + Service + Route) ──
  cat > "$_user_tmp/workload.yaml" <<WORKLOAD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: showroom
  namespace: ${_ns}
  labels: {app.kubernetes.io/managed-by: showroom-bootstrap}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app.kubernetes.io/name: showroom}
  template:
    metadata:
      labels: {app.kubernetes.io/name: showroom}
      annotations: {showroom-bootstrap/run: "${_run}"}
    spec:
      automountServiceAccountToken: false
      initContainers:
        - name: clone
          image: quay.io/rhpds/git-cloner:v1.1.5
          command: [sh, /config/clone.sh]
          env:
            - {name: GIT_TERMINAL_PROMPT, value: "0"}
          volumeMounts: &build-mounts
            - {name: config, mountPath: /config, readOnly: true}
            - {name: work, mountPath: /showroom/repo, subPath: repo}
            - {name: work, mountPath: /showroom/sources, subPath: sources}
            - {name: work, mountPath: /showroom/www, subPath: www}
          resources: &build-resources
            requests: {cpu: 100m, memory: 256Mi}
            limits: {cpu: "1", memory: 1Gi}
        - name: build
          image: quay.io/rhpds/antora:v1.3.0
          command: [bash, /config/build.sh]
          volumeMounts: *build-mounts
          resources: *build-resources
      containers:
        - name: proxy
          image: quay.io/rhpds/traefik:v3.7.9
          args: ["--configFile=/etc/traefik/traefik-static.yml"]
          ports: [{name: web, containerPort: 8080}]
          volumeMounts:
            - {name: config, mountPath: /etc/traefik/traefik-static.yml, subPath: traefik-static.yml, readOnly: true}
            - {name: config, mountPath: /etc/traefik/dynamic.yml, subPath: traefik-dynamic.yml, readOnly: true}
          livenessProbe:
            httpGet: {path: /ping, port: 8080}
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: {path: /ping, port: 8080}
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests: {cpu: 5m, memory: 16Mi}
            limits: {cpu: 100m, memory: 64Mi}
        - name: content
          image: quay.io/rhpds/showroom-content:v1.4.3
          env:
            - {name: ANTORA_PLAYBOOK, value: site.yml}
            - {name: ZT_UI_ENABLED, value: "true"}
            - {name: ZT_BUNDLE, value: "https://github.com/rhpds/nookbag/releases/download/nookbag-v0.5.1/nookbag-v0.5.1.zip"}
            - name: SHOWROOM_UI_CONFIG
              valueFrom: {configMapKeyRef: {name: showroom-config, key: ui-config.yml}}
          ports: [{name: http, containerPort: 8000}]
          startupProbe:
            httpGet: {path: /, port: http}
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet: {path: /, port: http}
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /, port: http}
            periodSeconds: 20
          volumeMounts:
            - {name: work, mountPath: /showroom/repo, subPath: repo}
            - {name: work, mountPath: /showroom/www, subPath: www}
          resources:
            requests: {cpu: 10m, memory: 64Mi}
            limits: {cpu: 200m, memory: 256Mi}
      volumes:
        - name: config
          configMap: {name: showroom-config}
        - name: work
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: showroom
  namespace: ${_ns}
spec:
  selector: {app.kubernetes.io/name: showroom}
  ports: [{name: http, port: 8080, targetPort: web}]
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: showroom
  namespace: ${_ns}
  annotations:
    haproxy.router.openshift.io/timeout: 1h
    haproxy.router.openshift.io/timeout-tunnel: 1h
spec:
  host: "${_host}"
  to: {kind: Service, name: showroom}
  port: {targetPort: http}
  tls: {termination: edge, insecureEdgeTerminationPolicy: Redirect}
WORKLOAD

  if oc apply -f "$_user_tmp/workload.yaml"; then
    _deployed_users+=("$_username")
    showroom_success "$_username — resources applied (ns: $_ns)"
  else
    _failed_users+=("$_username")
    showroom_warn "$_username — workload apply failed."
  fi
  echo ""
done

###############################################################################
# 6. Wait for all rollouts in parallel
###############################################################################
if [[ ${#_deployed_users[@]} -gt 0 ]]; then
  printf '━━━ Waiting for all rollouts (max %s parallel)... ━━━\n' "$MAX_PARALLEL"

  declare -a _wait_pids=() _wait_users=() _rollout_failed=()

  for _username in "${_deployed_users[@]}"; do
    _ns="showroom-${_username}"
    oc rollout status deployment/showroom -n "$_ns" --timeout=600s &>/dev/null &
    _wait_pids+=($!)
    _wait_users+=("$_username")

    if [[ ${#_wait_pids[@]} -ge $MAX_PARALLEL ]]; then
      if ! wait "${_wait_pids[0]}" 2>/dev/null; then
        _rollout_failed+=("${_wait_users[0]}")
      fi
      _wait_pids=("${_wait_pids[@]:1}")
      _wait_users=("${_wait_users[@]:1}")
    fi
  done

  for _idx in "${!_wait_pids[@]}"; do
    if ! wait "${_wait_pids[$_idx]}" 2>/dev/null; then
      _rollout_failed+=("${_wait_users[$_idx]}")
    fi
  done

  for _rf in "${_rollout_failed[@]+"${_rollout_failed[@]}"}"; do
    _failed_users+=("$_rf")
    showroom_warn "$_rf — rollout did not complete in time."
  done
fi

###############################################################################
# 7. Summary
###############################################################################
_ok_count=0
for _username in "${_deployed_users[@]}"; do
  _is_failed=false
  for _f in "${_failed_users[@]+"${_failed_users[@]}"}"; do
    [[ "$_f" == "$_username" ]] && _is_failed=true && break
  done
  [[ "$_is_failed" == true ]] || _ok_count=$((_ok_count + 1))
done

printf '\n'
printf '══════════════════════════════════════════════════\n'
printf ' Showroom deployment complete!\n'
printf '══════════════════════════════════════════════════\n\n'
printf '  Total users : %d\n' "${#showroom_users[@]}"
printf '  Succeeded   : %d\n' "$_ok_count"
printf '  Workbench   : %d attached (inline)\n' "${#_workbench_attached[@]}"
[[ ${#_failed_users[@]} -eq 0 ]] || \
  printf '  Failed      : %d — %s\n' "${#_failed_users[@]}" "${_failed_users[*]}"
printf '\n'
printf '  URLs:\n'
for _username in "${_deployed_users[@]}"; do
  _is_failed=false
  for _f in "${_failed_users[@]+"${_failed_users[@]}"}"; do
    [[ "$_f" == "$_username" ]] && _is_failed=true && break
  done
  [[ "$_is_failed" == true ]] && continue
  printf '    %-12s → https://showroom-showroom-%s.%s\n' "$_username" "$_username" "$showroom_domain"
done
printf '\n'
printf '  Workshops : %d\n' "$ws_count"
for _i in $(seq 0 $((ws_count - 1))); do
  printf '    %d. %s\n' "$((_i+1))" "${ws_titles[$_i]}"
done
printf '\n'
printf '  Update    : re-run this script (idempotent)\n'
printf '  Delete all: for u in %s; do oc delete ns showroom-\$u; done\n' "${showroom_users[*]}"
printf '══════════════════════════════════════════════════\n'
