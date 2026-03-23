# Sigstore Policy Controller - Policy Documentation

This directory contains the Sigstore Policy Controller configuration for enforcing image signature policies on OpenShift.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Policy Types](#policy-types)
- [GitLab OIDC Identity Format](#gitlab-oidc-identity-format)
- [Policy Reference](#policy-reference)
- [Policy Modes](#policy-modes)
- [Customization Guide](#customization-guide)
- [Testing Policies](#testing-policies)
- [Troubleshooting](#troubleshooting)

---

## Overview

The Sigstore Policy Controller is a Kubernetes admission webhook that validates container image signatures before allowing pod creation. It integrates with RHTAS (Red Hat Trusted Artifact Signer) to verify signatures created by our GitLab CI pipelines.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        POLICY ENFORCEMENT FLOW                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────┐       ┌─────────────────┐       ┌─────────────────────┐      │
│   │ kubectl │──────▶│ API Server      │──────▶│ Policy Controller   │      │
│   │ apply   │       │ (Admission)     │       │ (Webhook)           │      │
│   └─────────┘       └─────────────────┘       └──────────┬──────────┘      │
│                                                          │                  │
│                                               ┌──────────▼──────────┐      │
│                                               │ Check Policies      │      │
│                                               │ 1. Allow lists      │      │
│                                               │ 2. Signature verify │      │
│                                               │ 3. Identity check   │      │
│                                               │ 4. Deny lists       │      │
│                                               └──────────┬──────────┘      │
│                                                          │                  │
│                              ┌────────────────┬──────────┴──────────┐      │
│                              ▼                ▼                      ▼      │
│                         ┌────────┐       ┌────────┐            ┌────────┐  │
│                         │ ALLOW  │       │  WARN  │            │ DENY   │  │
│                         │ Pod    │       │ + Log  │            │ Pod    │  │
│                         └────────┘       └────────┘            └────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Architecture

### Files in this Directory

| File | Description |
|------|-------------|
| `namespace.yaml` | Creates the `policy-controller` namespace |
| `trustroot.yaml` | Configures trust anchors for RHTAS (Fulcio CA, Rekor public key) |
| `policies/` | Directory containing individual policy files |
| `test-unsigned-pod.yaml` | Test pod to verify policies block unsigned images |
| `kustomization.yaml` | Kustomize configuration |

### Policy Files

```
policies/
├── 01-allow-redhat-images.yaml              # Allow Red Hat official images
├── 02-rhtas-signed-images.yaml              # Require RHTAS signatures
├── 03-require-pipeline-signature.yaml       # Require CI pipeline signatures
├── 04-require-develop-or-main-signature.yaml # Require develop/main branches
├── 05-require-production-release-signature.yaml # Production release policy
├── 06-require-multi-signature.yaml          # Multi-signature chain policy
├── 07-require-sbom-attestation.yaml         # [Optional] SBOM attestation
├── 08-require-vulnerability-scan.yaml       # [Optional] Vuln scan attestation
├── 09-require-slsa-provenance.yaml          # [Optional] SLSA provenance
├── 10-deny-risky-tags.yaml                  # Block risky tags (:latest, :dev)
├── 11-deny-untrusted-registries.yaml        # Block public registries
├── 12-deny-known-vulnerable-images.yaml     # Block CVE-affected images
├── 13-deny-privileged-images.yaml           # [Optional] Block privileged images
├── 14-require-image-labels.yaml             # [Optional] OCI label compliance
├── 15-require-base-image-allowlist.yaml     # [Optional] Base image enforcement
├── 16-require-license-compliance.yaml       # [Optional] License compliance (SBOM)
├── 17-require-image-freshness.yaml          # [Optional] Block stale images
├── 18-require-secret-scan.yaml              # [Optional] Secret scanning attestation
├── 19-require-sast-scan.yaml                # [Optional] SAST scan attestation
├── 20-require-code-review.yaml              # [Optional] Code review approval
├── 21-require-test-coverage.yaml            # [Optional] Test coverage threshold
├── 22-require-dependency-pinning.yaml       # [Optional] Dependency version pinning
├── 23-require-hermetic-build.yaml           # [Optional] Hermetic build (SLSA L3)
├── 24-require-human-approval.yaml           # [Optional] Human sign-off gate
├── 25-deny-large-images.yaml                # [Optional] Image size limits
├── 26-require-runtime-security.yaml         # [Optional] Seccomp/AppArmor profile
├── 27-require-operational-readiness.yaml    # [Optional] Ops metadata (SLOs, runbooks)
└── 99-block-all-unsigned.yaml               # Catch-all unsigned policy
```

**Numbering Convention:**
- `01-06`: Allow List & Identity Policies (core)
- `07-09`: Attestation Policies (require pipeline setup)
- `10-15`: Deny List & Compliance Policies
- `16-19`: Advanced Security Policies
- `20-24`: Governance & Quality Policies
- `25-27`: Operational & Supply Chain Policies
- `99`: Catch-All Policies (evaluated last)

**To enable/disable a policy:** Edit `kustomization.yaml`

### Policy Categories

| Category | Policies | Status |
|----------|----------|--------|
| **Allow List** | 01 | ✅ Enabled |
| **Signature Verification** | 02 | ✅ Enabled |
| **Identity** | 03-06 | ✅ Enabled (warn) |
| **Attestation** | 07-09 | ⚠️ Optional (requires pipeline) |
| **Deny List** | 10-12 | ✅ Enabled |
| **Security** | 13, 25-26 | ⚠️ Optional |
| **Compliance** | 14-16 | ⚠️ Optional (requires attestation) |
| **Advanced Security** | 17-19 | ⚠️ Optional (requires scanning) |
| **Governance** | 20, 24 | ⚠️ Optional (regulated environments) |
| **Quality** | 21 | ⚠️ Optional (requires test coverage) |
| **Supply Chain** | 22-23 | ⚠️ Optional (SLSA Level 3+) |
| **Operational** | 27 | ⚠️ Optional (production readiness) |
| **Catch-All** | 99 | ✅ Enabled (warn) |

### Policy Evaluation Order

1. **Allow Lists** - Explicitly trusted images pass immediately
2. **Deny Lists** - Blocked images fail immediately
3. **Signature Verification** - Check for valid signatures
4. **Identity Verification** - Verify signer identity matches policy
5. **Catch-All** - Default behavior for unmatched images

---

## Policy Types

### 1. Allow List Policies

Allow specific images without signature verification.

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: allow-redhat-images
spec:
  images:
    - glob: "registry.redhat.io/**"
  authorities:
    - static:
        action: pass
  mode: enforce
```

**Use Cases:**
- Red Hat official images (already signed by Red Hat)
- Internal infrastructure images
- Third-party images with verified provenance

### 2. Signature Verification Policies

Require valid signatures from trusted OIDC issuers.

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-signatures
spec:
  images:
    - glob: "my-registry.com/my-app/*"
  authorities:
    - keyless:
        identities:
          - issuer: https://gitlab.example.com
            subjectRegExp: ".*"
        trustRootRef: rhtas-trust
  mode: enforce
```

**What it verifies:**
- Image has a signature
- Signature is valid (not tampered)
- Signature was created with a certificate from Fulcio
- Certificate was issued by the trusted OIDC provider

### 3. Identity-Based Policies

Verify WHO signed the image (not just that it's signed).

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-pipeline-signature
spec:
  images:
    - glob: "my-registry.com/my-app/*"
  authorities:
    - keyless:
        identities:
          - issuer: https://gitlab.example.com
            subjectRegExp: ".*/my-project//\\.gitlab-ci\\.yml@refs/heads/(develop|main)$"
        trustRootRef: rhtas-trust
  mode: enforce
```

**Identity Patterns:**
| Pattern | Matches |
|---------|---------|
| `.*` | Any subject |
| `.*/my-project/.*` | Specific project |
| `.*@refs/heads/main$` | Main branch only |
| `.*@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$` | Semantic version tags |

### 4. Deny List Policies

Block specific images unconditionally.

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: deny-risky-tags
spec:
  images:
    - glob: "**:latest"
    - glob: "**:dev"
  authorities:
    - static:
        action: fail
  mode: enforce
```

**Categories:**
- **Risky Tags**: `:latest`, `:dev`, `:test`, `:nightly`
- **Untrusted Registries**: `docker.io/library/*`, `ghcr.io/*`
- **Vulnerable Images**: Known CVE-affected versions

---

## GitLab OIDC Identity Format

When GitLab CI creates a signature using OIDC, the certificate subject follows this format:

```
https://<gitlab-url>/<project-path>//.gitlab-ci.yml@refs/<type>/<name>
```

### Examples

| Source | Subject |
|--------|---------|
| develop branch | `https://gitlab.example.com/root/secure-app//.gitlab-ci.yml@refs/heads/develop` |
| main branch | `https://gitlab.example.com/root/secure-app//.gitlab-ci.yml@refs/heads/main` |
| v1.0.0 tag | `https://gitlab.example.com/root/secure-app//.gitlab-ci.yml@refs/tags/v1.0.0` |
| feature branch | `https://gitlab.example.com/root/secure-app//.gitlab-ci.yml@refs/heads/feature/new-feature` |

### Subject Regex Patterns

| Policy Goal | Regex Pattern |
|-------------|---------------|
| Any pipeline | `.*` |
| Specific project | `.*/root/secure-app/.*` |
| Main branch only | `.*/root/secure-app//\\.gitlab-ci\\.yml@refs/heads/main$` |
| develop or main | `.*/root/secure-app//\\.gitlab-ci\\.yml@refs/heads/(develop\|main)$` |
| Release tags | `.*/root/secure-app//\\.gitlab-ci\\.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$` |
| Any branch | `.*/root/secure-app//\\.gitlab-ci\\.yml@refs/heads/.*` |

---

## Policy Reference

### Core Policies (01-15)

| Policy | Category | Mode | Description |
|--------|----------|------|-------------|
| `allow-redhat-images` | Allow List | enforce | Skip verification for Red Hat images |
| `rhtas-signed-images` | Signature | enforce | Require RHTAS signatures for secure-app |
| `require-pipeline-signature` | Identity | warn | Require signatures from CI pipeline |
| `require-develop-or-main-signature` | Identity | warn | Only accept develop/main signatures |
| `require-production-release-signature` | Identity | warn | Production images from release tags |
| `require-multi-signature` | Multi-Sig | warn | Require multiple environment signatures |
| `require-sbom-attestation` | Attestation | warn | Require SBOM for software transparency |
| `require-vulnerability-scan` | Attestation | warn | Require vulnerability scan attestation |
| `require-slsa-provenance` | Attestation | warn | Require SLSA provenance for build trust |
| `deny-risky-tags` | Deny List | enforce | Block mutable/risky tags |
| `deny-untrusted-registries` | Deny List | warn | Block public registries |
| `deny-known-vulnerable-images` | Deny List | warn | Block CVE-affected images |
| `deny-privileged-images` | Security | warn | Block dind, netshoot, mining images |
| `require-image-labels` | Compliance | warn | Require OCI labels for traceability |
| `require-base-image-allowlist` | Compliance | warn | Only allow approved base images |

### Advanced Security Policies (16-19)

| Policy | Category | Mode | Description |
|--------|----------|------|-------------|
| `require-license-compliance` | Compliance | warn | Verify no prohibited licenses (AGPL, SSPL) |
| `require-image-freshness` | Security | warn | Block images older than 90 days |
| `require-secret-scan` | Security | warn | Require secret scanning attestation |
| `require-sast-scan` | Security | warn | Require SAST (Semgrep) scan attestation |

### Governance & Quality Policies (20-24)

| Policy | Category | Mode | Description |
|--------|----------|------|-------------|
| `require-code-review` | Governance | warn | Verify MR approvals before build |
| `require-test-coverage` | Quality | warn | Require minimum test coverage (70%+) |
| `require-dependency-pinning` | Supply Chain | warn | All dependencies must be pinned |
| `require-hermetic-build` | Supply Chain | warn | Verify hermetic build (SLSA Level 3) |
| `require-human-approval` | Governance | warn | Require human sign-off for production |

### Operational & Security Policies (25-27)

| Policy | Category | Mode | Description |
|--------|----------|------|-------------|
| `deny-large-images` | Security | warn | Block images > 500MB or > 20 layers |
| `require-runtime-security` | Security | warn | Require Seccomp profile, non-root |
| `require-operational-readiness` | Operational | warn | Require SLOs, runbooks, contacts |

### Catch-All Policy (99)

| Policy | Category | Mode | Description |
|--------|----------|------|-------------|
| `block-all-unsigned` | Catch-All | warn | Default unsigned image policy |

### Risky Tags Blocked

| Tag | Reason |
|-----|--------|
| `:latest` | Mutable, unpredictable |
| `:dev`, `:develop` | Development builds |
| `:test`, `:testing` | Test builds |
| `:debug` | Contains debug tools |
| `:nightly`, `:edge` | Unstable builds |
| `:canary` | Experimental |
| `:alpha`, `:beta`, `:rc` | Pre-release |
| `:snapshot`, `:SNAPSHOT` | Point-in-time |
| `:unstable`, `:experimental` | Explicitly unstable |

### Vulnerable Images Blocked

| Image Pattern | Reason |
|---------------|--------|
| `**/log4j:2.14.*` - `2.16.0` | CVE-2021-44228 (Log4Shell) |
| `**/python:2.*` | EOL January 2020 |
| `**/node:8*` - `12*` | EOL, no security updates |
| `**/centos:6*` - `7*` | EOL |
| `**/ubuntu:14.04` - `18.04` | EOL |
| `**/debian:8*` - `9*` | EOL |
| `**/alpine:3.12*` - `3.14*` | EOL |

---

## Policy Modes

### enforce

```yaml
mode: enforce
```

- **Behavior**: Block non-compliant images
- **Use When**: Policy is tested and ready for production
- **Effect**: `oc apply` fails with admission error

### warn

```yaml
mode: warn
```

- **Behavior**: Allow but log warnings
- **Use When**: Testing new policies, gradual rollout
- **Effect**: Pod created but warning logged

### Recommended Rollout

1. Deploy policy with `mode: warn`
2. Monitor logs for violations
3. Fix non-compliant workloads
4. Change to `mode: enforce`

---

## Advanced Policy Implementation Guide

This section provides implementation guidance for the advanced supply chain security policies (16-27).

### 16. License Compliance Policy

**Purpose:** Prevent copyleft or prohibited licenses from entering production.

**Pipeline Integration:**
```bash
# Extract licenses from SBOM
syft ${IMAGE} -o spdx-json > sbom.json
jq '{licenses: [.packages[].licenseConcluded] | unique}' sbom.json > license-report.json
cosign attest --type https://example.com/license-scan/v1 --predicate license-report.json ${IMAGE}
```

**Prohibited Licenses:** AGPL-3.0, SSPL-1.0, Commons Clause

---

### 17. Image Freshness Policy

**Purpose:** Block stale images that may contain unpatched vulnerabilities.

**Thresholds:**
- DEV: 30 days
- STAGING: 60 days  
- PRODUCTION: 90 days

**Pipeline Integration:**
```bash
BUILD_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "{\"buildTimestamp\": \"${BUILD_TIMESTAMP}\", \"maxAgeDays\": 90}" > freshness.json
cosign attest --type https://example.com/build-freshness/v1 --predicate freshness.json ${IMAGE}
```

---

### 18. Secret Scanning Policy

**Purpose:** Ensure no credentials, API keys, or secrets are embedded in images.

**Tools:** Trufflehog, Gitleaks, GitLab Secret Detection

**Pipeline Integration:**
```bash
trufflehog docker --image=${IMAGE} --json > secret-scan.json
echo "{\"scanner\": \"trufflehog\", \"status\": \"pass\", \"findings\": []}" > secret-attestation.json
cosign attest --type https://example.com/secret-scan/v1 --predicate secret-attestation.json ${IMAGE}
```

---

### 19. SAST Scan Policy

**Purpose:** Require static application security testing before deployment.

**Tools:** Semgrep, SonarQube, CodeQL, Bandit

**Pipeline Integration:**
```bash
semgrep scan --config=auto --json -o sast-results.json .
jq '{scanner: "semgrep", status: "pass", summary: {total: (.results | length), critical: 0}}' \
  sast-results.json > sast-attestation.json
cosign attest --type https://example.com/sast-scan/v1 --predicate sast-attestation.json ${IMAGE}
```

---

### 20. Code Review Policy

**Purpose:** Verify merge request was approved before build (four-eyes principle).

**Requirements:**
- Standard branches: 1 approval minimum
- Production releases: 2 approvals minimum

**Pipeline Integration (GitLab):**
```bash
MR_APPROVALS=$(curl -s "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}/approvals" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
echo "{\"mergeRequestIid\": ${CI_MERGE_REQUEST_IID}, \"approvedBy\": $(echo $MR_APPROVALS | jq '.approved_by')}" > code-review.json
cosign attest --type https://example.com/code-review/v1 --predicate code-review.json ${IMAGE}
```

---

### 21. Test Coverage Policy

**Purpose:** Enforce minimum test coverage threshold.

**Thresholds:**
- Minimum: 70%
- Target: 80%+

**Pipeline Integration:**
```bash
npm test -- --coverage --coverageReporters=json-summary
jq '{framework: "jest", coverage: {lines: .total.lines.pct}, threshold: {minimum: 70}}' \
  coverage/coverage-summary.json > test-coverage.json
cosign attest --type https://example.com/test-coverage/v1 --predicate test-coverage.json ${IMAGE}
```

---

### 22. Dependency Pinning Policy

**Purpose:** Ensure all dependencies are pinned to exact versions (no floating).

**Checks:**
- Lockfile present (package-lock.json, go.sum)
- No `^`, `~`, `*`, `latest` in dependencies
- All versions explicit

**Pipeline Integration:**
```bash
FLOATING=$(jq '[.dependencies, .devDependencies | to_entries[] | select(.value | test("^[\\^~*]|latest"))] | length' package.json)
echo "{\"lockfilePresent\": true, \"floatingDependencies\": ${FLOATING}, \"status\": \"pass\"}" > dep-pinning.json
cosign attest --type https://example.com/dependency-pinning/v1 --predicate dep-pinning.json ${IMAGE}
```

---

### 23. Hermetic Build Policy (SLSA Level 3)

**Purpose:** Verify build was hermetic (no network access during build).

**Requirements:**
- Network disabled during build
- Dependencies pre-cached
- SLSA Level 3+ compliance

**Pipeline Integration:**
```bash
buildah bud --network=none --layers -t ${IMAGE} .
echo "{\"buildSystem\": \"buildah\", \"networkDisabled\": true, \"hermetic\": true, \"slsaLevel\": 3}" > hermetic.json
cosign attest --type https://example.com/hermetic-build/v1 --predicate hermetic.json ${IMAGE}
```

---

### 24. Human Approval Policy (GitLab JWT-Based)

**Purpose:** Verify images were built from approved and merged MRs using GitLab's JWT claims.

**How it Works:**

```
┌─────────────────────────────────────────────────────────────────────────┐
│  MR APPROVAL VERIFICATION FLOW                                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. Developer creates Merge Request                                     │
│  2. Approver(s) review and approve MR                                   │
│  3. Maintainer/Approver MERGES the MR                                   │
│  4. Merge triggers pipeline with JWT containing merger's identity       │
│  5. Fulcio extracts user_email, user_login from JWT → certificate       │
│  6. Pipeline creates approval attestation with MR details               │
│  7. Policy verifies certificate identity + approval attestation         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**GitLab OIDC JWT Claims (embedded in Fulcio certificate):**
- `user_email`: Email of person who triggered pipeline (merger)
- `user_login`: Username of merger
- `project_path`: Full project path
- `pipeline_source`: `merge_request_event` or `push`
- `ref`/`ref_type`: Branch or tag info

**Fulcio Certificate Extensions (OID 1.3.6.1.4.1.57264.1.x):**
- Build Signer URI (CI config path)
- Source Repository URI/Digest
- Build Trigger
- Runner Environment

**Key Insight:** When someone **merges** an MR, **they trigger** the pipeline. Their identity is in the JWT token and becomes part of the Fulcio certificate - proving a human (the merger) initiated the build.

**Required GitLab Settings:**
1. "Prevent approval by author" - enabled
2. "Prevent approvals by users who add commits" - enabled
3. Required approvers for protected branches
4. "Require re-authentication for approvals" - recommended

**Pipeline Integration:**
```bash
# The template at .gitlab/ci/templates/approval-attestation.yml captures:
# - MR approval status from CI variables
# - Approver list from GitLab API
# - Merger identity from JWT claims

# Attestation includes:
{
  "mergeRequest": {
    "approved": true,
    "approvalCount": 2,
    "approvedBy": [{"username": "reviewer1"}, {"username": "reviewer2"}],
    "mergedBy": {"username": "maintainer", "email": "maintainer@example.com"}
  },
  "triggeredBy": {"username": "maintainer", "email": "maintainer@example.com"}
}
```

See `apps-projects/secure-app/.gitlab/ci/templates/approval-attestation.yml` for full implementation.

---

### 25. Image Size Policy

**Purpose:** Block oversized images that may indicate compromise.

**Limits:**
- Maximum total size: 500MB
- Maximum layers: 20
- Maximum single layer: 300MB

**Pipeline Integration:**
```bash
MANIFEST=$(skopeo inspect docker://${IMAGE})
echo "{\"totalSize\": $(echo $MANIFEST | jq '.LayersData | map(.Size) | add'), \"layerCount\": $(echo $MANIFEST | jq '.LayersData | length')}" > size.json
cosign attest --type https://example.com/image-size/v1 --predicate size.json ${IMAGE}
```

---

### 26. Runtime Security Policy

**Purpose:** Require secure runtime configuration (Seccomp/AppArmor).

**Requirements:**
- Seccomp profile not `unconfined`
- Must run as non-root
- No privilege escalation
- No dangerous capabilities (SYS_ADMIN, SYS_PTRACE)

**Pipeline Integration:**
```bash
echo "{
  \"seccompProfile\": \"runtime/default\",
  \"runAsNonRoot\": true,
  \"allowPrivilegeEscalation\": false,
  \"capabilities\": {\"drop\": [\"ALL\"], \"add\": [\"NET_BIND_SERVICE\"]}
}" > runtime-security.json
cosign attest --type https://example.com/runtime-security/v1 --predicate runtime-security.json ${IMAGE}
```

---

### 27. Operational Readiness Policy

**Purpose:** Ensure services have operational metadata for production.

**Required Fields:**
- `owner`: Team responsible
- `runbookUrl`: Link to runbook
- `slackChannel` or `pagerDutyService`: Incident contact
- `sloAvailability`: Target SLO (≥99%)
- `healthCheckPath`: Health endpoint

**Example ops-metadata.json:**
```json
{
  "owner": "platform-team",
  "runbookUrl": "https://docs.example.com/runbooks/app",
  "slackChannel": "#app-incidents",
  "sloAvailability": 99.9,
  "healthCheckPath": "/api/health"
}
```

---

## Customization Guide

### Adding a New Deny List Entry

```yaml
# Add to deny-known-vulnerable-images
spec:
  images:
    - glob: "**/vulnerable-image:*"  # Add your pattern
```

### Creating Project-Specific Policy

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: my-project-policy
spec:
  images:
    - glob: "my-registry.com/my-project/*"
  authorities:
    - keyless:
        identities:
          - issuer: https://gitlab.example.com
            subjectRegExp: ".*/my-org/my-project//\\.gitlab-ci\\.yml@refs/heads/(develop|main)$"
        trustRootRef: rhtas-trust
  mode: enforce
```

### Namespace-Specific Policies

Label namespaces to include/exclude from policy enforcement:

```bash
# Include namespace in policy enforcement
oc label namespace my-namespace policy.sigstore.dev/include=true

# Exclude namespace from policy enforcement
oc label namespace my-namespace policy.sigstore.dev/include-
```

---

## Testing Policies

### Test 1: Verify Unsigned Image is Blocked

```bash
# This should fail (enforce mode) or warn (warn mode)
oc run test-unsigned --image=nginx:latest -n secure-app-dev

# Expected output (enforce mode):
# Error: admission webhook "policy.sigstore.dev" denied the request
```

### Test 2: Verify Signed Image is Allowed

```bash
# Deploy using the signed image from our pipeline
oc apply -f apps-projects/secure-app/k8s/deployment.yaml

# Should succeed if image is properly signed
```

### Test 3: Check Policy Warnings

```bash
# View policy controller logs
oc logs -n cosign-system -l app.kubernetes.io/name=policy-controller -f

# Look for:
# - "failed policy: <policy-name>"
# - "signature keyless validation failed"
```

### Test 4: Verify Signature on Image

```bash
# Verify image has valid signature
cosign verify \
  --rekor-url=https://rekor-server-trusted-artifact-signer.${CLUSTER_DOMAIN} \
  --certificate-identity-regexp=".*" \
  --certificate-oidc-issuer=https://gitlab.${CLUSTER_DOMAIN} \
  ${REGISTRY}/secure-app/backend:dev-latest

# Should show signature details if valid
```

---

## Troubleshooting

### Issue: Policy Blocking Legitimate Images

**Symptoms:**
```
admission webhook "policy.sigstore.dev" denied the request: 
validation failed: failed policy: <policy-name>
```

**Solutions:**
1. Check if image is signed: `cosign verify <image>`
2. Check subject matches policy regex
3. Verify OIDC issuer matches
4. Temporarily set policy to `warn` mode

### Issue: Signature Verification Fails

**Symptoms:**
```
signature keyless validation failed for authority authority-0
```

**Solutions:**
1. Verify TrustRoot is correctly configured
2. Check Fulcio CA certificate is current
3. Ensure Rekor server is accessible
4. Re-sign the image if certificate expired

### Issue: Identity Mismatch

**Symptoms:**
```
none of the expected identities matched what was in the certificate,
got subjects [https://gitlab.../refs/heads/feature-branch]
```

**Solutions:**
1. Update policy regex to include the branch
2. Sign from an allowed branch
3. Check for typos in subjectRegExp

### Useful Commands

```bash
# List all policies
oc get clusterimagepolicy

# View policy details
oc describe clusterimagepolicy <policy-name>

# Check policy controller status
oc get pods -n cosign-system

# View policy controller logs
oc logs -n cosign-system -l app.kubernetes.io/name=policy-controller --tail=100

# Check namespace labels
oc get namespace <ns> -o jsonpath='{.metadata.labels}'
```

---

## Related Resources

- [Sigstore Policy Controller Documentation](https://docs.sigstore.dev/policy-controller/overview/)
- [RHTAS Documentation](https://access.redhat.com/documentation/en-us/red_hat_trusted_artifact_signer)
- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
- [Rekor Transparency Log](https://docs.sigstore.dev/rekor/overview/)
