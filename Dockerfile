# SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
# SPDX-License-Identifier: Apache-2.0
#
# Pinned proof environment for vosken-certified-samples.
#
# Base: debian:bookworm-slim plus the YosysHQ oss-cad-suite dated release
# below. The suite ships every tool the proofs need: sby (SymbiYosys), yosys
# with the yosys-slang frontend plugin, the z3 and bitwuzla SMT solvers, and
# yosys-abc (the abc pdr engine). Exact tool versions are recorded in
# ENVIRONMENT.txt; reproduce.sh compares against them at run time.
#
# Build:  docker build -t vosken-certified-samples .
# Run:    ./reproduce.sh          (builds and runs this image for you)

FROM debian:bookworm-slim

# Dated oss-cad-suite release. Changing this date changes the toolchain and
# voids the "certified reproduction" claim until ENVIRONMENT.txt is re-pinned.
ARG OSS_CAD_SUITE_DATE=2026-06-25
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl make \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) OSS_ARCH=x64 ;; \
        arm64) OSS_ARCH=arm64 ;; \
        *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    STAMP="$(echo "${OSS_CAD_SUITE_DATE}" | tr -d '-')"; \
    curl -fL -o /tmp/oss-cad-suite.tgz \
        "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_SUITE_DATE}/oss-cad-suite-linux-${OSS_ARCH}-${STAMP}.tgz"; \
    tar -xzf /tmp/oss-cad-suite.tgz -C /opt; \
    rm /tmp/oss-cad-suite.tgz

ENV PATH="/opt/oss-cad-suite/bin:${PATH}"

WORKDIR /work
CMD ["/bin/bash"]
