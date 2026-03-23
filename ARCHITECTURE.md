# Architecture — Jenkins Secure Supply Chain Demo

This document explains every component in `demo/jenkins/`, how they connect, and what happens when the pipeline runs.

---

## High-level flow

```
                         ┌─────────────────────────────────────────────────────────────────┐
                         │                    OpenShift Cluster                             │
                         │                                                                  │
  ┌────────┐   push      │  ┌──────────┐   ApplicationSet   ┌─────────────────────────┐   │
  │ demo/  │───────────► │  │  Gitea   │ ◄────────────────── │  Argo CD (GitOps)       │   │
  │jenkins/│  repo/      │  │(manifests│   reads config/     │  Deploys 10 components  │   │
  │repo/   │             │  │  repo)   │   enabled-components│  via sync-waves         │   │
  └────────┘             │  └──────────┘   .yaml             └───────────┬─────────────┘   │
                         │                                               │                  │
                         │       ┌───────────────────────────────────────┘                  │
                         │       ▼                                                          │
                         │  ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌─────────┐  ┌──────┐ │
                         │  │ Jenkins │  │ GitLab  │  │  RHTAS   │  │   ACS   │  │ Quay │ │
                         │  │(pipeline│  │(app src)│  │(signing) │  │ (CVE    │  │(image│ │
                         │  │ engine) │  │         │  │          │  │  gate)  │  │ reg) │ │
                         │  └────┬────┘  └────┬────┘  └────┬─────┘  └────┬────┘  └──┬───┘ │
                         │       │            │            │              │           │      │
                         │       ▼            ▼            ▼              ▼           ▼      │
                         │  ┌──────────────────────────────────────────────────────────────┐ │
                         │  │                   Jenkins Pipeline                           │ │
                         │  │  checkout → build → push to Quay → SBOM → Trivy → ACS →     │ │
                         │  │  cosign sign → cosign attest (SBOM, vuln, ACS) → deploy      │ │
                         │  └──────────────────────────────────────────────────────────────┘ │
                         │       │                                                          │
                         │       ▼                                                          │
                         │  ┌──────────────────────────┐                                    │
                         │  │ Sigstore Policy Controller│                                    │
                         │  │ (admission webhook)       │                                    │
                         │  │ Verifies: signature +     │                                    │
                         │  │ SBOM + vuln + ACS attest  │                                    │
                         │  └──────────────────────────┘                                    │
                         │       │                                                          │
                         │       ▼                                                          │
                         │  ┌─────────────────────────────────────┐                         │
                         │  │ secure-app-dev / staging / prod     │                         │
                         │  │ (deployment admitted only if all    │                         │
                         │  │  attestations are present + valid)  │                         │
                         │  └─────────────────────────────────────┘                         │
                         └─────────────────────────────────────────────────────────────────┘
```

---

## GitOps model

### How ArgoCD manages components

`spin-demo.sh` pushes `repo/` to Gitea. The `argocd/applicationset.yaml` inside that repo uses a **matrix generator**: it reads the component list from `config/enabled-components.yaml` and generates one ArgoCD Application per entry. Each Application points to `components/<name>/`.

```yaml
# config/enabled-components.yaml (the only file you edit to add/remove components)
components:
  - sealed-secrets          # wave 0
  - mysql                   # wave 2
  - jenkins                 # wave 5
  - jenkins-app-namespaces  # wave 18
  - gitlab                  # wave 5
  - rhtas-operator          # wave 5
  - rhtas-securesign        # wave 10
  - acs                     # wave 5
  - sigstore-policy-controller  # wave 15
  - quay                    # wave 5
```

Sync-wave annotations in each component's manifests control deployment order. Lower numbers deploy first.

---

## Component reference

### 1. Sealed Secrets (`components/sealed-secrets/`)

**What:** Bitnami Sealed Secrets operator. Encrypts Kubernetes secrets so they can be stored safely in Git.

**Files:** Single `kustomization.yaml` that installs the operator subscription.

**Why it's here:** Foundation for storing database passwords and other credentials in the GitOps repo without exposing them.

---

### 2. MySQL (`components/mysql/`)

**What:** MySQL 8.0 database used by RHTAS Trillian (the Merkle tree backend for Rekor).

**Files:** Namespace, Deployment, PVC, Service, Secret (credentials), NetworkPolicies.

**Why it's here:** Rekor needs a persistent database to store the transparency log entries. Trillian connects to this MySQL instance.

---

### 3. Jenkins (`components/jenkins/`)

**What:** Jenkins controller deployed on OpenShift with:
- OIDC Provider plugin (issues JWTs that Fulcio trusts for keyless signing)
- Kubernetes cloud plugin (spins up build agents as pods)
- Custom agent image with buildah, cosign, syft, trivy, roxctl

**Files:**
- `namespace.yaml` — `jenkins` namespace
- `deployment.yaml` — Jenkins controller (with OIDC, CasC)
- `configmap.yaml` — Jenkins Configuration as Code (JCasC) defining Kubernetes cloud, pod templates, security settings
- `agent-buildconfig.yaml` + `agent-image/Dockerfile` — builds the `supply-chain` agent image (buildah + signing tools)
- `admin-credentials-secret.yaml` — admin/openshift
- `pvc.yaml` — persistent storage for Jenkins home
- `rbac.yaml` — ServiceAccount + ClusterRoleBindings for building images and deploying to app namespaces
- `route.yaml` — external HTTPS route

**Key detail:** Jenkins OIDC issuer is `https://jenkins.<apps-domain>/oidc`. This URL is registered as a trusted issuer in the RHTAS SecureSign config so Fulcio can issue signing certificates to Jenkins pipeline runs.

---

### 4. Jenkins App Namespaces (`components/jenkins-app-namespaces/`)

**What:** Creates the three deployment environments and wires them for RHTAS + Jenkins.

**Files:**
- `namespaces.yaml` — `secure-app-dev`, `secure-app-staging`, `secure-app-prod` with label `policy.sigstore.dev/include: "true"` (enables Sigstore admission in these namespaces)
- `rhtas-config.yaml` — ConfigMaps with RHTAS URLs (Fulcio, Rekor, TUF, TSA, OIDC issuer) in each namespace. The Jenkinsfile reads these as environment variables.
- `rbac.yaml` — grants Jenkins SA permissions to deploy into these namespaces
- `wait-for-jenkins.yaml` — PreSync Job that ensures Jenkins is up before creating namespaces

**Key detail:** The label `policy.sigstore.dev/include: "true"` on each namespace tells the Sigstore Policy Controller webhook to enforce admission policies there. Without this label, images would deploy unchecked.

---

### 5. GitLab (`components/gitlab/`)

**What:** GitLab CE instance. Hosts the `secure-app` application source code. Jenkins pulls from here.

**Files:**
- `subscription.yaml` — GitLab Operator subscription from OperatorHub
- `gitlab.yaml` — GitLab CR (instance definition)
- `gitlab-admin-secret.yaml` — admin password seed
- `gitlab-oidc-setup.yaml` — PostSync Job: registers a `sigstore` OIDC application in GitLab (for GitLab CI signing — not used in the Jenkins track but configured for completeness)
- `gitlab-secure-app-setup.yaml` — PostSync Job: creates the `secure-app` project and pushes code
- `gitlab-password-reset.yaml` — PostSync Job: resets root password to `openshift`
- `gitlab-test-users-setup.yaml` — PostSync Job: creates test users
- `secure-app-jenkinsfile-configmap.yaml` — stores the Jenkinsfile as a ConfigMap (used by setup jobs)

**Key detail:** `spin-demo.sh` also creates the `secure-app` project and pushes code in Step 7 (belt-and-suspenders approach in case the PostSync job hasn't run yet).

---

### 6. RHTAS Operator (`components/rhtas-operator/`)

**What:** Installs the Red Hat Trusted Artifact Signer operator from OperatorHub.

**Files:** `subscription.yaml` + `kustomization.yaml`.

**Why separate from SecureSign:** The operator must be installed before the SecureSign CR can be created (enforced by sync-waves: operator at wave 5, SecureSign at wave 10).

---

### 7. RHTAS SecureSign (`components/rhtas-securesign/`)

**What:** The SecureSign custom resource that deploys the full signing stack:
- **Fulcio** — Certificate authority for keyless signing (issues short-lived certs based on OIDC identity)
- **Rekor** — Transparency log (immutable append-only ledger of all signatures)
- **TUF** — The Update Framework (distributes root of trust to clients)
- **TSA** — Timestamp Authority (proves when a signature was created)

**OIDC issuers configured in `securesign.yaml`:**

| Issuer | Type | Who uses it |
|--------|------|------------|
| `https://kubernetes.default.svc` | kubernetes | In-cluster workloads (Tekton, Jobs) |
| `https://gitlab.<domain>` | gitlab-pipeline | GitLab CI runners |
| `https://jenkins.<domain>/oidc` | uri | Jenkins pipelines |

**How signing works:** When the Jenkinsfile calls `cosign sign`, cosign contacts Fulcio with a JWT from Jenkins OIDC. Fulcio verifies the JWT against the registered issuer, issues a short-lived X.509 certificate, and cosign uses it to sign. The signature is recorded in Rekor. No long-lived keys exist — the identity is the Jenkins job path embedded in the JWT.

---

### 8. ACS — Red Hat Advanced Cluster Security (`components/acs/`)

**What:** Deploys StackRox Central + Scanner + SecuredCluster for:
- CVE scanning of images
- Policy-based image checks (`roxctl image check`)
- Runtime security monitoring
- Compliance dashboards

**Files:**
- `subscription.yaml` + `operatorgroup.yaml` — installs the ACS operator
- `central.yaml` — ACS Central instance
- `secured-cluster.yaml` — SecuredCluster that registers with Central
- `acs-reset-admin-password-job.yaml` — PostSync: sets admin password to `openshift`
- `init-api-token-job.yaml` — PostSync: creates an API token and stores it in a Secret so Jenkins can call `roxctl`
- `acs-jenkins-credentials-rbac.yaml` — grants Jenkins access to the ACS API token secret
- `api-token-secret.yaml` — placeholder Secret for the API token

**Pipeline integration:** The Jenkinsfile mounts the ACS API token as a file, downloads `roxctl` from Central, and runs `roxctl image scan` + `roxctl image check`. The JSON output is then attested with `cosign attest --type https://stackrox.io/policy-check/v1`.

---

### 9. Sigstore Policy Controller (`components/sigstore-policy-controller/`)

**What:** Kubernetes admission webhook that verifies cosign signatures and attestations before allowing pod creation.

**Core files:**
- `subscription.yaml` — installs the Policy Controller operator
- `policycontroller.yaml` — PolicyController CR
- `trustroot.yaml` — TrustRoot with Fulcio CA cert, Rekor public key, CTlog key
- `trustroot-tuf-secret-job.yaml` — PostSync Job that fetches live TUF root.json

**Active policies (in `policies/`):**

| # | Policy | What it enforces | Scope |
|---|--------|------------------|-------|
| 00 | `require-multi-signature-chain` | Production images require 3 signatures: develop + main + release branch | `prod-*`, `v*` tags only |
| 01 | `allow-redhat-images` | Red Hat registry images pass without signature | `registry.redhat.io`, `registry.access.redhat.com` |
| 02 | `rhtas-signed-images` | All Quay images must have a valid cosign signature from a trusted OIDC issuer | All `secure-app/**` images |
| 03 | `require-pipeline-signature` | Signature must come from Jenkins pipeline OIDC (not manual cosign) | All `secure-app/**` images |
| 04 | `require-develop-or-main-signature` | Signature identity must include develop or main branch path | All `secure-app/**` images |
| 05 | `require-production-release-signature` | Production images must be signed from `release/*` branch | `prod-*`, `v*` tags only |
| 06 | `require-multi-signature` | Production images need 2 signatures: dev pipeline + main/release pipeline | `prod-*` tags only |
| 07 | `require-sbom-attestation` | CycloneDX SBOM attestation must exist (produced by syft) | All `secure-app/**` images |
| 08 | `require-vulnerability-scan` | Trivy vulnerability scan attestation must exist | All `secure-app/**` images |
| 09 | `require-acs-policy-check` | ACS `roxctl image check` attestation must exist | All `secure-app/**` images |
| 10 | `deny-risky-tags` | Blocks `:latest`, `:dev`, `:test` tags | All images in labeled namespaces |
| 11 | `deny-untrusted-registries` | Blocks images from `docker.io`, `ghcr.io`, `gcr.io` | All images in labeled namespaces |
| 99 | `block-all-unsigned` | Catch-all: block any image not covered by other policies | All images in labeled namespaces |

**Disabled policies (available but commented out):**

| # | Policy | Why disabled | How to enable |
|---|--------|-------------|---------------|
| 09b | `require-slsa-provenance` | Pipeline doesn't generate SLSA provenance yet | Add `cosign attest --type slsaprovenance` to Jenkinsfile |
| 12 | `deny-known-vulnerable-images` | ACS handles this at runtime | Uncomment if you want admission-time blocking too |
| 13 | `deny-privileged-images` | Blocks dind/netshoot used by some build agents | Uncomment for strict environments |
| 14–16 | Compliance (labels, base image, license) | Require attestation types not in the pipeline | Add corresponding attestation stages |
| 17–19 | Advanced security (freshness, secrets, SAST) | Require Trufflehog/Semgrep integration | Add scanning tools + attestation stages |
| 20, 24 | Governance (code review, human approval) | Require MR approval attestation or dual signatures | Implement GitLab webhook → attestation flow |
| 21 | Test coverage | Requires coverage attestation | Add `cosign attest --type test-coverage` |
| 22–23 | Supply chain (dependency pinning, hermetic) | Requires SLSA Level 3+ build setup | Implement hermetic build environment |
| 25–27 | Operations (image size, runtime security, readiness) | Require operational metadata attestation | Add ops metadata attestation stage |
| 50–55 | ML pipeline | For `ml-model-app`, not `secure-app` | Enable when ML pipeline is active |

**How admission works:** When `oc apply -f deployment.yaml` runs in `secure-app-dev` (which has label `policy.sigstore.dev/include: "true"`), the Policy Controller webhook intercepts the request. It pulls the image's cosign signatures and attestations from the registry, verifies them against the TrustRoot (Fulcio CA + Rekor), and checks that each active policy passes. If any required attestation is missing or invalid, the pod creation is **rejected**.

---

### 10. Quay (`components/quay/`)

**What:** Red Hat Quay container registry. Jenkins pushes built images here; cosign stores signatures and attestations as OCI artifacts alongside the images.

**Files:**
- `subscription.yaml` — Quay operator
- `quayregistry.yaml` — QuayRegistry CR
- `quay-config-bundle.yaml` — Quay configuration (storage, auth)
- `quay-registry-setup-job.yaml` — PostSync: creates `secure-app` organization and `admin` user with password `openshift`
- `wait-for-operator.yaml` — PreSync Job

**Image path:** `registry-quay-quay.<domain>/secure-app/backend:<sha>` and `.../frontend:<sha>`.

---

### 11. Gitea (`components/gitea/`)

**What:** Lightweight Git server. Hosts the GitOps manifests repo that ArgoCD reads.

**Files:** CatalogSource, Subscription, OperatorGroup, Gitea CR, Namespace.

**Not in enabled-components.yaml** because `spin-demo.sh` deploys it directly before the ApplicationSet exists (chicken-and-egg: ArgoCD needs Gitea to exist before it can read from it).

---

## The pilot application (`repo/apps-projects/secure-app/`)

A two-tier web application: Node.js backend + Nginx frontend.

| File | Purpose |
|------|---------|
| `Jenkinsfile` | Main pipeline — branch routing, build, scan, sign, attest, deploy |
| `backend/server.js` | Express API |
| `backend/Dockerfile` | Backend container image |
| `frontend/index.html` | Static frontend |
| `frontend/Dockerfile` | Nginx-based frontend image |
| `k8s/deployment.yaml` | Kubernetes Deployment (patched per env by pipeline) |
| `k8s/service.yaml` | ClusterIP Service |
| `k8s/route.yaml` | OpenShift Route |

### Pipeline stages (Jenkinsfile)

```
Prepare → Tool Check → Checkout → Code Quality (lint/test + kube-lint)
    → Build & Push Images (buildah → Quay)
    → Generate SBOMs (syft → cyclonedx-json)
    → Vulnerability Scans (Trivy + ACS roxctl — in parallel)
    → Sign & Attest (cosign sign + 3 attestations: SBOM, vuln, ACS)
    → Verify Signatures & Attestations (cosign verify)
    → Deploy (oc apply to target namespace — admission enforced here)
```

### Branch → Environment routing

| Branch | Environment | Namespace | Policy strictness |
|--------|-------------|-----------|-------------------|
| `develop` (or any) | DEV | `secure-app-dev` | Base policies |
| `main` | STAGING | `secure-app-staging` | Base + branch identity |
| `release/*` | PRODUCTION | `secure-app-prod` | All policies + multi-signature |

---

## Versions and images reference

### Operators (installed via OLM)

| Component | Operator name | Channel | Source |
|-----------|--------------|---------|--------|
| RHTAS | `rhtas-operator` | `stable` | `redhat-operators` |
| ACS (StackRox) | `rhacs-operator` | `stable` | `redhat-operators` |
| Quay | `quay-operator` | `stable-3.13` | `redhat-operators` |
| Sigstore Policy Controller | `policy-controller-operator` | `tech-preview` | `redhat-operators` |
| GitLab | `gitlab-operator-kubernetes` | `stable` | `community-operators` |
| Gitea | `gitea-operator` | `stable` | `rhpds-gitea-catalog` (CatalogSource: `quay.io/rhpds/gitea-catalog:latest`) |

No `startingCSV` is pinned — operators track the latest version in their channel. To pin a specific version, add `startingCSV` to the Subscription YAML.

### Helm charts

| Component | Chart | Version | Repository |
|-----------|-------|---------|------------|
| Sealed Secrets | `sealed-secrets` | `2.13.3` | `https://bitnami-labs.github.io/sealed-secrets` |
| GitLab instance | GitLab chart (via operator) | `9.8.7` | Managed by GitLab operator |

### Container images

| Component | Image | Tag |
|-----------|-------|-----|
| Jenkins controller | `openshift/jenkins` (internal registry) | `2` |
| Jenkins agent base | `openshift/jenkins-agent-base` (internal registry) | `latest` |
| Jenkins agent buildah | `registry.redhat.io/rhel8/buildah` | `latest` |
| MySQL | `docker.io/mysql` | `8.0` |
| secure-app backend base | `registry.access.redhat.com/ubi8/nodejs-18-minimal` | `latest` |
| secure-app frontend base | `registry.access.redhat.com/ubi8/nginx-120` | `latest` |
| Job images (ose-cli) | `registry.redhat.io/openshift4/ose-cli` | `latest` |

### Jenkins plugins

| Plugin | Version |
|--------|---------|
| `gitlab-plugin` | `1.6.0` |
| `oidc-provider` | `62.vd67c19f76766` |

All other Jenkins plugins come from the base OpenShift Jenkins image (`jenkins:2`).

### CLI tools (downloaded at pipeline runtime)

These are downloaded inside the Jenkins agent pod during the "Tool Check" stage — they are not pre-installed:

| Tool | Purpose | Download source |
|------|---------|-----------------|
| `cosign` | Image signing + attestation | RHTAS CLI server (`cli-server.trusted-artifact-signer.svc:8080`) |
| `rekor-cli` | Transparency log queries | RHTAS CLI server |
| `syft` | SBOM generation (CycloneDX) | `anchore/syft` install script |
| `trivy` | Vulnerability scanning | `aquasecurity/trivy` install script |
| `roxctl` | ACS image scan + policy check | Downloaded from ACS Central (`central.stackrox.svc:443`) |

Tools are downloaded as latest available. To pin versions, modify the `ensure_tool` calls in the Jenkinsfile's "Tool Check" stage.

---

## Deployment order (sync-waves)

```
Wave  0: sealed-secrets
Wave  2: mysql
Wave  5: jenkins, gitlab, rhtas-operator, acs, quay (parallel)
Wave 10: rhtas-securesign (needs operator from wave 5)
Wave 15: sigstore-policy-controller (needs RHTAS certs from wave 10)
Wave 18: jenkins-app-namespaces (needs Jenkins + RHTAS URLs)
```

---

## Security flow summary

1. Developer pushes code to GitLab (`secure-app`)
2. Jenkins detects the change, checks out code
3. Jenkins builds images with buildah, pushes to Quay
4. Jenkins generates SBOM (syft), runs Trivy scan, runs ACS policy check
5. Jenkins signs the image with cosign (keyless — Fulcio cert from Jenkins OIDC)
6. Jenkins attests SBOM, vulnerability scan, and ACS check (cosign attest)
7. All signatures and attestations are recorded in Rekor transparency log
8. Jenkins deploys to the target namespace (`oc apply`)
9. **Sigstore Policy Controller intercepts the deployment** and verifies:
   - Image has a valid signature from a trusted OIDC issuer
   - SBOM attestation exists
   - Vulnerability scan attestation exists
   - ACS policy check attestation exists
10. If all checks pass → pod is created. If any fail → **deployment rejected**.
