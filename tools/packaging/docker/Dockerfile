# Pyking's Docker images, for one architecture, made from that
# architecture's Linux package (its tarball, copied into the build context
# as pyking.tar.gz) by tools/packaging/packaging.py (Docker.build). Two
# targets:
#
#   slim  pyk and its tree on Debian: programs, the REPL, the notebook,
#         the playground, the help and the language server.
#   full  the same, with every target's host -- Python 3.14, node 24, gcc,
#         a JDK and the OCaml pyk was built by -- so `pyk compile --run`
#         runs every target, and a program's own external module compiles
#         its plugin.
#
# The OCaml is copied from the Linux build image (OCAML_IMAGE), whose
# compiler built this `pyk`, at the path it was installed at, and reached
# through the `ocamlopt` beside this file (copied into the context too),
# which links an executable the way that OCaml's runtime needs.

ARG OCAML_IMAGE=scratch
ARG DEBIAN=debian:13-slim
ARG PYTHON=python:3.14-slim-trixie

FROM ${OCAML_IMAGE} AS ocaml

FROM ${DEBIAN} AS slim
ARG VERSION
LABEL org.opencontainers.image.title="Pyking" \
      org.opencontainers.image.description="Compiler and interpreter for Pyking, a small statically typed Python-like language" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/pyking-lang/pyking-releases"
# ADD unpacks the tarball. The tree stays together: pyk finds lib/, build/
# and tools/ beside its own resolved path.
ADD pyking.tar.gz /opt/
RUN mv "/opt/pyking-${VERSION}" /opt/pyking \
 && ln -s /opt/pyking/pyk /usr/local/bin/pyk
# A container's 127.0.0.1 cannot be reached from outside it, so the web
# tools listen on every interface. The cache is where a plugin is compiled
# to, writable whatever --user a container runs as.
ENV PYKING_WEB_HOST=0.0.0.0 XDG_CACHE_HOME=/tmp/.cache
WORKDIR /work
ENTRYPOINT ["pyk"]
CMD ["repl"]

FROM ${PYTHON} AS full
ARG VERSION
ARG TARGETARCH
ARG NODE_VERSION
ARG NODE_SHA256_AMD64
ARG NODE_SHA256_ARM64
LABEL org.opencontainers.image.title="Pyking (full)" \
      org.opencontainers.image.description="Pyking with every target's host: Python, node, gcc, a JDK and OCaml" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/pyking-lang/pyking-releases"
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev default-jdk-headless \
      curl ca-certificates xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN case "$TARGETARCH" in \
      amd64) arch=x64 sum="$NODE_SHA256_AMD64" ;; \
      arm64) arch=arm64 sum="$NODE_SHA256_ARM64" ;; \
      *) echo "no node for $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
 && echo "${sum}  /tmp/node.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
      --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md \
 && rm /tmp/node.tar.xz
COPY --from=ocaml /opt/opam/release/bin /opt/opam/release/bin
COPY --from=ocaml /opt/opam/release/lib/ocaml /opt/opam/release/lib/ocaml
COPY --chmod=755 ocamlopt /usr/local/bin/ocamlopt
COPY --from=slim /opt/pyking /opt/pyking
RUN ln -s /opt/pyking/pyk /usr/local/bin/pyk
ENV PATH=$PATH:/opt/opam/release/bin \
    PYKING_WEB_HOST=0.0.0.0 XDG_CACHE_HOME=/tmp/.cache
WORKDIR /work
ENTRYPOINT ["pyk"]
CMD ["repl"]
