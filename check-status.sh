#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# RHTAS Demo - Status Check Script
# ═══════════════════════════════════════════════════════════════════════════════
#
# Quick check of all demo components status
# Run this before starting the demo to ensure everything is ready
#
# Usage: ./scripts/check-status.sh
#
# ═══════════════════════════════════════════════════════════════════════════════

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  RHTAS Demo - Component Status Check${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Check login
if ! oc whoami &>/dev/null; then
    echo -e "${RED}[✗] Not logged into OpenShift${NC}"
    exit 1
fi

# Get cluster domain
CLUSTER_DOMAIN=$(oc whoami --show-server | sed -E 's|https://api\.([^:]+):.*|apps.\1|')
echo -e "${BLUE}Cluster:${NC} ${CLUSTER_DOMAIN}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# FOUNDATIONS (should be ready BEFORE demo)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}FOUNDATIONS (Pre-Demo Requirements)${NC}"
echo "─────────────────────────────────────────────────────────────────────────────"

# ArgoCD
ARGOCD_PODS=$(oc get pods -n openshift-gitops --no-headers 2>/dev/null | grep -c "Running" || echo "0")
if [ "$ARGOCD_PODS" -ge 5 ]; then
    echo -e "  ${GREEN}[✓]${NC} ArgoCD: ${ARGOCD_PODS} pods running"
else
    echo -e "  ${YELLOW}[!]${NC} ArgoCD: Only ${ARGOCD_PODS} pods running (need 5+)"
fi

# GitLab Operator
GITLAB_OP=$(oc get csv -n gitlab-system --no-headers 2>/dev/null | grep -i gitlab-operator | grep -c "Succeeded" 2>/dev/null || echo "0")
GITLAB_OP=$(echo "$GITLAB_OP" | tr -d '\n')
if [ "$GITLAB_OP" -ge 1 ]; then
    echo -e "  ${GREEN}[✓]${NC} GitLab Operator: Installed"
else
    echo -e "  ${RED}[✗]${NC} GitLab Operator: Not installed"
fi

# GitLab Instance
GITLAB_PODS=$(oc get pods -n gitlab-system --no-headers 2>/dev/null | grep -v "Completed\|Error\|Init" | grep -c "Running" 2>/dev/null || echo "0")
GITLAB_PODS=$(echo "$GITLAB_PODS" | tr -d '\n')
GITLAB_WS=$(oc get pods -n gitlab-system -l app=webservice --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || echo "0")
GITLAB_WS=$(echo "$GITLAB_WS" | tr -d '\n')
if [ "$GITLAB_WS" -ge 1 ]; then
    echo -e "  ${GREEN}[✓]${NC} GitLab Instance: Ready (${GITLAB_PODS} pods)"
elif [ "$GITLAB_PODS" -ge 5 ]; then
    echo -e "  ${YELLOW}[!]${NC} GitLab Instance: Starting (${GITLAB_PODS} pods, webservice not ready)"
else
    echo -e "  ${RED}[✗]${NC} GitLab Instance: Not ready (${GITLAB_PODS} pods)"
fi

# GitLab Runner Operator
RUNNER_OP=$(oc get csv -n gitlab-system --no-headers 2>/dev/null | grep -i gitlab-runner | grep -c "Succeeded" 2>/dev/null || echo "0")
RUNNER_OP=$(echo "$RUNNER_OP" | tr -d '\n')
if [ "$RUNNER_OP" -ge 1 ]; then
    echo -e "  ${GREEN}[✓]${NC} GitLab Runner Operator: Installed"
else
    echo -e "  ${RED}[✗]${NC} GitLab Runner Operator: Not installed"
fi

# GitLab Runner Instance
RUNNER_PODS=$(oc get pods -n gitlab-system -l app=gitlab-runner --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || echo "0")
RUNNER_PODS=$(echo "$RUNNER_PODS" | tr -d '\n')
if [ "$RUNNER_PODS" -ge 1 ]; then
    echo -e "  ${GREEN}[✓]${NC} GitLab Runner: Running"
else
    echo -e "  ${YELLOW}[!]${NC} GitLab Runner: Not running (${RUNNER_PODS} pods)"
fi

# Demo Namespaces
NS_COUNT=$(oc get ns --no-headers 2>/dev/null | grep -cE "secure-app-dev|secure-app-staging|secure-app-prod" 2>/dev/null || echo "0")
NS_COUNT=$(echo "$NS_COUNT" | tr -d '\n')
if [ "$NS_COUNT" -ge 3 ]; then
    echo -e "  ${GREEN}[✓]${NC} Demo Namespaces: ${NS_COUNT}/3 created"
else
    echo -e "  ${YELLOW}[!]${NC} Demo Namespaces: Only ${NS_COUNT}/3 created"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# DEMO COMPONENTS (installed LIVE during demo)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}DEMO COMPONENTS (Installed Live During Demo)${NC}"
echo "─────────────────────────────────────────────────────────────────────────────"

# RHTAS Operator
RHTAS_OP=$(oc get csv -n rhtas-operator --no-headers 2>/dev/null | grep -i rhtas | grep -c "Succeeded" 2>/dev/null || echo "0")
RHTAS_OP=$(echo "$RHTAS_OP" | tr -d '\n')
if [ "$RHTAS_OP" -ge 1 ]; then
    echo -e "  ${GREEN}[✓]${NC} RHTAS Operator: Installed (demo already started)"
else
    echo -e "  ${BLUE}[○]${NC} RHTAS Operator: Not installed (install live in demo)"
fi

# SecureSign Instance
SECURESIGN=$(oc get securesign -n trusted-artifact-signer --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
SECURESIGN=$(echo "$SECURESIGN" | tr -d '\n' | tr -d ' ')
if [ "$SECURESIGN" -ge 1 ]; then
    echo -e "  ${GREEN}[✓]${NC} SecureSign: Deployed"
else
    echo -e "  ${BLUE}[○]${NC} SecureSign: Not deployed (deploy live in demo)"
fi

# Policy Controller
POLICY_NS=$(oc get ns cosign-system --no-headers 2>/dev/null | wc -l 2>/dev/null || echo "0")
POLICY_NS=$(echo "$POLICY_NS" | tr -d '\n' | tr -d ' ')
if [ "$POLICY_NS" -ge 1 ]; then
    POLICY_PODS=$(oc get pods -n cosign-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    echo -e "  ${GREEN}[✓]${NC} Policy Controller: Running (${POLICY_PODS} pods)"
else
    echo -e "  ${BLUE}[○]${NC} Policy Controller: Not installed (install live in demo)"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# URLS
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}URLS${NC}"
echo "─────────────────────────────────────────────────────────────────────────────"
echo "  OpenShift Console:  https://console-openshift-console.${CLUSTER_DOMAIN}"
echo "  GitLab:             https://gitlab.${CLUSTER_DOMAIN}"
echo "  ArgoCD:             https://openshift-gitops-server-openshift-gitops.${CLUSTER_DOMAIN}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CREDENTIALS
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}CREDENTIALS${NC}"
echo "─────────────────────────────────────────────────────────────────────────────"

# GitLab password
GITLAB_PW=$(oc get secret gitlab-gitlab-initial-root-password -n gitlab-system -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "Not available")
echo "  GitLab root password: ${GITLAB_PW}"

# ArgoCD password
ARGOCD_PW=$(oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "Not available")
echo "  ArgoCD admin password: ${ARGOCD_PW}"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
