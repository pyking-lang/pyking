# The build environment for Pyking's Linux packages: AlmaLinux 8, whose
# glibc (2.28) is old enough that a `pyk` linked against it runs on every
# current distribution -- the floor Python's manylinux_2_28 wheels share --
# and an opam switch holding OCaml and dune. `pyk`
# is linked dynamically because the interpreter loads library plugins,
# which a static binary cannot (tools/packaging/README.md). Built once per
# architecture by `make packaging-setup` (tools/packaging/packaging.py,
# Linux.setup); the image's tag carries a hash of this file, so editing it
# makes the next setup build a new one.
FROM almalinux:8

RUN dnf install -y gcc gcc-c++ make git m4 patch unzip rsync diffutils bzip2 \
      which tar findutils \
 && dnf clean all

ARG OCAML_VERSION=5.5.0
ARG OPAM_VERSION=2.3.0
# Set by Docker to the platform being built for: amd64 or arm64.
ARG TARGETARCH

# opam's own binary, which the distribution does not package.
RUN case "$TARGETARCH" in amd64) arch=x86_64 ;; *) arch="$TARGETARCH" ;; esac \
 && curl -fsSL -o /usr/local/bin/opam \
      "https://github.com/ocaml/opam/releases/download/$OPAM_VERSION/opam-$OPAM_VERSION-$arch-linux" \
 && chmod +x /usr/local/bin/opam

ENV OPAMROOT=/opt/opam OPAMYES=1 OPAMROOTISOK=1 OPAMCOLOR=never

# Readable by any user, since builds run as the caller's own uid so that
# what they write into the mounted repository is the caller's.
RUN opam init --bare --disable-sandboxing --no-setup \
 && opam switch create release "$OCAML_VERSION" \
 && opam install --switch release dune \
 && opam clean --all-switches --download-cache --logs --repo-cache \
 && chmod -R a+rX /opt/opam

ENV PATH=/opt/opam/release/bin:$PATH HOME=/tmp
WORKDIR /src
