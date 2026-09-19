# A reproducible Linux toolchain for contributors whose platform has no native
# MoonBit binary, and for reproducing a CI failure locally.
#
#   docker build -t moon-schema-plan-dev -f .devcontainer/Dockerfile .
#   docker run --rm -v "$PWD:/workspace" moon-schema-plan-dev moon test --deny-warn
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        ca-certificates \
        curl \
        gcc \
        git \
        libc6-dev \
        sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# The native backend compiles through C, so gcc above is required for
# `moon test --target native` as well as for the CLI's file-system stub.
RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
ENV PATH="/root/.moon/bin:${PATH}"

WORKDIR /workspace
CMD ["moon", "test", "--deny-warn"]
