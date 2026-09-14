# goose runtime for a team agent (plan 12, opt-in). Debian base + the pinned goose release + the sprig binaries
# (musl static-PIE; verified to run on glibc). The only image this repository builds.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171
ARG GOOSE_VERSION=1.50.0
ARG GOOSE_SHA256=8b5dfae07d16e352fbabe3122339a9270ea30e3b29246c81d6a227ed5f35e904
RUN apt-get update && apt-get install -y --no-install-recommends bash git curl ca-certificates bzip2 procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -d /home/agent -s /bin/bash agent
ADD https://github.com/block/goose/releases/download/v${GOOSE_VERSION}/goose-x86_64-unknown-linux-gnu.tar.bz2 /tmp/goose.tar.bz2
RUN echo "${GOOSE_SHA256}  /tmp/goose.tar.bz2" | sha256sum -c - && tar -xjf /tmp/goose.tar.bz2 -C /usr/local/bin ./goose && rm /tmp/goose.tar.bz2 \
    && chmod 0755 /usr/local/bin/goose
COPY --from=ghcr.io/block/buzz-sprig:sha-e17cdd9 /usr/local/bin/sprig /usr/local/bin/sprig
COPY --from=ghcr.io/block/buzz-sprig:sha-e17cdd9 /usr/local/bin/sprig-entrypoint /usr/local/bin/sprig-entrypoint
RUN for b in buzz buzz-acp buzz-agent buzz-dev-mcp git-credential-nostr git-sign-nostr rg; do ln -s /usr/local/bin/sprig /usr/local/bin/$b; done
USER agent
WORKDIR /home/agent
