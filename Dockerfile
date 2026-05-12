FROM ubuntu:24.04

# Pinned grpcurl version — update the SHA when bumping the version.
# To regenerate: run the build, then sha256sum /usr/local/bin/grpcurl
ARG GRPCURL_VERSION=1.9.3
ARG TARGETARCH

# Install runtime dependencies.
# util-linux  → fstrim
# cryptsetup  → luksDump, token export, refresh
# dmsetup     → table queries
# nsenter     → enter host mount namespace for fstrim
# jq          → JSON parsing in trim.sh and coordinator
# curl        → Kubernetes API calls in both scripts
# ca-certificates → TLS for Kubernetes API + KMS endpoint
RUN apt-get update && apt-get install -y --no-install-recommends \
      util-linux \
      cryptsetup \
      dmsetup \
      jq \
      curl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install grpcurl from the GitHub release.
# The sha256 file is fetched alongside the binary so the checksum is always
# consistent with the version above — no hardcoded digest to forget to update.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64)   GA=x86_64  ;; \
      arm64)   GA=arm64   ;; \
      *)       echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    TAR="grpcurl_${GRPCURL_VERSION}_linux_${GA}.tar.gz"; \
    BASE_URL="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}"; \
    curl -fsSL "${BASE_URL}/${TAR}"          -o /tmp/grpcurl.tar.gz; \
    curl -fsSL "${BASE_URL}/checksums.txt"   -o /tmp/checksums.txt; \
    grep "${TAR}" /tmp/checksums.txt | sha256sum -c -; \
    tar -xz -C /usr/local/bin -f /tmp/grpcurl.tar.gz grpcurl; \
    chmod +x /usr/local/bin/grpcurl; \
    rm -f /tmp/grpcurl.tar.gz /tmp/checksums.txt; \
    grpcurl --version

# Smoke-test that all required binaries are present and executable.
RUN fstrim --version && \
    cryptsetup --version && \
    dmsetup --version && \
    jq --version && \
    curl --version && \
    grpcurl --version

USER root
