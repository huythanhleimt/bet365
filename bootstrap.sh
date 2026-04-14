#!/bin/bash
# =============================================================
# IMT GitOps Bootstrap Script
# =============================================================
# Usage:
#   ADO_TOKEN=<personal-access-token> ./bootstrap.sh
#   ADO_TOKEN=<pat> VALUES_FILE=values.monorepo.yaml ./bootstrap.sh
#
# AUTO-DETECTS deployment mode from values.yaml:
#
#   SINGLE-SERVICE  — 'services' list absent or empty
#     Generates:  deployment.tpl.yaml (root)
#                 azure-pipelines.yaml (updated in-place)
#
#   MONOREPO        — 'services' list has ≥ 1 entry
#     Generates:  pipeline/azure-pipelines.<name>.yaml   (per service)
#                 pipeline/deployment.<name>.tpl.yaml     (per service)
#     Creates:    one ADO pipeline per service with path-based triggers
#
# Required tools: yq (≥4.x), curl, git, envsubst (gettext)
# Required env:   ADO_TOKEN — PAT with Repos (R/W) + Pipelines (R/W)
# =============================================================
set -euo pipefail

# ── Colors & logging ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
info()  { echo -e "${BLUE}[→]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
step()  { echo -e "\n${BOLD}${BLUE}══ $1${NC}"; }
svc()   { echo -e "${CYAN}  ◆ $1${NC}"; }
error() { echo -e "${RED}[✗] ERROR:${NC} $1" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────
VALUES_FILE="${VALUES_FILE:-values.yaml}"

# ─────────────────────────────────────────────────────────────
# 1. PREREQUISITES
# ─────────────────────────────────────────────────────────────
check_prerequisites() {
  step "Checking prerequisites"
  local missing=()
  command -v yq       &>/dev/null || missing+=("yq        → https://github.com/mikefarah/yq")
  command -v curl     &>/dev/null || missing+=("curl      → apt install curl")
  command -v git      &>/dev/null || missing+=("git       → apt install git")
  command -v envsubst &>/dev/null || missing+=("envsubst  → apt install gettext")
  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}Missing required tools:${NC}"
    for t in "${missing[@]}"; do echo "  • $t"; done
    exit 1
  fi
  [ -f "$VALUES_FILE" ] || error "${VALUES_FILE} not found. Run from the project root."
  log "All prerequisites satisfied."
}

# ─────────────────────────────────────────────────────────────
# 2. MODE DETECTION
# ─────────────────────────────────────────────────────────────
DEPLOY_MODE="single"
SERVICE_COUNT=0

detect_mode() {
  step "Detecting deployment mode"
  SERVICE_COUNT=$(yq -r '(.services // []) | length' "$VALUES_FILE")
  if [ "$SERVICE_COUNT" -gt 0 ]; then
    DEPLOY_MODE="monorepo"
  else
    DEPLOY_MODE="single"
    SERVICE_COUNT=1
  fi
  log "Mode: ${BOLD}${DEPLOY_MODE}${NC} | Services: ${SERVICE_COUNT}"
}

# ─────────────────────────────────────────────────────────────
# 3. CONFIG LOADING
# ─────────────────────────────────────────────────────────────

# Global config shared by both modes
load_global_config() {
  ADO_BASE_URL=$(yq -r '.ado.base_url'    "$VALUES_FILE")
  ADO_COLLECTION=$(yq -r '.ado.collection' "$VALUES_FILE")
  ADO_PROJECT=$(yq -r '.ado.project'    "$VALUES_FILE")
  REPO_NAME=$(yq -r '.repository.name'   "$VALUES_FILE")
  BRANCH=$(yq -r '.repository.branch' "$VALUES_FILE")
}

# Single-service mode — reads from ci/deploy sections
load_single_config() {
  step "Loading single-service configuration"
  load_global_config

  PIPELINE_NAME=$(yq -r '.pipeline.name' "$VALUES_FILE")

  IMAGE_NAME=$(yq -r '.ci.image_name'        "$VALUES_FILE")
  CONTAINER_NAME=$(yq -r '.ci.container_name'   "$VALUES_FILE")
  DOCKERFILE_PATH=$(yq -r '.ci.dockerfile_path'  "$VALUES_FILE")
  BUILD_CONTEXT=$(yq -r '.ci.build_context'     "$VALUES_FILE")
  ACR_LOGIN_SERVER=$(yq -r '.ci.acr_login_server' "$VALUES_FILE")

  NAMESPACE=$(yq -r '.deploy.namespace'       "$VALUES_FILE")
  REPLICAS=$(yq -r '.deploy.replicas'        "$VALUES_FILE")
  CONTAINER_PORT=$(yq -r '.deploy.container_port' "$VALUES_FILE")

  SERVICE_TYPE=$(yq -r '.deploy.service.type'      "$VALUES_FILE")
  NODE_PORT=$(yq -r '.deploy.service.node_port'  "$VALUES_FILE")

  CPU_REQUEST=$(yq -r '.deploy.resources.requests.cpu'    "$VALUES_FILE")
  MEM_REQUEST=$(yq -r '.deploy.resources.requests.memory' "$VALUES_FILE")
  CPU_LIMIT=$(yq -r '.deploy.resources.limits.cpu'      "$VALUES_FILE")
  MEM_LIMIT=$(yq -r '.deploy.resources.limits.memory'   "$VALUES_FILE")

  HC_ENABLED=$(yq -r '.deploy.health_check.enabled'               "$VALUES_FILE")
  HC_PATH=$(yq -r '.deploy.health_check.path'                  "$VALUES_FILE")
  HC_INITIAL_DELAY=$(yq -r '.deploy.health_check.initial_delay_seconds' "$VALUES_FILE")
  HC_PERIOD=$(yq -r '.deploy.health_check.period_seconds'            "$VALUES_FILE")
  HC_FAILURE=$(yq -r '.deploy.health_check.failure_threshold'         "$VALUES_FILE")

  INGRESS_ENABLED=$(yq -r '.deploy.ingress.enabled'    "$VALUES_FILE")
  INGRESS_HOST=$(yq -r '.deploy.ingress.host'       "$VALUES_FILE")
  INGRESS_PATH=$(yq -r '.deploy.ingress.path'       "$VALUES_FILE")
  INGRESS_TLS=$(yq -r '.deploy.ingress.tls'        "$VALUES_FILE")
  INGRESS_TLS_SECRET=$(yq -r '.deploy.ingress.tls_secret' "$VALUES_FILE")

  HPA_ENABLED=$(yq -r '.deploy.hpa.enabled'           "$VALUES_FILE")
  HPA_MIN=$(yq -r '.deploy.hpa.min_replicas'       "$VALUES_FILE")
  HPA_MAX=$(yq -r '.deploy.hpa.max_replicas'       "$VALUES_FILE")
  HPA_CPU=$(yq -r '.deploy.hpa.cpu_target_percent' "$VALUES_FILE")

  # Path used by generate_deployment_template to locate env vars in YAML
  ENV_YAML_PATH=".deploy.env"

  log "Config loaded → ${ACR_LOGIN_SERVER}/${IMAGE_NAME}  ns=${NAMESPACE}  port=${CONTAINER_PORT}"
}

# Monorepo mode — reads service[i] with fallback to defaults
load_service_config() {
  local i=$1
  local s=".services[$i]"           # service path
  local d=".defaults"               # defaults path

  SVC_NAME=$(yq -r "${s}.name" "$VALUES_FILE")
  SVC_PATH=$(yq -r "${s}.path" "$VALUES_FILE")

  ACR_LOGIN_SERVER=$(yq -r '.registry.acr_login_server' "$VALUES_FILE")
  local img_prefix
  img_prefix=$(yq -r '.registry.image_prefix' "$VALUES_FILE")

  NAMESPACE=$(yq -r '.cluster.namespace' "$VALUES_FILE")

  CONTAINER_NAME="$SVC_NAME"
  IMAGE_NAME="${img_prefix}/${SVC_NAME}"
  DOCKERFILE_PATH="${SVC_PATH}/Dockerfile"
  BUILD_CONTEXT="${SVC_PATH}"
  CONTAINER_PORT=$(yq -r "${s}.container_port" "$VALUES_FILE")

  # Scalars with fallback: service override → defaults → hardcoded fallback
  REPLICAS=$(yq -r      "${s}.replicas            // ${d}.replicas            // 1"          "$VALUES_FILE")
  SERVICE_TYPE=$(yq -r  "${s}.service.type        // ${d}.service.type        // \"NodePort\""   "$VALUES_FILE")
  NODE_PORT=$(yq -r     "${s}.node_port           // 30000"                                  "$VALUES_FILE")

  CPU_REQUEST=$(yq -r   "${s}.resources.requests.cpu    // ${d}.resources.requests.cpu    // \"100m\""  "$VALUES_FILE")
  MEM_REQUEST=$(yq -r   "${s}.resources.requests.memory // ${d}.resources.requests.memory // \"256Mi\"" "$VALUES_FILE")
  CPU_LIMIT=$(yq -r     "${s}.resources.limits.cpu      // ${d}.resources.limits.cpu      // \"1000m\"" "$VALUES_FILE")
  MEM_LIMIT=$(yq -r     "${s}.resources.limits.memory   // ${d}.resources.limits.memory   // \"1Gi\""   "$VALUES_FILE")

  HC_ENABLED=$(yq -r      "${s}.health_check.enabled               // ${d}.health_check.enabled               // true"  "$VALUES_FILE")
  HC_PATH=$(yq -r         "${s}.health_check.path                  // ${d}.health_check.path                  // \"/\""   "$VALUES_FILE")
  HC_INITIAL_DELAY=$(yq -r "${s}.health_check.initial_delay_seconds // ${d}.health_check.initial_delay_seconds // 15"   "$VALUES_FILE")
  HC_PERIOD=$(yq -r       "${s}.health_check.period_seconds         // ${d}.health_check.period_seconds         // 30"   "$VALUES_FILE")
  HC_FAILURE=$(yq -r      "${s}.health_check.failure_threshold      // ${d}.health_check.failure_threshold      // 3"    "$VALUES_FILE")

  INGRESS_ENABLED=$(yq -r    "${s}.ingress.enabled    // false" "$VALUES_FILE")
  INGRESS_HOST=$(yq -r       "${s}.ingress.host       // \"\""  "$VALUES_FILE")
  INGRESS_PATH=$(yq -r       "${s}.ingress.path       // \"/\"" "$VALUES_FILE")
  INGRESS_TLS=$(yq -r        "${s}.ingress.tls        // false" "$VALUES_FILE")
  INGRESS_TLS_SECRET=$(yq -r "${s}.ingress.tls_secret // \"\""  "$VALUES_FILE")

  HPA_ENABLED=$(yq -r "${s}.hpa.enabled            // false" "$VALUES_FILE")
  HPA_MIN=$(yq -r     "${s}.hpa.min_replicas       // 1"     "$VALUES_FILE")
  HPA_MAX=$(yq -r     "${s}.hpa.max_replicas       // 5"     "$VALUES_FILE")
  HPA_CPU=$(yq -r     "${s}.hpa.cpu_target_percent // 70"    "$VALUES_FILE")

  ENV_YAML_PATH="${s}.env"
}

# ─────────────────────────────────────────────────────────────
# 4. DEPLOYMENT TEMPLATE GENERATOR
#    Shared by both modes. Reads global vars set by load_*_config.
#    $1 = output file path
# ─────────────────────────────────────────────────────────────
generate_deployment_template() {
  local T="${1:-deployment.tpl.yaml}"
  info "  Generating ${T}..."

  # ---- Deployment ----
  # <<'BLOCK'  → all ${…} written literally (envsubst placeholders for CI)
  # <<BLOCK    → bash expands $VAR (bakes values.yaml data in at bootstrap time)
  # printf '…' → single-quoted format preserves literal ${…} for envsubst
  cat > "$T" <<'BLOCK'
# Auto-generated by bootstrap.sh from values.yaml.
# To update: edit values.yaml, then re-run ./bootstrap.sh
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CONTAINER_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${CONTAINER_NAME}
spec:
BLOCK
  printf '  replicas: %s\n' "$REPLICAS" >> "$T"
  cat >> "$T" <<'BLOCK'
  selector:
    matchLabels:
      app: ${CONTAINER_NAME}
  template:
    metadata:
      labels:
        app: ${CONTAINER_NAME}
    spec:
      imagePullSecrets:
        - name: registry-secret
      containers:
        - name: ${CONTAINER_NAME}
          image: ${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest
          imagePullPolicy: Always
          ports:
BLOCK
  printf '            - containerPort: %s\n' "$CONTAINER_PORT" >> "$T"

  # Env vars — read from values.yaml at bootstrap time (baked in)
  local env_count
  env_count=$(yq -r "(${ENV_YAML_PATH} // []) | length" "$VALUES_FILE")
  if [ "$env_count" -gt 0 ]; then
    printf '          env:\n' >> "$T"
    for j in $(seq 0 $((env_count - 1))); do
      local ev_name ev_val
      ev_name=$(yq -r "${ENV_YAML_PATH}[$j].name"  "$VALUES_FILE")
      ev_val=$(yq -r  "${ENV_YAML_PATH}[$j].value" "$VALUES_FILE")
      printf '            - name: %s\n              value: "%s"\n' "$ev_name" "$ev_val" >> "$T"
    done
  fi

  # Resources (baked in)
  printf '          resources:\n            requests:\n              cpu: "%s"\n              memory: "%s"\n            limits:\n              cpu: "%s"\n              memory: "%s"\n' \
    "$CPU_REQUEST" "$MEM_REQUEST" "$CPU_LIMIT" "$MEM_LIMIT" >> "$T"

  # Health check probes (baked in — path, port, intervals)
  if [ "$HC_ENABLED" = "true" ]; then
    printf '          livenessProbe:\n            httpGet:\n              path: %s\n              port: %s\n            initialDelaySeconds: %s\n            periodSeconds: %s\n            failureThreshold: %s\n' \
      "$HC_PATH" "$CONTAINER_PORT" "$HC_INITIAL_DELAY" "$HC_PERIOD" "$HC_FAILURE" >> "$T"
    printf '          readinessProbe:\n            httpGet:\n              path: %s\n              port: %s\n            initialDelaySeconds: %s\n            periodSeconds: %s\n            failureThreshold: %s\n' \
      "$HC_PATH" "$CONTAINER_PORT" "$HC_INITIAL_DELAY" "$HC_PERIOD" "$HC_FAILURE" >> "$T"
  fi

  cat >> "$T" <<'BLOCK'
      nodeSelector:
        kubernetes.io/arch: amd64
BLOCK

  # ---- Service ----
  cat >> "$T" <<'BLOCK'
---
apiVersion: v1
kind: Service
metadata:
  name: ${CONTAINER_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${CONTAINER_NAME}
spec:
BLOCK
  printf '  type: %s\n' "$SERVICE_TYPE" >> "$T"
  cat >> "$T" <<'BLOCK'
  selector:
    app: ${CONTAINER_NAME}
  ports:
    - protocol: TCP
BLOCK
  printf '      port: %s\n      targetPort: %s\n' "$CONTAINER_PORT" "$CONTAINER_PORT" >> "$T"
  [ "$SERVICE_TYPE" = "NodePort" ] && printf '      nodePort: %s\n' "$NODE_PORT" >> "$T"

  # ---- Ingress (optional) ----
  if [ "$INGRESS_ENABLED" = "true" ]; then
    cat >> "$T" <<'BLOCK'
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${CONTAINER_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${CONTAINER_NAME}
spec:
  rules:
BLOCK
    printf '    - host: %s\n' "$INGRESS_HOST" >> "$T"
    # ${CONTAINER_NAME} in single-quoted format → literal envsubst placeholder
    printf '      http:\n        paths:\n          - path: %s\n            pathType: Prefix\n            backend:\n              service:\n                name: ${CONTAINER_NAME}\n                port:\n                  number: %s\n' \
      "$INGRESS_PATH" "$CONTAINER_PORT" >> "$T"
    if [ "$INGRESS_TLS" = "true" ]; then
      printf '  tls:\n    - hosts:\n        - %s\n      secretName: %s\n' \
        "$INGRESS_HOST" "$INGRESS_TLS_SECRET" >> "$T"
    fi
  fi

  # ---- HPA (optional) ----
  if [ "$HPA_ENABLED" = "true" ]; then
    cat >> "$T" <<'BLOCK'
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${CONTAINER_NAME}
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${CONTAINER_NAME}
BLOCK
    printf '  minReplicas: %s\n  maxReplicas: %s\n' "$HPA_MIN" "$HPA_MAX" >> "$T"
    cat >> "$T" <<'BLOCK'
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
BLOCK
    printf '          averageUtilization: %s\n' "$HPA_CPU" >> "$T"
  fi
}

# ─────────────────────────────────────────────────────────────
# 5. PIPELINE YAML GENERATOR  (monorepo only)
#    Generates pipeline/azure-pipelines.<name>.yaml
#    Reads global vars: SVC_NAME SVC_PATH BRANCH IMAGE_NAME
#    CONTAINER_NAME DOCKERFILE_PATH BUILD_CONTEXT
#    ACR_LOGIN_SERVER NAMESPACE CONTAINER_PORT
# ─────────────────────────────────────────────────────────────
generate_service_pipeline_yaml() {
  local svc_name="$1"
  local out="pipeline/azure-pipelines.${svc_name}.yaml"
  local tpl="pipeline/deployment.${svc_name}.tpl.yaml"

  # In unquoted heredoc:
  #   ${BASH_VAR}   → bash expands  (baked in)
  #   \$(ado_var)   → $(ado_var) in output  (ADO pipeline expression)
  cat > "$out" <<HEREDOC
name: \$(Date:yyyyMMdd)\$(Rev:.r)

# ── Pipeline: ${svc_name} ─────────────────────────────────────
# Auto-generated by bootstrap.sh from values.yaml.
# To update: edit values.yaml, re-run ./bootstrap.sh

trigger:
  branches:
    include:
      - ${BRANCH}
  paths:
    include:
      - ${SVC_PATH}/**
      - ${tpl}

pool:
  name: 'AI Team'

# Auto-synced from values.yaml — do not edit manually.
variables:
  - name: imageName
    value: "${IMAGE_NAME}"
  - name: containerName
    value: "${CONTAINER_NAME}"
  - name: dockerfilePath
    value: "${DOCKERFILE_PATH}"
  - name: buildContext
    value: "${BUILD_CONTEXT}"
  - name: acrLoginServer
    value: "${ACR_LOGIN_SERVER}"
  - name: namespace
    value: "${NAMESPACE}"
  - name: containerPort
    value: "${CONTAINER_PORT}"

stages:
  # ── Build & Push ─────────────────────────────────────────────
  - stage: Build
    displayName: 'Build and Push — ${svc_name}'
    jobs:
      - job: BuildPush
        displayName: Build and Push Docker Image
        steps:
          - checkout: self

          - task: Docker@2
            displayName: Build Docker Image
            inputs:
              containerRegistry: dockerRegistryServiceConnection
              repository: \$(imageName)
              command: build
              Dockerfile: \$(dockerfilePath)
              buildContext: \$(buildContext)
              tags: latest

          - task: Docker@2
            displayName: Push Image to Registry
            inputs:
              containerRegistry: dockerRegistryServiceConnection
              repository: \$(imageName)
              command: push
              tags: latest

          - script: docker rmi \$(acrLoginServer)/\$(imageName):latest || true
            displayName: Clean Up Local Image

  # ── Deploy ───────────────────────────────────────────────────
  - stage: Deploy
    displayName: 'Deploy — ${svc_name}'
    dependsOn: Build
    jobs:
      - job: Deploy
        displayName: Apply Manifests to Cluster
        steps:
          - checkout: self

          - script: |
              echo "Rendering manifest for ${svc_name}..."
              envsubst < ${tpl} > deployment.yaml
              echo "=== deployment.yaml ==="
              cat deployment.yaml
            displayName: Render Deployment Manifest
            env:
              CONTAINER_NAME:   \$(containerName)
              IMAGE_NAME:       \$(imageName)
              ACR_LOGIN_SERVER: \$(acrLoginServer)
              NAMESPACE:        \$(namespace)
              CONTAINER_PORT:   \$(containerPort)

          - task: Kubernetes@1
            displayName: Apply Manifest
            inputs:
              connectionType: 'Kubernetes Service Connection'
              kubernetesServiceEndpoint: kubeServiceConnection
              namespace: \$(namespace)
              command: apply
              useConfigurationFile: true
              configuration: deployment.yaml

          - task: Kubernetes@1
            displayName: Rollout Restart
            inputs:
              connectionType: 'Kubernetes Service Connection'
              kubernetesServiceEndpoint: kubeServiceConnection
              namespace: \$(namespace)
              command: rollout
              arguments: restart deployment/\$(containerName)
HEREDOC
  log "  Generated: ${out}"
}

# ─────────────────────────────────────────────────────────────
# 6. PIPELINE YAML UPDATER  (single-service only)
#    Syncs variables block in azure-pipelines.yaml
# ─────────────────────────────────────────────────────────────
update_single_pipeline_yaml() {
  step "Updating azure-pipelines.yaml"

  yq e ".trigger.branches.include = [\"${BRANCH}\"]" -i azure-pipelines.yaml

  local tmp="/tmp/imt_vars_$$.yaml"
  cat > "$tmp" <<EOF
variables:
  - name: imageName
    value: "${IMAGE_NAME}"
  - name: containerName
    value: "${CONTAINER_NAME}"
  - name: dockerfilePath
    value: "${DOCKERFILE_PATH}"
  - name: buildContext
    value: "${BUILD_CONTEXT}"
  - name: acrLoginServer
    value: "${ACR_LOGIN_SERVER}"
  - name: namespace
    value: "${NAMESPACE}"
  - name: containerPort
    value: "${CONTAINER_PORT}"
EOF
  yq e ".variables = load(\"$tmp\").variables" -i azure-pipelines.yaml
  rm -f "$tmp"
  log "azure-pipelines.yaml updated."
}

# ─────────────────────────────────────────────────────────────
# 7. ADO AUTH
# ─────────────────────────────────────────────────────────────
setup_auth() {
  step "Setting up Azure DevOps authentication"
  [ -n "${ADO_TOKEN:-}" ] || error "ADO_TOKEN is not set.\nUsage: ADO_TOKEN=<pat> ./bootstrap.sh"

  ADO_PAT=$(printf '%s' "IMT-SOFT\\aiteam:${ADO_TOKEN}" | base64 -w 0)
  AUTH_HEADER="Authorization: Basic ${ADO_PAT}"
  ADO_API="${ADO_BASE_URL}/${ADO_COLLECTION}/${ADO_PROJECT}/_apis"
  log "Authentication configured."
}

# ─────────────────────────────────────────────────────────────
# 8. GET ADO PROJECT ID
# ─────────────────────────────────────────────────────────────
get_project_id() {
  step "Fetching ADO project ID"
  PROJECT_ID=$(curl -sf \
    -H "$AUTH_HEADER" \
    "${ADO_BASE_URL}/${ADO_COLLECTION}/_apis/projects/${ADO_PROJECT}?api-version=6.0" \
    | grep -oP '"id":"\K[^"]+' | head -n 1)
  [ -n "$PROJECT_ID" ] || error "Failed to fetch project ID.\nCheck: ADO_TOKEN permissions, base_url, collection, project name."
  log "Project ID: ${PROJECT_ID}"
}

# ─────────────────────────────────────────────────────────────
# 9. CREATE OR GET REPOSITORY
# ─────────────────────────────────────────────────────────────
setup_repository() {
  step "Setting up repository: ${REPO_NAME}"

  local resp
  resp=$(curl -s -X POST \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{\"name\":\"${REPO_NAME}\",\"project\":{\"id\":\"${PROJECT_ID}\"}}" \
    "${ADO_API}/git/repositories?api-version=6.0")

  REPO_ID=$(echo "$resp" | grep -oP '"id":"\K[^"]+' | head -n 1)

  if [ -z "$REPO_ID" ]; then
    warn "Repository may already exist. Fetching existing..."
    REPO_ID=$(curl -sf \
      -H "$AUTH_HEADER" \
      "${ADO_API}/git/repositories/${REPO_NAME}?api-version=6.0" \
      | grep -oP '"id":"\K[^"]+' | head -n 1)
  fi

  [ -n "$REPO_ID" ] || error "Cannot resolve repo ID for '${REPO_NAME}'.\nVerify name and ADO_TOKEN permissions."
  REPO_URL="${ADO_BASE_URL}/${ADO_COLLECTION}/${ADO_PROJECT}/_git/${REPO_NAME}"
  log "Repo ID  : ${REPO_ID}"
  log "Repo URL : ${REPO_URL}"
}

# ─────────────────────────────────────────────────────────────
# 10. PUSH CODE
# ─────────────────────────────────────────────────────────────
push_code() {
  step "Pushing code to remote"
  [ -d ".git" ] || git init
  git checkout -B "$BRANCH"
  git add .
  git commit -m "chore: initial commit from IMT GitOps template" 2>/dev/null \
    || warn "Nothing new to commit."
  git remote remove origin 2>/dev/null || true
  git remote add origin "$REPO_URL"
  git -c http.extraheader="$AUTH_HEADER" push -u origin "$BRANCH" --force
  log "Code pushed to ${REPO_URL}"
}

# ─────────────────────────────────────────────────────────────
# 11. CREATE ADO PIPELINE
#     $1 = YAML path inside repo
#     $2 = pipeline display name
# ─────────────────────────────────────────────────────────────
create_ado_pipeline() {
  local yaml_path="$1"
  local pipe_name="$2"

  local resp
  resp=$(curl -s -X POST \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${pipe_name}\",
      \"configuration\": {
        \"type\": \"yaml\",
        \"path\": \"${yaml_path}\",
        \"repository\": {
          \"id\": \"${REPO_ID}\",
          \"type\": \"azureReposGit\",
          \"name\": \"${REPO_NAME}\",
          \"defaultBranch\": \"refs/heads/${BRANCH}\"
        }
      }
    }" \
    "${ADO_API}/pipelines?api-version=7.0-preview.1")

  if echo "$resp" | grep -q '"id"'; then
    log "  Pipeline created: ${pipe_name}"
  else
    warn "  Pipeline '${pipe_name}' may already exist — skipping."
  fi
}

# ─────────────────────────────────────────────────────────────
# 12. FIRST DEPLOY TRIGGERS
# ─────────────────────────────────────────────────────────────
trigger_first_deploy_single() {
  step "Triggering first deploy"
  info "Waiting 3 minutes for pipeline to register in ADO..."
  sleep 180

  printf '\n' >> Dockerfile
  git add Dockerfile
  git commit -m "chore: trigger initial pipeline run"
  git -c http.extraheader="$AUTH_HEADER" push origin "$BRANCH"
  log "First deploy triggered."
}

trigger_first_deploy_monorepo() {
  step "Triggering first deploy for all services"
  info "Waiting 3 minutes for pipelines to register in ADO..."
  sleep 180

  # Touch each service's deployment template — these files are in every
  # service pipeline's path trigger, so each pipeline fires exactly once.
  for i in $(seq 0 $((SERVICE_COUNT - 1))); do
    local svc_name
    svc_name=$(yq -r ".services[$i].name" "$VALUES_FILE")
    printf '\n' >> "pipeline/deployment.${svc_name}.tpl.yaml"
    svc "Queued trigger for: ${svc_name}"
  done

  git add pipeline/
  git commit -m "chore: trigger initial pipeline runs for all services"
  git -c http.extraheader="$AUTH_HEADER" push origin "$BRANCH"
  log "First deploy triggered for all ${SERVICE_COUNT} services."
}

# ─────────────────────────────────────────────────────────────
# MAIN FLOWS
# ─────────────────────────────────────────────────────────────
run_single() {
  load_single_config
  generate_deployment_template "deployment.tpl.yaml"
  update_single_pipeline_yaml
  setup_auth
  get_project_id
  setup_repository
  push_code
  step "Creating pipeline"
  create_ado_pipeline "azure-pipelines.yaml" "$PIPELINE_NAME"
  trigger_first_deploy_single
}

run_monorepo() {
  step "Loading monorepo configuration"
  load_global_config

  local acr namespace img_prefix
  acr=$(yq -r '.registry.acr_login_server' "$VALUES_FILE")
  namespace=$(yq -r '.cluster.namespace'   "$VALUES_FILE")
  img_prefix=$(yq -r '.registry.image_prefix' "$VALUES_FILE")
  info "Registry  : ${acr}"
  info "Namespace : ${namespace}"
  info "Services  : $(yq -r '[.services[].name] | join(", ")' "$VALUES_FILE")"

  mkdir -p pipeline

  # Generate per-service templates and pipeline YAMLs
  step "Generating per-service files"
  for i in $(seq 0 $((SERVICE_COUNT - 1))); do
    load_service_config "$i"
    svc "${SVC_NAME}  (${SVC_PATH}  port=${CONTAINER_PORT})"
    generate_deployment_template "pipeline/deployment.${SVC_NAME}.tpl.yaml"
    generate_service_pipeline_yaml "$SVC_NAME"
  done

  setup_auth
  get_project_id
  setup_repository
  push_code

  # Create one ADO pipeline per service
  step "Creating ADO pipelines"
  for i in $(seq 0 $((SERVICE_COUNT - 1))); do
    local svc_name
    svc_name=$(yq -r ".services[$i].name" "$VALUES_FILE")
    create_ado_pipeline \
      "pipeline/azure-pipelines.${svc_name}.yaml" \
      "${svc_name}-pipeline"
  done

  trigger_first_deploy_monorepo
}

# ─────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────
main() {
  echo -e "\n${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║       IMT GitOps Bootstrap               ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}\n"

  check_prerequisites
  detect_mode

  if [ "$DEPLOY_MODE" = "monorepo" ]; then
    run_monorepo
  else
    run_single
  fi

  echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║   Bootstrap complete!                    ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo -e "  Repo     : ${REPO_URL}"
  echo -e "  Pipelines: ${ADO_BASE_URL}/${ADO_COLLECTION}/${ADO_PROJECT}/_build"
  echo ""
}

main "$@"
