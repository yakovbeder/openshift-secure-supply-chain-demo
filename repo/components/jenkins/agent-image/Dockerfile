FROM image-registry.openshift-image-registry.svc:5000/openshift/jenkins-agent-base:latest

USER root

ARG RHTAS_CLI_SERVER="https://cli-server-trusted-artifact-signer.apps.__CLUSTER_DOMAIN__"

# npm (jq, python3, openssl, git, oc already in base image)
RUN dnf install -y --nodocs --nobest --skip-broken npm 2>/dev/null; \
    dnf clean all && rm -rf /var/cache/dnf

# cosign + rekor-cli from RHTAS CLI server (cluster-local)
RUN curl -skL "${RHTAS_CLI_SERVER}/clients/linux/cosign-amd64.gz" | gunzip > /usr/local/bin/cosign \
    && chmod +x /usr/local/bin/cosign \
    && curl -skL "${RHTAS_CLI_SERVER}/clients/linux/rekor-cli-amd64.gz" | gunzip > /usr/local/bin/rekor-cli \
    && chmod +x /usr/local/bin/rekor-cli \
    && curl -skL "${RHTAS_CLI_SERVER}/clients/linux/ec-amd64.gz" | gunzip > /usr/local/bin/ec \
    && chmod +x /usr/local/bin/ec

# syft (SBOM generator)
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin

# trivy (vulnerability scanner)
RUN curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

# kube-linter
RUN curl -sL "https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux" -o /usr/local/bin/kube-linter \
    && chmod +x /usr/local/bin/kube-linter

# roxctl is downloaded at runtime in the Jenkinsfile using the ACS API token
# (requires authentication, so it cannot be baked into the image at build time)

USER 1001
