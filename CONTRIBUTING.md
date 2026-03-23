# Contributing

Thank you for your interest in contributing to this project. All contributions — bug reports, feature requests, documentation improvements, and code changes — are appreciated.

## How to Contribute

### Reporting Issues

Open a [GitHub Issue](../../issues/new) with:

- A clear, descriptive title
- Steps to reproduce (for bugs)
- Expected vs. actual behavior
- OpenShift version and cluster details (if relevant)

### Submitting Changes

1. **Fork** the repository
2. **Create a branch** from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **Make your changes** — keep commits focused and atomic
4. **Test** your changes on an OpenShift cluster:
   ```bash
   ./cleanup.sh --yes && ./spin-demo.sh
   ```
5. **Push** and open a Pull Request against `main`

### Pull Request Guidelines

- Reference any related issue (`Fixes #123`)
- Describe what changed and why
- Ensure `spin-demo.sh` completes successfully on a clean cluster
- Ensure `cleanup.sh --yes && spin-demo.sh` works (idempotent re-run)
- Keep diffs minimal — don't reformat unrelated code

## Project Conventions

### Manifests

- All Kubernetes manifests use **Kustomize** (no Helm)
- Cluster-specific values use `__CLUSTER_DOMAIN__` placeholder — `spin-demo.sh` replaces them at deploy time
- Deployment order is controlled via `argocd.argoproj.io/sync-wave` annotations
- Components are self-contained in `repo/components/<name>/` with their own `kustomization.yaml`

### Scripts

- Bash with `set -euo pipefail`
- All `oc` and `curl` calls must handle errors gracefully (retry or `|| true`)
- No hardcoded cluster domains — always use `__CLUSTER_DOMAIN__` in source files

### Adding a New Component

1. Create `repo/components/<name>/kustomization.yaml` with the required manifests
2. Add the component name to `repo/config/enabled-components.yaml`
3. Set an appropriate `sync-wave` annotation based on dependencies
4. Update `ARCHITECTURE.md` with the component's role and configuration

### Adding a New Sigstore Policy

1. Create a numbered YAML in `repo/components/sigstore-policy-controller/policies/`
2. Follow the naming convention: `NN-policy-description.yaml`
3. Reference the policy in `repo/components/sigstore-policy-controller/kustomization.yaml`
4. Document the policy in the ARCHITECTURE.md policies table

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold this code.
