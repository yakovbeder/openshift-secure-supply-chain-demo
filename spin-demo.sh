#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# RHTAS Jenkins Demo — One-command cluster bootstrap (self-contained)
#
# This folder contains everything needed. No external dependencies on the
# parent repo — it ships its own components/, argocd/, config/, and app source.
#
# Deploys on OpenShift:
#   1. OpenShift GitOps (ArgoCD)
#   2. Gitea (GitOps manifests repo)
#   3. Push repo/ to Gitea → apply ApplicationSet
#   4. Wait for all components to sync and become healthy
#   5. Create GitLab project + push secure-app source
#   6. Health check + credentials summary
#
# Prerequisite: oc login https://api.<cluster>:6443 -u <user> -p '<pass>'
# Usage:        ./spin-demo.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="${SCRIPT_DIR}/repo"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
REPO_DIR="${WORK_DIR}/repo"
APP_DIR="${REPO_DIR}/apps-projects/secure-app"

# ── Constants ────────────────────────────────────────────────────────────────
GITEA_ORG="gitea"
GITEA_USER="admin"
GITEA_PASS="openshift"
GITEA_REPO="rhtas-demo"
ARGOCD_NS="openshift-gitops"

# ── Colors / logging ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Progress bar ─────────────────────────────────────────────────────────────
TOTAL_STEPS=8
CURRENT_STEP=0
DEMO_START_TIME=${SECONDS}

STEP_LABELS=(
    ""
    "Domain placeholders"
    "ArgoCD"
    "Gitea"
    "Push to Gitea + ApplicationSet"
    "ArgoCD applications"
    "Components health"
    "GitLab project"
    "Final status"
)

progress_bar() {
    local step=$1 cols=${COLUMNS:-80}
    local bar_width=$(( cols - 42 ))
    [ $bar_width -lt 20 ] && bar_width=20
    local filled=$(( bar_width * step / TOTAL_STEPS ))
    local empty=$(( bar_width - filled ))
    local elapsed=$(( SECONDS - DEMO_START_TIME ))
    local mins=$(( elapsed / 60 )) secs=$(( elapsed % 60 ))

    local bar_filled="" bar_empty=""
    for ((i=0; i<filled; i++)); do bar_filled+="█"; done
    for ((i=0; i<empty;  i++)); do bar_empty+="░"; done

    printf "\033[s\033[1;1H\033[2K"
    printf " ${BOLD}${CYAN}[%d/%d]${NC} ${GREEN}%s${DIM}%s${NC}  ${BOLD}%02d:%02d${NC}  %s" \
        "$step" "$TOTAL_STEPS" \
        "$bar_filled" "$bar_empty" \
        "$mins" "$secs" \
        "${STEP_LABELS[$step]:-}"
    printf "\033[u"
}

log_step() {
    CURRENT_STEP=$(echo "$1" | grep -oE '^Step [0-9]+' | grep -oE '[0-9]+' || echo "$CURRENT_STEP")
    progress_bar "$CURRENT_STEP"
    echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}\n"
}
log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()     { echo -e "${RED}[ERROR]${NC} $1"; }

spin_wait() {
    local timeout=$1 check_cmd=$2 msg=$3 interval=${4:-5}
    local elapsed=0 spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ $elapsed -lt $timeout ]; do
        if eval "$check_cmd" &>/dev/null; then
            printf "\r${GREEN}[OK]${NC} %s  \n" "$msg"
            progress_bar "$CURRENT_STEP"
            return 0
        fi
        local i=$(( (elapsed / interval) % 10 ))
        printf "\r${CYAN}[${spin:$i:1}]${NC} %s … %ds" "$msg" "$elapsed"
        progress_bar "$CURRENT_STEP"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    printf "\r${YELLOW}[WARN]${NC} %s — timeout after %ds\n" "$msg" "$timeout"
    progress_bar "$CURRENT_STEP"
    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# PREFLIGHT
# ═════════════════════════════════════════════════════════════════════════════
clear 2>/dev/null || true
echo ""
cat << 'BANNER'
  ╔════════════════════════════════════════════════════════════════╗
  ║   RHTAS Demo — Jenkins Supply-Chain (One Command)            ║
  ║                                                                ║
  ║   ArgoCD · Jenkins · GitLab · RHTAS · ACS · Sigstore · Quay  ║
  ╚════════════════════════════════════════════════════════════════╝

BANNER
progress_bar 0

if [ ! -d "${REPO_SRC}/components" ]; then
    log_err "repo/ directory not found at ${REPO_SRC}"
    log_err "Run this script from inside demo/jenkins/"
    exit 1
fi

for tool in oc git curl; do
    command -v "$tool" &>/dev/null || { log_err "$tool not found in PATH"; exit 1; }
done

if ! oc whoami &>/dev/null; then
    log_err "Not logged into OpenShift.  Run:"
    echo "  oc login https://api.<cluster>:6443 -u <user> -p '<password>'"
    exit 1
fi

log_ok "Logged in as $(oc whoami) on $(oc whoami --show-server)"

# ── Detect cluster domain ───────────────────────────────────────────────────
API_SERVER=$(oc whoami --show-server)
CLUSTER_NAME=$(echo "$API_SERVER" | sed -E 's|https://api\.([^:]+):.*|\1|')
CLUSTER_DOMAIN="apps.${CLUSTER_NAME}"
log_ok "Cluster domain: ${CLUSTER_DOMAIN}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1  Domain placeholder replacement inside repo/
# ═════════════════════════════════════════════════════════════════════════════
log_step "Step 1/8 — Replacing domain placeholders"

log_info "Copying repo/ → temp working directory"
cp -R "${REPO_SRC}/." "${REPO_DIR}"
rm -rf "${REPO_DIR}/.git"

replace_count=0

replace_in_repo() {
    local pattern=$1
    while IFS= read -r -d '' file; do
        if grep -q "$pattern" "$file" 2>/dev/null; then
            sed -i.bak "s|${pattern}|${CLUSTER_DOMAIN}|g" "$file"
            rm -f "${file}.bak"
            replace_count=$((replace_count + 1))
        fi
    done < <(find "${REPO_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sh' -o -name '*.json' \) -print0)
}

replace_in_repo '__CLUSTER_DOMAIN__'

log_ok "Replaced domains in ${replace_count} file(s)"

# Initialise working copy as a git repo so we can push to Gitea
cd "${REPO_DIR}"
git init -b main
git add -A
git commit -m "Jenkins demo: initial commit for ${CLUSTER_DOMAIN}" --allow-empty

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2  Install OpenShift GitOps (ArgoCD)
# ═════════════════════════════════════════════════════════════════════════════
log_step "Step 2/8 — ArgoCD"

if oc get deployment openshift-gitops-server -n "${ARGOCD_NS}" &>/dev/null; then
    log_ok "ArgoCD already installed"
else
    log_info "Installing OpenShift GitOps operator…"
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    spin_wait 300 "oc get deployment openshift-gitops-server -n ${ARGOCD_NS}" \
        "ArgoCD deployment" 10
    oc rollout status deployment/openshift-gitops-server -n "${ARGOCD_NS}" --timeout=300s
    log_ok "ArgoCD installed"
fi

oc adm policy add-cluster-role-to-user cluster-admin \
    system:serviceaccount:${ARGOCD_NS}:openshift-gitops-argocd-application-controller 2>/dev/null || true

oc patch configmap argocd-cm -n "${ARGOCD_NS}" --type merge -p '{
  "data": {
    "timeout.reconciliation": "30s",
    "resource.customizations": "PersistentVolumeClaim:\n  health.lua: |\n    hs = {}\n    if obj.status ~= nil then\n      if obj.status.phase ~= nil then\n        if obj.status.phase == \"Pending\" then\n          hs.status = \"Healthy\"\n          hs.message = obj.status.phase\n          return hs\n        end\n        if obj.status.phase == \"Bound\" then\n          hs.status = \"Healthy\"\n          hs.message = obj.status.phase\n          return hs\n        end\n      end\n    end\n    hs.status = \"Progressing\"\n    hs.message = \"Waiting for PVC\"\n    return hs\n"
  }
}' 2>/dev/null || true

oc patch argocd openshift-gitops -n "${ARGOCD_NS}" --type merge \
    -p '{"spec":{"kustomizeBuildOptions":"--enable-helm"}}' 2>/dev/null || \
oc patch configmap argocd-cm -n "${ARGOCD_NS}" --type merge \
    -p '{"data":{"kustomize.buildOptions":"--enable-helm"}}' 2>/dev/null || true

oc patch configmap argocd-cmd-params-cm -n "${ARGOCD_NS}" --type merge -p '{
  "data": {
    "controller.status.processors": "50",
    "controller.operation.processors": "25",
    "controller.repo.server.timeout.seconds": "120",
    "reposerver.parallelism.limit": "5"
  }
}' 2>/dev/null || true
oc patch configmap argocd-rbac-cm -n "${ARGOCD_NS}" --type merge -p '{
  "data": {
    "policy.csv": "g, system:cluster-admins, role:admin\ng, cluster-admins, role:admin\ng, admin, role:admin\n",
    "policy.default": "role:readonly",
    "scopes": "[groups, preferred_username]"
  }
}' 2>/dev/null || true
log_ok "ArgoCD tuned (30s poll, PVC health, 50/25 processors, RBAC, --enable-helm)"

if oc get validatingwebhookconfiguration namespace.operator.tekton.dev &>/dev/null 2>&1; then
    oc patch validatingwebhookconfiguration namespace.operator.tekton.dev \
        --type='json' -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]' 2>/dev/null || true
    log_ok "Patched stale Tekton webhook"
fi

ARGOCD_URL="https://$(oc get route openshift-gitops-server -n ${ARGOCD_NS} -o jsonpath='{.spec.host}' 2>/dev/null || echo 'pending')"
ARGOCD_PASS=$(oc get secret openshift-gitops-cluster -n ${ARGOCD_NS} -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d || echo "N/A")

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3  Deploy Gitea
# ═════════════════════════════════════════════════════════════════════════════
log_step "Step 3/8 — Gitea"

oc apply -f "${REPO_DIR}/components/gitea/namespace.yaml" 2>/dev/null || \
    oc create namespace gitea-system 2>/dev/null || true
oc apply -f "${REPO_DIR}/components/gitea/catalogsource.yaml" 2>/dev/null || true
oc apply -f "${REPO_DIR}/components/gitea/operatorgroup.yaml" 2>/dev/null || true
oc apply -f "${REPO_DIR}/components/gitea/subscription.yaml" 2>/dev/null || true

spin_wait 300 "oc get crd gitea.pfe.rhpds.com" "Gitea CRD" 5

oc apply -f "${REPO_DIR}/components/gitea/gitea-instance.yaml" 2>/dev/null || \
    oc apply -k "${REPO_DIR}/components/gitea" 2>/dev/null || true

spin_wait 300 \
    "[ \$(oc get pods -n gitea-system --no-headers 2>/dev/null | grep -c '1/1.*Running') -ge 2 ]" \
    "Gitea pods (2/2 ready)" 5

GITEA_URL="https://gitea.${CLUSTER_DOMAIN}"
spin_wait 300 \
    "curl -sk '${GITEA_URL}/api/v1/version' 2>/dev/null | grep -q '\"version\"'" \
    "Gitea API (JSON response)" 10
log_ok "Gitea ready at ${GITEA_URL}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4  Push repo/ to Gitea + apply ApplicationSet
# ═════════════════════════════════════════════════════════════════════════════
log_step "Step 4/8 — Push to Gitea + ApplicationSet"

gitea_api() {
    local method=$1 endpoint=$2 data=${3:-}
    local http_code
    for attempt in 1 2 3 4 5; do
        if [ -n "$data" ]; then
            http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
                -X "$method" "${GITEA_URL}/api/v1${endpoint}" \
                -u "${GITEA_USER}:${GITEA_PASS}" \
                -H "Content-Type: application/json" \
                -d "$data" 2>/dev/null)
        else
            http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
                -X "$method" "${GITEA_URL}/api/v1${endpoint}" \
                -u "${GITEA_USER}:${GITEA_PASS}" 2>/dev/null)
        fi
        case "$http_code" in
            2*|409|422) return 0 ;;  # 2xx success, 409/422 already exists
        esac
        log_warn "Gitea API ${endpoint} returned ${http_code} (attempt ${attempt}/5)"
        sleep $(( attempt * 5 ))
    done
    log_err "Gitea API ${endpoint} failed after 5 attempts"
    return 1
}

gitea_api POST "/orgs" "{\"username\":\"${GITEA_ORG}\",\"visibility\":\"public\"}"
log_ok "Gitea org '${GITEA_ORG}' ready"

gitea_api POST "/orgs/${GITEA_ORG}/repos" "{\"name\":\"${GITEA_REPO}\",\"private\":false,\"auto_init\":false}"
log_ok "Gitea repo '${GITEA_REPO}' ready"

cd "${REPO_DIR}"
git remote remove gitea 2>/dev/null || true
git remote add gitea "https://${GITEA_USER}:${GITEA_PASS}@gitea.${CLUSTER_DOMAIN}/${GITEA_ORG}/${GITEA_REPO}.git"

log_info "Pushing repo/ → Gitea main…"
push_ok=false
for attempt in 1 2 3 4 5; do
    if GIT_SSL_NO_VERIFY=true git push gitea main --force 2>&1 | tail -3; then
        push_ok=true
        break
    fi
    log_warn "Git push attempt ${attempt}/5 failed — retrying in ${attempt}0s…"
    sleep $(( attempt * 10 ))
done
if [ "$push_ok" = false ]; then
    log_err "Git push failed after 5 attempts"; exit 1
fi
log_ok "Repo pushed to Gitea"

curl -sk -X POST "${GITEA_URL}/api/v1/repos/${GITEA_ORG}/${GITEA_REPO}/hooks" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"${ARGOCD_URL}/api/webhook\",\"content_type\":\"json\",\"secret\":\"\"}}" 2>/dev/null || true

oc apply -f "${REPO_DIR}/argocd/applicationset.yaml"
log_ok "ApplicationSet applied"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5  Wait for ArgoCD applications to be created
# ═════════════════════════════════════════════════════════════════════════════
log_step "Step 5/8 — Wait for ArgoCD applications"

ENABLED_COUNT=$(grep -cE '^\s+-\s+\w' "${REPO_DIR}/config/enabled-components.yaml" 2>/dev/null || echo "0")
log_info "Expecting ~${ENABLED_COUNT} applications"

spin_wait 600 \
    "[ \$(oc get applications -n ${ARGOCD_NS} --no-headers 2>/dev/null | wc -l | tr -d ' ') -ge ${ENABLED_COUNT} ]" \
    "ArgoCD creating ${ENABLED_COUNT} applications" 10

log_info "Applications:"
oc get applications -n "${ARGOCD_NS}" --no-headers 2>/dev/null | awk '{printf "  %-30s Sync=%-12s Health=%s\n", $1, $2, $3}'

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6  Wait for critical components to become healthy
# ═════════════════════════════════════════════════════════════════════════════
log_step "Step 6/8 — Wait for components (Jenkins, GitLab, RHTAS, ACS, Quay)"

wait_app_healthy() {
    local app=$1 timeout=${2:-900}
    spin_wait "$timeout" \
        "oc get application ${app} -n ${ARGOCD_NS} -o jsonpath='{.status.health.status}' 2>/dev/null | grep -qE 'Healthy|Progressing'" \
        "${app}" 15 || true
}

wait_app_healthy jenkins 300
wait_app_healthy jenkins-app-namespaces 300
wait_app_healthy gitlab 900
wait_app_healthy rhtas-operator 600
wait_app_healthy rhtas-securesign 900
wait_app_healthy acs 600
wait_app_healthy sigstore-policy-controller 300
wait_app_healthy quay 600
wait_app_healthy sealed-secrets 120
wait_app_healthy mysql 120

log_info "Current application status:"
oc get applications -n "${ARGOCD_NS}" --no-headers 2>/dev/null | awk '{printf "  %-30s Sync=%-12s Health=%s\n", $1, $2, $3}'

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7  GitLab: create project + push secure-app
# ═════════════════════════════════════════════════════════════════════════════
log_step "Step 7/8 — GitLab project setup (secure-app)"

GITLAB_URL="https://gitlab.${CLUSTER_DOMAIN}"
GITLAB_USER_GL="root"

spin_wait 900 \
    "curl -sk '${GITLAB_URL}/-/health' 2>/dev/null | grep -q 'GitLab OK'" \
    "GitLab health endpoint" 15

# Wait for password-reset PostSync Job to complete (sets root password to 'openshift')
spin_wait 600 \
    "oc get pods -n gitlab-system -l job-name=gitlab-password-reset --no-headers 2>/dev/null | grep -q Completed" \
    "GitLab password-reset job" 15

GITLAB_PASSWORD="openshift"

# Retry OAuth token — GitLab may need a moment after password change
GL_TOKEN=""
for gl_attempt in 1 2 3 4 5; do
    GL_TOKEN=$(curl -sk --request POST "${GITLAB_URL}/oauth/token" \
        --data "grant_type=password" \
        --data "username=${GITLAB_USER_GL}" \
        --data "password=${GITLAB_PASSWORD}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
    [ -n "${GL_TOKEN}" ] && break
    log_warn "GitLab OAuth attempt ${gl_attempt}/5 failed — retrying in 10s"
    sleep 10
done

if [ -z "${GL_TOKEN}" ]; then
    log_warn "Cannot authenticate to GitLab API — skip project creation"
    log_warn "Create project manually: ${GITLAB_URL} → New project → 'secure-app'"
else
    log_info "GitLab OAuth token obtained"

    curl -sk -X POST "${GITLAB_URL}/api/v4/projects" \
        -H "Authorization: Bearer ${GL_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"name":"secure-app","visibility":"public","initialize_with_readme":false}' 2>/dev/null || true
    log_ok "GitLab project 'secure-app' created (or exists)"

    GL_PAT=$(curl -sk -X POST "${GITLAB_URL}/api/v4/users/1/personal_access_tokens" \
        -H "Authorization: Bearer ${GL_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"name":"demo-push","scopes":["api","write_repository"],"expires_at":"2027-01-01"}' 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

    if [ -z "${GL_PAT}" ]; then
        log_warn "Could not create GitLab PAT — will try password auth for git push"
        GL_AUTH="${GITLAB_USER_GL}:${GITLAB_PASSWORD}"
    else
        GL_AUTH="oauth2:${GL_PAT}"
    fi

    # Unprotect main branch to allow force-push on re-runs
    curl -sk -X DELETE "${GITLAB_URL}/api/v4/projects/root%2Fsecure-app/protected_branches/main" \
        -H "Authorization: Bearer ${GL_TOKEN}" 2>/dev/null || true

    if [ -d "${APP_DIR}" ]; then
        cd "${APP_DIR}"
        rm -rf .git
        git init -b main
        git add -A
        git commit -m "secure-app initial commit"

        git remote add gitlab "https://${GL_AUTH}@gitlab.${CLUSTER_DOMAIN}/root/secure-app.git"

        for attempt in 1 2 3; do
            if GIT_SSL_NO_VERIFY=true git push -u gitlab main --force 2>&1 | tail -3; then
                log_ok "secure-app pushed to GitLab"
                break
            fi
            [ "$attempt" -lt 3 ] && { log_warn "Push attempt ${attempt} failed, retrying…"; sleep 5; }
            [ "$attempt" -eq 3 ] && log_warn "Push failed — push manually: cd ${APP_DIR} && git push gitlab main"
        done
        cd "${SCRIPT_DIR}"
    else
        log_warn "${APP_DIR} not found — skip push"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8  Health check + credentials summary
# ═════════════════════════════════════════════════════════════════════════════
log_step "Step 8/8 — Final status"

echo -e "${BOLD}Component health:${NC}"
for ns_check in \
    "openshift-gitops:ArgoCD" \
    "gitea-system:Gitea" \
    "jenkins:Jenkins" \
    "gitlab-system:GitLab" \
    "trusted-artifact-signer:RHTAS" \
    "stackrox:ACS" \
    "cosign-system:PolicyController" \
    "quay:Quay"; do
    ns="${ns_check%%:*}"
    label="${ns_check##*:}"
    running=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -c Running 2>/dev/null || echo 0)
    if [ "$running" -ge 1 ]; then
        echo -e "  ${GREEN}[✓]${NC} ${label}: ${running} pod(s) running"
    else
        echo -e "  ${YELLOW}[!]${NC} ${label}: not ready (${running} running)"
    fi
done

NS_COUNT=$(oc get ns --no-headers 2>/dev/null | grep -cE "secure-app-dev|secure-app-staging|secure-app-prod" 2>/dev/null || echo 0)
echo -e "  App namespaces: ${NS_COUNT}/3"

progress_bar "$TOTAL_STEPS"

TOTAL_ELAPSED=$(( SECONDS - DEMO_START_TIME ))
TOTAL_MINS=$(( TOTAL_ELAPSED / 60 )); TOTAL_SECS=$(( TOTAL_ELAPSED % 60 ))

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║            DEMO READY  (${TOTAL_MINS}m ${TOTAL_SECS}s)                              ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Services:${NC}"
echo -e "  ArgoCD:   ${ARGOCD_URL}  (admin / ${ARGOCD_PASS})"
echo -e "  Gitea:    ${GITEA_URL}  (${GITEA_USER} / ${GITEA_PASS})"
echo -e "  Jenkins:  https://jenkins.${CLUSTER_DOMAIN}  (admin / openshift)"
echo -e "  Quay:     https://registry-quay-quay.${CLUSTER_DOMAIN}  (admin / openshift)"
echo -e "  ACS:      https://central-stackrox.${CLUSTER_DOMAIN}  (admin / openshift)"
echo -e "  GitLab:   ${GITLAB_URL}  (root / ${GITLAB_PASSWORD:-<see secret>})"
echo ""
echo -e "  ${BOLD}Next:${NC}"
echo -e "  1. Open Jenkins → New Multibranch Pipeline"
echo -e "     Repo: ${GITLAB_URL}/root/secure-app.git"
echo -e "     Script path: Jenkinsfile"
echo -e "  2. Run the pipeline on 'develop' or 'main' branch"
echo -e "  3. Watch Sigstore policy admission + Rekor transparency"
echo ""
echo -e "  ${BOLD}Monitor:${NC}"
echo -e "  watch 'oc get applications -n openshift-gitops'"
echo -e "  oc get pods -n secure-app-dev"
echo ""

cat > "${SCRIPT_DIR}/.credentials.txt" <<CREDS
RHTAS Demo Credentials — $(date)
Cluster: ${CLUSTER_DOMAIN}

ArgoCD:  ${ARGOCD_URL}  admin / ${ARGOCD_PASS}
Gitea:   ${GITEA_URL}  ${GITEA_USER} / ${GITEA_PASS}
Jenkins: https://jenkins.${CLUSTER_DOMAIN}  admin / openshift
Quay:    https://registry-quay-quay.${CLUSTER_DOMAIN}  admin / openshift
ACS:     https://central-stackrox.${CLUSTER_DOMAIN}  admin / openshift
GitLab:  ${GITLAB_URL}  root / ${GITLAB_PASSWORD:-<see secret>}
CREDS
log_ok "Credentials saved to demo/jenkins/.credentials.txt"
