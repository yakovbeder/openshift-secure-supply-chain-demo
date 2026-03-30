# CI Checks

This repository's GitHub Actions CI lives in `.github/workflows/ci.yaml`.
It runs on pull requests and on pushes to `main`.

The current pipeline is a validation and linting pipeline. It does not yet run application unit tests, integration tests, or end-to-end deployment smoke tests.

## Implemented Checks

| Job | What it verifies | Current scope |
|-----|------------------|---------------|
| `ShellCheck` | Shell script correctness and common Bash pitfalls | `spin-demo.sh`, `cleanup.sh`, `check-status.sh` |
| `yamllint` | YAML syntax, formatting, and style rules | Entire repository using `.yamllint.yml` |
| `kubeconform` | Kubernetes manifest schema validation | `repo/components`, `repo/apps-projects/secure-app/k8s`, `repo/apps-projects/secure-app/.tekton`, `repo/argocd` |
| `kustomize build` | Kustomize overlays render successfully | All listed component and app overlay directories in `ci.yaml` |
| `Hadolint` | Dockerfile linting and container build best practices | Jenkins agent image plus secure-app frontend and backend Dockerfiles |
| `markdownlint` | Markdown formatting and style consistency | All `*.md` files using `.markdownlint-cli2.jsonc` |

## Notes

- `Hadolint` is configured with `failure-threshold: error`, so warnings are reported but do not fail CI.
- `kustomize build` uses `--enable-helm` because the Sealed Secrets component relies on Helm chart inflation.
- For exact commands and directory lists, use `.github/workflows/ci.yaml` as the source of truth.
