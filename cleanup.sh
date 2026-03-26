#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# RHTAS Jenkins Demo — Full cluster cleanup
#
# Removes ALL resources deployed by spin-demo.sh so you can start fresh.
# Local files are NOT affected.
#
# Usage:  ./demo/jenkins/cleanup.sh [--yes]
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

AUTO_YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && AUTO_YES=true

confirm() {
    [ "$AUTO_YES" = true ] && return 0
    read -p "$(echo -e "${YELLOW}[?]${NC} $1 [y/N]: ")" -r
    [[ $REPLY =~ ^[Yy]$ ]]
}

del() {
    echo -e "${RED}[DEL]${NC} $2"
    eval "$1" 2>/dev/null || true
}

# ── Preflight ─────────────────────────────────────────────────────────────────
if ! oc whoami &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Not logged into OpenShift."
    exit 1
fi

echo ""
echo -e "${BOLD}${RED}  RHTAS Jenkins Demo — FULL CLEANUP${NC}"
echo ""
echo -e "  Cluster: $(oc whoami --show-server)"
echo -e "  User:    $(oc whoami)"
echo ""
echo "  This will delete ALL demo resources from the cluster."
echo "  Local files are NOT affected."
echo ""

if ! confirm "Proceed with full cleanup?"; then
    echo "Cancelled."; exit 0
fi

ARGOCD_NS="openshift-gitops"

# ═════════════════════════════════════════════════════════════════════════════
# 1. Delete ApplicationSet (this cascades and deletes all ArgoCD Applications)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}━━━ Step 1: ApplicationSet + ArgoCD Applications ━━━${NC}"

if oc get applicationset rhtas-demo-components -n "${ARGOCD_NS}" &>/dev/null; then
    del "oc delete applicationset rhtas-demo-components -n ${ARGOCD_NS} --wait=false" \
        "ApplicationSet rhtas-demo-components"
fi

# Also delete any individual apps that might remain
for app in $(oc get applications -n "${ARGOCD_NS}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true); do
    del "oc patch application ${app} -n ${ARGOCD_NS} --type merge -p '{\"metadata\":{\"finalizers\":null}}'" \
        "Remove finalizer: ${app}"
    del "oc delete application ${app} -n ${ARGOCD_NS} --wait=false" \
        "Application: ${app}"
done

echo -e "${GREEN}[OK]${NC} ArgoCD applications cleaned"
sleep 5

# ═════════════════════════════════════════════════════════════════════════════
# 2. Delete component namespaces
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}━━━ Step 2: Component namespaces ━━━${NC}"

NAMESPACES=(
    jenkins
    gitlab-system
    gitea-system
    stackrox
    trusted-artifact-signer
    cosign-system
    policy-controller-operator
    quay
    mysql
    secure-app-dev
    secure-app-staging
    secure-app-prod
)

for ns in "${NAMESPACES[@]}"; do
    if oc get namespace "$ns" &>/dev/null; then
        del "oc delete namespace $ns --wait=false" "Namespace: $ns"
    fi
done

echo -e "${GREEN}[OK]${NC} Namespace deletion initiated"

# ═════════════════════════════════════════════════════════════════════════════
# 3. Delete cluster-scoped resources
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}━━━ Step 3: Cluster-scoped resources ━━━${NC}"

# ClusterImagePolicies (Sigstore)
for cip in $(oc get clusterimagepolicies.policy.sigstore.dev --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true); do
    del "oc delete clusterimagepolicy.policy.sigstore.dev ${cip}" \
        "ClusterImagePolicy: ${cip}"
done

# TrustRoots
for tr in $(oc get trustroots.policy.sigstore.dev --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true); do
    del "oc delete trustroot.policy.sigstore.dev ${tr}" \
        "TrustRoot: ${tr}"
done

# Remove CRs that have operator-managed finalizers (clear finalizer first, then delete)
remove_cr() {
    local api_resource=$1 label=$2
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ns name
        ns=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        oc patch "$api_resource" "$name" -n "$ns" --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        del "oc delete ${api_resource} ${name} -n ${ns} --wait=false" "${label}: ${ns}/${name}"
    done < <(oc get "$api_resource" --all-namespaces --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null || true)
}

remove_cr securesigns.rhtas.redhat.com "SecureSign"
remove_cr centrals.platform.stackrox.io "Central"
remove_cr securedclusters.platform.stackrox.io "SecuredCluster"
remove_cr quayregistries.quay.redhat.com "QuayRegistry"
remove_cr gitlabs.apps.gitlab.com "GitLab"
remove_cr policycontrollers.rhtas.charts.redhat.com "PolicyController"
remove_cr argocds.argoproj.io "ArgoCD"

echo -e "${GREEN}[OK]${NC} Cluster-scoped resources cleaned"

# ═════════════════════════════════════════════════════════════════════════════
# 4. Delete operator subscriptions + CSVs
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}━━━ Step 4: Operators ━━━${NC}"

declare -A OPERATORS=(
    [rhtas-operator]="openshift-operators"
    [rhacs-operator]="openshift-operators"
    [quay-operator]="openshift-operators"
    [openshift-pipelines-operator-rh]="openshift-operators"
    [gitea-operator]="gitea-system"
    [gitlab-operator-kubernetes]="gitlab-system"
    [openshift-gitops-operator]="openshift-operators"
)

for sub_name in "${!OPERATORS[@]}"; do
    sub_ns="${OPERATORS[$sub_name]}"
    if oc get subscription "${sub_name}" -n "${sub_ns}" &>/dev/null 2>&1; then
        CSV=$(oc get subscription "${sub_name}" -n "${sub_ns}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        del "oc delete subscription ${sub_name} -n ${sub_ns}" \
            "Subscription: ${sub_name}"
        if [ -n "$CSV" ]; then
            del "oc delete csv ${CSV} -n ${sub_ns}" \
                "CSV: ${CSV}"
        fi
    fi
done

# Sweep any orphaned CSVs from openshift-operators (subscriptions may already be gone)
for csv in $(oc get csv -n openshift-operators --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true); do
    case "$csv" in
        rhtas-operator*|rhacs-operator*|quay-operator*|openshift-gitops-operator*|gitea-operator*|gitlab-operator*|policy-controller-operator*)
            del "oc delete csv ${csv} -n openshift-operators" "Orphaned CSV: ${csv}"
            ;;
    esac
done

# Gitea CatalogSource
del "oc delete catalogsource rhpds-gitea-catalog -n openshift-marketplace" \
    "CatalogSource: rhpds-gitea-catalog"

echo -e "${GREEN}[OK]${NC} Operators cleaned"

# ═════════════════════════════════════════════════════════════════════════════
# 5. Delete ArgoCD namespace (last, so ArgoCD doesn't recreate anything)
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}━━━ Step 5: OpenShift GitOps ━━━${NC}"

if oc get namespace "${ARGOCD_NS}" &>/dev/null; then
    del "oc delete namespace ${ARGOCD_NS} --wait=false" "Namespace: ${ARGOCD_NS}"
fi

echo -e "${GREEN}[OK]${NC} GitOps cleanup initiated"

# ═════════════════════════════════════════════════════════════════════════════
# 6. Wait for namespace termination
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}━━━ Step 6: Waiting for namespaces to terminate ━━━${NC}"
echo -e "${YELLOW}  This can take 5-10 minutes (PVCs, finalizers, operator hooks)${NC}"
echo ""

ALL_NS=("${NAMESPACES[@]}" "${ARGOCD_NS}")
for attempt in $(seq 1 60); do
    stuck=0
    for ns in "${ALL_NS[@]}"; do
        if oc get namespace "$ns" &>/dev/null 2>&1; then
            stuck=$((stuck + 1))
        fi
    done
    if [ $stuck -eq 0 ]; then
        echo ""
        echo -e "${GREEN}[OK]${NC} All namespaces deleted"
        break
    fi
    printf "\r  Waiting… %d namespace(s) still terminating (%ds)" "$stuck" "$((attempt * 10))"
    sleep 10
done

# Force-remove stuck namespaces: clear resource finalizers first, then namespace finalizers
for ns in "${ALL_NS[@]}"; do
    if oc get namespace "$ns" &>/dev/null 2>&1; then
        echo -e "${YELLOW}[WARN]${NC} Force-removing stuck namespace: $ns"
        for resource_type in \
            securesigns.rhtas.redhat.com \
            centrals.platform.stackrox.io \
            securedclusters.platform.stackrox.io \
            quayregistries.quay.redhat.com \
            gitlabs.apps.gitlab.com \
            policycontrollers.rhtas.charts.redhat.com \
            argocds.argoproj.io; do
            for res in $(oc get "$resource_type" -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true); do
                oc patch "$resource_type" "$res" -n "$ns" --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
            done
        done
        oc get namespace "$ns" -o json \
            | python3 -c 'import sys,json; ns=json.load(sys.stdin); ns["spec"]["finalizers"]=[]; print(json.dumps(ns))' \
            | oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - 2>/dev/null || true
    fi
done

# ═════════════════════════════════════════════════════════════════════════════
# Done
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║               CLEANUP COMPLETE                                ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  To redeploy:  ./demo/jenkins/spin-demo.sh"
echo ""
