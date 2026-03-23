# OpenShift Secure Supply Chain Demo

[![OpenShift](https://img.shields.io/badge/OpenShift-4.14+-EE0000?logo=redhatopenshift&logoColor=white)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![ArgoCD](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo&logoColor=white)](https://argo-cd.readthedocs.io/)
[![Sigstore](https://img.shields.io/badge/Signing-Sigstore%2FCosign-7B2D8B)](https://www.sigstore.dev/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A **one-command** deployment of a complete software supply chain security demo on Red Hat OpenShift. Deploys 10 GitOps-managed components that demonstrate image signing, SBOM generation, vulnerability scanning, policy-based admission, and transparency logging — all wired together through a Jenkins pipeline.

## What Gets Deployed

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          OpenShift Cluster                               │
│                                                                          │
│   ArgoCD (GitOps)  ──────►  10 Components via ApplicationSet            │
│        │                                                                 │
│        ├── Jenkins         CI/CD pipeline engine + OIDC provider         │
│        ├── GitLab          Application source code hosting               │
│        ├── RHTAS           Fulcio (CA) + Rekor (log) + TUF + TSA        │
│        ├── ACS             CVE scanning + runtime security               │
│        ├── Quay            Container registry for images + signatures    │
│        ├── Sigstore PC     Admission webhook — verifies attestations     │
│        ├── Sealed Secrets  Encrypted secrets in Git                      │
│        └── MySQL           Transparency log backend                      │
│                                                                          │
│   Pipeline: build → scan → sign → attest → deploy → admission verify   │
└──────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

**Prerequisites:** `oc` CLI, `git`, `curl`, and access to an OpenShift 4.14+ cluster with cluster-admin.

```bash
# 1. Log in to your OpenShift cluster
oc login https://api.<cluster>:6443 -u <user> -p '<password>'

# 2. Clone and run
git clone https://github.com/ihsanmokhlisse/openshift-secure-supply-chain-demo.git
cd openshift-secure-supply-chain-demo
./spin-demo.sh
```

The script handles everything end-to-end:

| Step | What happens | Duration |
|------|-------------|----------|
| 1 | Replace `__CLUSTER_DOMAIN__` placeholders for your cluster | ~2s |
| 2 | Install OpenShift GitOps (ArgoCD), configure RBAC | ~40s |
| 3 | Deploy Gitea (in-cluster Git server for GitOps manifests) | ~60s |
| 4 | Push manifests to Gitea, apply ArgoCD ApplicationSet | ~10s |
| 5 | Wait for ArgoCD to create all 10 applications | ~15s |
| 6 | Wait for Jenkins, GitLab, RHTAS, ACS, Quay to become healthy | ~2min |
| 7 | Create GitLab project, push `secure-app` source code | ~8min |
| 8 | Health check + print credentials | ~2s |

**Total: ~12–15 minutes** (GitLab is the slowest operator to initialize).

## After Deployment

1. Open **Jenkins** → Create a Multibranch Pipeline
   - Repository: `https://gitlab.<apps-domain>/root/secure-app.git`
   - Script path: `Jenkinsfile`
2. Run the pipeline on `develop` → DEV, `main` → STAGING, or `release/*` → PROD
3. Watch the full supply chain in action:
   - Image signing in **Rekor** transparency log
   - SBOM + vulnerability + ACS attestations attached to images in **Quay**
   - Admission gating by **Sigstore Policy Controller**
   - CVE dashboard in **ACS Central**

## Pipeline Security Flow

```
Developer pushes code to GitLab
        │
        ▼
Jenkins detects change, checks out code
        │
        ▼
Build images with buildah → push to Quay
        │
        ▼
┌───────────────────────────────────────┐
│  Generate SBOM (syft, CycloneDX)      │
│  Vulnerability scan (Trivy)           │  ← parallel
│  Policy check (ACS roxctl)            │
└───────────────────────────────────────┘
        │
        ▼
Keyless signing with cosign (Fulcio + OIDC)
        │
        ▼
Attest SBOM + vuln scan + ACS check (cosign attest)
        │
        ▼
All recorded in Rekor transparency log
        │
        ▼
Deploy to target namespace (oc apply)
        │
        ▼
┌───────────────────────────────────────┐
│  Sigstore Policy Controller           │
│  ✓ Valid signature from trusted OIDC? │
│  ✓ SBOM attestation present?          │
│  ✓ Vuln scan attestation present?     │
│  ✓ ACS check attestation present?     │
│  ✗ Any missing → DEPLOYMENT REJECTED  │
└───────────────────────────────────────┘
```

## Default Credentials

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| ArgoCD | `https://openshift-gitops-server-openshift-gitops.<domain>` | admin | _auto (see .credentials.txt)_ |
| Gitea | `https://gitea.<domain>` | admin | openshift |
| Jenkins | `https://jenkins.<domain>` | admin | openshift |
| GitLab | `https://gitlab.<domain>` | root | openshift |
| Quay | `https://registry-quay-quay.<domain>` | admin | openshift |
| ACS | `https://central-stackrox.<domain>` | admin | openshift |

Credentials are saved to `.credentials.txt` after deployment.

## Cleanup

Remove all demo resources and start fresh:

```bash
./cleanup.sh              # interactive confirmation
./cleanup.sh --yes        # skip confirmation
```

## Repository Structure

```
.
├── spin-demo.sh                  # One-command bootstrap
├── cleanup.sh                    # Full teardown
├── check-status.sh               # Quick health snapshot
├── ARCHITECTURE.md               # Deep-dive technical documentation
├── repo/                         # GitOps manifests (pushed to Gitea)
│   ├── argocd/                   # ApplicationSet definition
│   ├── config/                   # enabled-components.yaml
│   ├── components/               # Kustomize manifests per component
│   │   ├── acs/                  # ACS Central + SecuredCluster
│   │   ├── gitea/                # Gitea operator + instance
│   │   ├── gitlab/               # GitLab operator + instance + setup jobs
│   │   ├── jenkins/              # Jenkins + OIDC + agent image build
│   │   ├── jenkins-app-namespaces/  # Dev/staging/prod + RHTAS config
│   │   ├── mysql/                # MySQL for Rekor Trillian backend
│   │   ├── quay/                 # Quay registry + setup
│   │   ├── rhtas-operator/       # RHTAS operator subscription
│   │   ├── rhtas-securesign/     # Fulcio + Rekor + TUF + TSA
│   │   ├── sealed-secrets/       # Bitnami Sealed Secrets
│   │   └── sigstore-policy-controller/  # 12 active admission policies
│   └── apps-projects/
│       └── secure-app/           # Pilot app (Node.js + Nginx) + Jenkinsfile
```

## Key Technologies

| Technology | Role |
|-----------|------|
| [Red Hat OpenShift](https://www.redhat.com/en/technologies/cloud-computing/openshift) | Kubernetes platform |
| [ArgoCD / OpenShift GitOps](https://argo-cd.readthedocs.io/) | GitOps deployment engine |
| [RHTAS (Trusted Artifact Signer)](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer) | Fulcio, Rekor, TUF — keyless signing infrastructure |
| [Sigstore / Cosign](https://www.sigstore.dev/) | Image signing, attestation, and verification |
| [Red Hat ACS (StackRox)](https://www.redhat.com/en/technologies/cloud-computing/openshift/advanced-cluster-security-kubernetes) | CVE scanning and runtime policy enforcement |
| [Jenkins](https://www.jenkins.io/) | CI/CD pipeline with OIDC-based identity |
| [Red Hat Quay](https://www.redhat.com/en/technologies/cloud-computing/quay) | Container registry with OCI artifact support |
| [GitLab CE](https://about.gitlab.com/) | Source code management |
| [Syft](https://github.com/anchore/syft) | SBOM generation (CycloneDX) |
| [Trivy](https://github.com/aquasecurity/trivy) | Container vulnerability scanning |

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the Apache License 2.0 — see [LICENSE](LICENSE) for details.

## Author

**Ihsan Mokhlisse** — [GitHub](https://github.com/ihsanmokhlisse)
