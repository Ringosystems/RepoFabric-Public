# RepoFabric Sandbox wizard image.
#
# A thin tools image co-located with the Docker daemon. It mounts the Docker
# socket and the repo at runtime and orchestrates the whole sandbox: build,
# certificate generation, NPM/Gitea seeding, and the prove-it validations. The
# only host prerequisite is therefore Docker Engine plus socket access; this
# image supplies compose, buildx, openssl, curl, and jq.
# Float on the latest docker CLI tag rather than a pinned major (was
# docker:27-cli). docker:cli is alpine-based and bundles the docker CLI plus the
# Go-compiled docker/buildkit/containerd binaries, which are a recurring source
# of HIGH/CRITICAL CVEs that only newer base images carry the fixes for. The
# wizard is throwaway build tooling, so patch freshness beats pin
# reproducibility here. See sandbox/versions.lock.env for the same float-on-latest
# posture across the bundled stack.
ARG WIZARD_BASE_IMAGE=docker:cli
FROM ${WIZARD_BASE_IMAGE}

# apk upgrade pulls the latest alpine package patches (git, musl, zlib, expat,
# nghttp2, ...) on every build, the same posture as linux/Dockerfile's
# apt-get dist-upgrade, so the wizard never ships whatever CVEs accrued since the
# base tag was cut. Then add the compose and buildx plugins explicitly (so a slim
# base still works) plus the shell tooling the wizard and seed scripts rely on.
RUN apk upgrade --no-cache && \
    apk add --no-cache \
        bash curl openssl jq coreutils ca-certificates \
        docker-cli-compose docker-cli-buildx

COPY wizard-entrypoint.sh /usr/local/bin/wizard-entrypoint.sh
RUN chmod 0755 /usr/local/bin/wizard-entrypoint.sh

WORKDIR /repo/sandbox
ENTRYPOINT ["/usr/local/bin/wizard-entrypoint.sh"]
