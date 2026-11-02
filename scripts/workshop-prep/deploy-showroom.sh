#!/usr/bin/env bash
###############################################################################
# deploy-showroom.sh
#
# Deploy N workshop guides as a merged Antora Showroom on OpenShift.
# Follows the showroom-editor multi-content pattern (clone → build → content)
# but requires no Helm, Docker build, or separate application.
#
# Multi-workshop mode (recommended):
#   export SITE_TITLE="RHOAI Hands-on Workshop"
#   export WORKSHOPS="
#   basic-inference|https://github.com/org/repo1.git|main|content|Basic Inference
#   agentops|https://github.com/org/repo2.git|main|content|AgentOps Workshop
#   "
#   bash deploy-showroom.sh
#
# Single-workshop mode (backward compatible):
#   export GIT_URL='https://github.com/org/workshop.git'
#   export GIT_REF='main'
#   export CONTENT_PATH='content'
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
# Optional environment variables:
#   SITE_TITLE       Site title (default: "Workshop")
#   SHOWROOM_NS      Force a specific namespace (default: auto-generated)
#   EXTRA_TABS       Additional nookbag tabs, pipe-delimited:
#                      name|url|external  (one per line)
#
# Requirements: bash, oc, sha256sum (or shasum), mktemp, date, tr.
# All build logic is in ConfigMap-embedded scripts — no local Helm, Docker,
# Python, Git, or container engine needed. The quay.io/rhpds images (git-cloner,
# antora, showroom-content) are used unchanged; every customization goes through
# ConfigMap files so small tweaks never require an image rebuild.
###############################################################################
set -euo pipefail

showroom_fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# sha256sum or shasum (macOS)
if command -v sha256sum >/dev/null 2>&1; then
  _sha256() { sha256sum; }
elif command -v shasum >/dev/null 2>&1; then
  _sha256() { shasum -a 256; }
else
  showroom_fail "Required command missing: sha256sum (or shasum)"
fi

for _cmd in oc tr mktemp date; do
  command -v "$_cmd" >/dev/null 2>&1 || showroom_fail "Required command missing: $_cmd"
done

###############################################################################
# 1. Parse inputs
###############################################################################
declare -a ws_names=() ws_urls=() ws_refs=() ws_paths=() ws_titles=()
ws_count=0

if [[ -n "${WORKSHOPS:-}" ]]; then
  # ── Multi-workshop mode ──
  while IFS= read -r _line; do
    _line="${_line%%#*}"           # strip comments
    _line="$(echo "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$_line" ]] && continue

    IFS='|' read -r _name _url _ref _path _title <<< "$_line"
    _name="$(echo "$_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _url="$(echo "$_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _ref="$(echo "$_ref" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _path="$(echo "$_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _title="$(echo "${_title:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Validate name (Antora component name / URL path)
    [[ "$_name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
      showroom_fail "Workshop name must be lowercase alphanumeric with hyphens: '$_name'"
    [[ "$_name" != "home" ]] || showroom_fail "Workshop name 'home' is reserved."

    # Validate URL
    [[ "$_url" =~ ^https://[^/@[:space:]]+/[^[:space:]?#]+$ ]] || \
      showroom_fail "Workshop '$_name': git_url must be HTTPS without credentials: '$_url'"

    # Validate ref
    [[ "$_ref" != -* && ! "$_ref" =~ [[:space:]] ]] || \
      showroom_fail "Workshop '$_name': git_ref is invalid: '$_ref'"

    # Validate content_path
    [[ "$_path" =~ ^[A-Za-z0-9._/-]+$ && "$_path" != /* && ! "$_path" =~ (^|/)\.\.(/|$) ]] || \
      showroom_fail "Workshop '$_name': content_path must be relative without ..: '$_path'"

    # Check for duplicates
    for _existing in "${ws_names[@]+"${ws_names[@]}"}"; do
      [[ "$_existing" != "$_name" ]] || showroom_fail "Duplicate workshop name: '$_name'"
    done

    ws_names+=("$_name")
    ws_urls+=("$_url")
    ws_refs+=("$_ref")
    ws_paths+=("$_path")
    ws_titles+=("${_title:-$_name}")
    ws_count=$((ws_count + 1))
  done <<< "$WORKSHOPS"

  [[ $ws_count -gt 0 ]] || showroom_fail "WORKSHOPS is set but contains no valid entries."

elif [[ -n "${GIT_URL:-}" ]]; then
  # ── Single-workshop backward-compatible mode ──
  : "${GIT_REF:?Set GIT_REF to a branch, tag, or commit}"
  : "${CONTENT_PATH:?Set CONTENT_PATH to the directory containing antora.yml}"
  [[ "$GIT_URL" =~ ^https://[^/@[:space:]]+/[^[:space:]?#]+$ ]] || \
    showroom_fail 'GIT_URL must be an HTTPS Git URL without embedded credentials.'
  [[ "$GIT_REF" != -* && ! "$GIT_REF" =~ [[:space:]] ]] || \
    showroom_fail 'GIT_REF must not start with a dash or contain whitespace.'
  [[ "$CONTENT_PATH" =~ ^[A-Za-z0-9._/-]+$ && "$CONTENT_PATH" != /* && ! "$CONTENT_PATH" =~ (^|/)\.\.(/|$) ]] || \
    showroom_fail 'CONTENT_PATH must be a relative directory without .. segments.'

  ws_names+=("workshop")
  ws_urls+=("$GIT_URL")
  ws_refs+=("$GIT_REF")
  ws_paths+=("$CONTENT_PATH")
  ws_titles+=("Workshop")
  ws_count=1
else
  showroom_fail 'Set WORKSHOPS (multi-workshop) or GIT_URL (single workshop). See script header for usage.'
fi

SITE_TITLE="${SITE_TITLE:-Workshop}"

printf 'Showroom: "%s" (%d workshop(s))\n' "$SITE_TITLE" "$ws_count"
for _i in $(seq 0 $((ws_count - 1))); do
  printf '  %d. %-24s %s @ %s (%s)\n' "$((_i+1))" "${ws_names[$_i]}" "${ws_urls[$_i]}" "${ws_refs[$_i]}" "${ws_paths[$_i]}"
done
echo ""

###############################################################################
# 2. Cluster information
###############################################################################
showroom_user="$(oc whoami 2>/dev/null)" || showroom_fail 'Log in with oc login first.'
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

###############################################################################
# 3. Namespace
###############################################################################
if [[ -n "${SHOWROOM_NS:-}" ]]; then
  showroom_ns="$SHOWROOM_NS"
elif [[ $ws_count -eq 1 && -n "${GIT_URL:-}" ]]; then
  # Single-workshop backward-compatible namespace naming:
  # showroom-<slug-from-git-url>-<hash-of-url+path>
  _slug="${GIT_URL%/}"; _slug="${_slug##*/}"; _slug="${_slug%.git}"
  _slug="$(printf '%s' "$_slug" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
  _slug="${_slug:0:28}"; _slug="${_slug:-workshop}"
  _hash="$(printf '%s\n%s' "$GIT_URL" "$CONTENT_PATH" | _sha256)"
  _hash="${_hash:0:8}"
  showroom_ns="showroom-${_slug}-${_hash}"
else
  # Multi-workshop namespace: showroom-<slug-from-title>-<hash-of-workshops>
  _hash_input=""
  for _i in $(seq 0 $((ws_count - 1))); do
    _hash_input+="${ws_names[$_i]}|${ws_urls[$_i]}|${ws_paths[$_i]}"$'\n'
  done
  _hash="$(printf '%s' "$_hash_input" | _sha256)"
  _hash="${_hash:0:8}"

  _slug="$(printf '%s' "$SITE_TITLE" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
  _slug="${_slug:0:28}"
  _slug="${_slug:-workshop}"
  showroom_ns="showroom-${_slug}-${_hash}"
fi

showroom_host="showroom-${showroom_ns}.${showroom_domain}"
showroom_url="https://${showroom_host}"
showroom_run="$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
showroom_tmp="$(mktemp -d)"
trap 'rm -rf -- "$showroom_tmp"' EXIT

printf 'Namespace : %s\nURL       : %s\n\n' "$showroom_ns" "$showroom_url"

# Create or verify namespace ownership
_existing="$(oc get namespace "$showroom_ns" --ignore-not-found -o jsonpath='{.metadata.name}')"
if [[ -n "$_existing" ]]; then
  _owner="$(oc get namespace "$showroom_ns" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
  [[ "$_owner" == showroom-bootstrap ]] || \
    showroom_fail "Namespace $showroom_ns exists and is not managed by this script."
else
  oc create namespace "$showroom_ns"
  oc label namespace "$showroom_ns" app.kubernetes.io/managed-by=showroom-bootstrap
fi

###############################################################################
# 4. Generate ConfigMap files
###############################################################################
printf 'Generating ConfigMap files...\n'

# Whether to generate a home landing page (only for multi-workshop)
_use_home=false
[[ $ws_count -gt 1 ]] && _use_home=true

# ── 4a. modules.txt ──
# Format: key url ref path  (read by clone.sh)
: > "$showroom_tmp/modules.txt"
for _i in $(seq 0 $((ws_count - 1))); do
  printf '%s %s %s %s\n' "${ws_names[$_i]}" "${ws_urls[$_i]}" "${ws_refs[$_i]}" "${ws_paths[$_i]}" \
    >> "$showroom_tmp/modules.txt"
done

# ── 4b. attrs-<name>.yml ──
# Common Antora attributes injected into each workshop's antora.yml by build.sh.
# These are YAML files loaded by yq: .asciidoc.attributes *= load("attrs-<key>.yml")
for _i in $(seq 0 $((ws_count - 1))); do
  cat > "$showroom_tmp/attrs-${ws_names[$_i]}.yml" <<ATTRS_EOF
user: "your-username"
username: "your-username"
guid: "your-username"
password: "Use the credentials provided by your instructor"
openshift_cluster_ingress_domain: "${showroom_domain}"
openshift_api_url: "${showroom_api}"
openshift_api_server_url: "${showroom_api}"
openshift_cluster_console_url: "${showroom_console}"
page-openshift_cluster_console_url: "${showroom_console}"
login_command: "oc login -u <your-username> ${showroom_api}"
ATTRS_EOF
  if [[ -n "$showroom_ai_url" ]]; then
    cat >> "$showroom_tmp/attrs-${ws_names[$_i]}.yml" <<RHOAI_ATTRS
rhoai_dashboard_url: "${showroom_ai_url}"
page-rhoai_dashboard_url: "${showroom_ai_url}"
RHOAI_ATTRS
  fi
done

# ── 4c. Home component (multi-workshop only) ──
if [[ "$_use_home" == true ]]; then
  cat > "$showroom_tmp/home-antora.yml" <<'HOME_ANTORA'
name: home
version: main
nav:
  - modules/ROOT/nav.adoc
HOME_ANTORA

  # home-index.adoc — landing page listing all workshops
  # Use HOME_INDEX_FILE to supply a custom .adoc; otherwise auto-generate.
  if [[ -n "${HOME_INDEX_FILE:-}" && -f "$HOME_INDEX_FILE" ]]; then
    cp "$HOME_INDEX_FILE" "$showroom_tmp/home-index.adoc"
    printf 'Using custom home page: %s\n' "$HOME_INDEX_FILE"
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

  # home-nav.adoc — left sidebar navigation
  {
    printf '* xref:index.adoc[Workshop Home]\n'
    for _i in $(seq 0 $((ws_count - 1))); do
      printf '* xref:%s::index.adoc[%s]\n' "${ws_names[$_i]}" "${ws_titles[$_i]}"
    done
  } > "$showroom_tmp/home-nav.adoc"
fi

# ── 4d. site.yml — Antora playbook ──
{
  cat <<SITE_HEAD
site:
  title: "${SITE_TITLE}"
  url: "${showroom_url}"
SITE_HEAD

  if [[ "$_use_home" == true ]]; then
    printf '  start_page: home::index.adoc\n'
  else
    printf '  start_page: %s::index.adoc\n' "${ws_names[0]}"
  fi

  printf 'content:\n  sources:\n'

  # Home component source (from /showroom/repo which gets git-init'd)
  if [[ "$_use_home" == true ]]; then
    cat <<'HOME_SRC'
    - url: /showroom/repo
      branches: HEAD
      start_path: home
HOME_SRC
  fi

  # Workshop sources (each is a separate git clone)
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
} > "$showroom_tmp/site.yml"

# ── 4e. clone.sh — init container 1 ──
cat > "$showroom_tmp/clone.sh" <<'CLONE_SCRIPT'
#!/bin/sh
# init container 1: clone all workshop repos + prepare home component.
# Follows the showroom-editor pattern: N repos → /showroom/sources/<key>/
# Home component + site.yml → /showroom/repo/ (git-init'd for Antora).
set -eu
export HOME=/tmp
git config --global --add safe.directory '*'

SOURCES=/showroom/sources
REPO=/showroom/repo

mkdir -p "$SOURCES" "$REPO"

# Clone each workshop repository
while read -r key url ref path; do
  [ -n "$key" ] || continue
  echo "[clone] $key <- $url ($ref)"
  rm -rf "${SOURCES:?}/$key"
  git clone --quiet --depth 1 --branch "$ref" "$url" "$SOURCES/$key"
  # Verify antora.yml exists
  if [ ! -f "$SOURCES/$key/$path/antora.yml" ]; then
    echo "[clone] ERROR: $key — $path/antora.yml not found" >&2
    exit 1
  fi
done < /config/modules.txt

# Prepare home component (if present in ConfigMap)
if [ -f /config/home-antora.yml ]; then
  echo "[clone] Generating home component..."
  mkdir -p "$REPO/home/modules/ROOT/pages"
  cp /config/home-antora.yml "$REPO/home/antora.yml"
  cp /config/home-index.adoc "$REPO/home/modules/ROOT/pages/index.adoc"
  cp /config/home-nav.adoc   "$REPO/home/modules/ROOT/nav.adoc"
fi

# Copy site playbook
cp /config/site.yml "$REPO/site.yml"

# Antora requires local content sources to be git repos
cd "$REPO"
rm -rf .git
git init --quiet
git add -A
git -c user.name=showroom -c user.email=showroom@localhost commit --quiet -m "showroom"

echo "[clone] All content ready."
CLONE_SCRIPT

# ── 4f. build.sh — init container 2 ──
cat > "$showroom_tmp/build.sh" <<'BUILD_SCRIPT'
#!/bin/bash
# init container 2: normalize antora.yml per workshop, inject attributes, build.
# Each workshop's component name is replaced with the key from modules.txt
# to prevent collisions when multiple repos use the same Antora component name.
set -euo pipefail

SOURCES=/showroom/sources
REPO=/showroom/repo

# Normalize each workshop's antora.yml
while read -r key url ref path; do
  [ -n "$key" ] || continue
  descriptor="$SOURCES/$key/$path/antora.yml"
  if [ ! -f "$descriptor" ]; then
    echo "[build] ERROR: $key — $path/antora.yml not found" >&2
    exit 1
  fi
  echo "[build] $key: rename component, inject attributes from attrs-$key.yml"
  yq -i ".name = \"$key\" | .version = \"main\" | .asciidoc.attributes *= load(\"/config/attrs-$key.yml\")" "$descriptor"
done < /config/modules.txt

# Build the merged Antora site
echo "[build] Running Antora..."
antora --stacktrace "$REPO/site.yml"

# Verify output
if [ -d /showroom/www ]; then
  _page_count="$(find /showroom/www -name '*.html' | wc -l)"
  echo "[build] Done — $_page_count HTML pages generated."
else
  echo "[build] ERROR: /showroom/www not created" >&2
  exit 1
fi
BUILD_SCRIPT

# ── 4g. traefik proxy configuration ──
# Traefik acts as the pod entrypoint (port 8080), routing:
#   /                  → content container (port 8000)
#   /proxy/console/    → OpenShift Console (header stripping for inline iframe)
#   /proxy/dashboard/  → RHOAI Dashboard (header stripping for inline iframe)
# This follows the showroom-deployer pattern (quay.io/rhpds/traefik).

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

# ── 4h. ui-config.yml — nookbag UI configuration ──
# Tabs point to local proxy paths for inline iframe rendering.
# If inline doesn't work (OAuth redirect issues), change to external: true
# with the direct URL.
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

  # Default tabs — inline via traefik proxy
  if [[ -n "$showroom_ai_url" ]]; then
    printf '  - name: OpenShift AI Dashboard\n'
    printf '    url: "/proxy/dashboard/"\n'
  fi
  printf '  - name: OpenShift Console\n'
  printf '    url: "/proxy/console/"\n'

  # Extra tabs from EXTRA_TABS env var
  if [[ -n "${EXTRA_TABS:-}" ]]; then
    while IFS= read -r _tab_line; do
      _tab_line="$(echo "$_tab_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$_tab_line" || "$_tab_line" == \#* ]] && continue
      IFS='|' read -r _tab_name _tab_url _tab_ext <<< "$_tab_line"
      _tab_name="$(echo "$_tab_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      _tab_url="$(echo "$_tab_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      _tab_ext="$(echo "${_tab_ext:-true}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      printf '  - name: %s\n' "$_tab_name"
      printf '    url: "%s"\n' "$_tab_url"
      [[ "$_tab_ext" == "true" ]] && printf '    external: true\n'
    done <<< "$EXTRA_TABS"
  fi
} > "$showroom_tmp/ui-config.yml"

###############################################################################
# 5. Create ConfigMap
###############################################################################
printf 'Applying ConfigMap...\n'

_cm_args=(showroom-config -n "$showroom_ns" --dry-run=client -o yaml)
_cm_args+=(--from-file=modules.txt="$showroom_tmp/modules.txt")
_cm_args+=(--from-file=clone.sh="$showroom_tmp/clone.sh")
_cm_args+=(--from-file=build.sh="$showroom_tmp/build.sh")
_cm_args+=(--from-file=site.yml="$showroom_tmp/site.yml")
_cm_args+=(--from-file=ui-config.yml="$showroom_tmp/ui-config.yml")
_cm_args+=(--from-file=traefik-static.yml="$showroom_tmp/traefik-static.yml")
_cm_args+=(--from-file=traefik-dynamic.yml="$showroom_tmp/traefik-dynamic.yml")

if [[ "$_use_home" == true ]]; then
  _cm_args+=(--from-file=home-antora.yml="$showroom_tmp/home-antora.yml")
  _cm_args+=(--from-file=home-index.adoc="$showroom_tmp/home-index.adoc")
  _cm_args+=(--from-file=home-nav.adoc="$showroom_tmp/home-nav.adoc")
fi

for _i in $(seq 0 $((ws_count - 1))); do
  _cm_args+=(--from-file="attrs-${ws_names[$_i]}.yml=$showroom_tmp/attrs-${ws_names[$_i]}.yml")
done

oc create configmap "${_cm_args[@]}" | oc apply -f -

###############################################################################
# 6. Deployment + Service + Route
###############################################################################
printf '\nApplying workloads...\n'

cat > "$showroom_tmp/workload.yaml" <<WORKLOAD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: showroom
  namespace: ${showroom_ns}
  labels: {app.kubernetes.io/managed-by: showroom-bootstrap}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app.kubernetes.io/name: showroom}
  template:
    metadata:
      labels: {app.kubernetes.io/name: showroom}
      annotations: {showroom-bootstrap/run: "${showroom_run}"}
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
        # Traefik reverse proxy — pod entrypoint (port 8080)
        # Routes: / → content, /proxy/console/ → Console, /proxy/dashboard/ → Dashboard
        # Strips X-Frame-Options so Console/Dashboard render in nookbag iframes
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
        # Showroom content — serves the built Antora HTML
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
  namespace: ${showroom_ns}
spec:
  selector: {app.kubernetes.io/name: showroom}
  ports: [{name: http, port: 8080, targetPort: web}]
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: showroom
  namespace: ${showroom_ns}
  annotations:
    haproxy.router.openshift.io/timeout: 1h
    haproxy.router.openshift.io/timeout-tunnel: 1h
spec:
  host: "${showroom_host}"
  to: {kind: Service, name: showroom}
  port: {targetPort: http}
  tls: {termination: edge, insecureEdgeTerminationPolicy: Redirect}
WORKLOAD

oc apply -f "$showroom_tmp/workload.yaml"

###############################################################################
# 7. Wait for rollout
###############################################################################
printf '\nWaiting for Showroom deployment (up to 10 min)...\n'
if ! oc rollout status deployment/showroom -n "$showroom_ns" --timeout=600s; then
  printf '\nDeployment did not become ready. Inspect:\n' >&2
  printf '  oc get pods -n %s\n' "$showroom_ns" >&2
  printf '  oc logs -n %s deployment/showroom -c clone\n' "$showroom_ns" >&2
  printf '  oc logs -n %s deployment/showroom -c build\n' "$showroom_ns" >&2
  printf '  oc logs -n %s deployment/showroom -c proxy\n' "$showroom_ns" >&2
  printf '  oc logs -n %s deployment/showroom -c content\n' "$showroom_ns" >&2
  exit 1
fi

###############################################################################
# 8. Summary
###############################################################################
_actual_host="$(oc get route showroom -n "$showroom_ns" -o jsonpath='{.spec.host}')"
printf '\n'
printf '══════════════════════════════════════════════════\n'
printf ' Showroom is ready!\n'
printf '══════════════════════════════════════════════════\n'
printf '\n'
printf '  URL       : https://%s\n' "$_actual_host"
printf '  Namespace : %s\n' "$showroom_ns"
printf '  Workshops : %d\n' "$ws_count"
for _i in $(seq 0 $((ws_count - 1))); do
  printf '    %d. %s\n' "$((_i+1))" "${ws_titles[$_i]}"
done
printf '\n'
printf '  Update    : re-run this script (idempotent)\n'
printf '  Rebuild   : oc rollout restart deployment/showroom -n %s\n' "$showroom_ns"
printf '  Logs      : oc logs -n %s deployment/showroom -c clone\n' "$showroom_ns"
printf '              oc logs -n %s deployment/showroom -c build\n' "$showroom_ns"
printf '              oc logs -n %s deployment/showroom -c proxy\n' "$showroom_ns"
printf '  Delete    : oc delete namespace %s\n' "$showroom_ns"
printf '══════════════════════════════════════════════════\n'
