# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-03-23

### Added

- One-command deployment via `spin-demo.sh` — deploys 10 components from a single `oc login`
- Full cleanup via `cleanup.sh` with force-remove for stuck namespaces
- Health check script `check-status.sh`
- ArgoCD ApplicationSet with matrix generator for component management
- Jenkins pipeline with OIDC keyless signing via RHTAS/Fulcio
- 12 active Sigstore admission policies covering signatures, SBOM, vulnerability scans, and ACS checks
- Additional 15+ disabled policies ready for advanced scenarios (SLSA provenance, compliance, ML pipelines)
- Branch-based environment routing: develop → DEV, main → STAGING, release/* → PROD
- Multi-signature chain policy for production deployments
- Pilot application (`secure-app`) with Node.js backend and Nginx frontend
- Comprehensive architecture documentation in `ARCHITECTURE.md`
- Variable-driven configuration with `__CLUSTER_DOMAIN__` placeholders — no hardcoded domains
- Progress bar in deployment script
- Idempotent re-runs: cleanup + spin-demo cycle works reliably
