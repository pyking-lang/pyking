# The build environment for Pyking's Linux packages: Alpine, so the C
# library is musl and `pyk` can be linked fully static, and an opam switch
# holding OCaml and dune. Built once per architecture by
# `make packaging-setup` (tools/packaging/packaging.py, Linux.setup);
# the image's tag carries a hash of this file, so editing it makes the
# next setup build a new one.
FROM alpine:3.22

RUN apk add --no-cache build-base opam git m4 bash curl patch unzip rsync

ARG OCAML_VERSION=5.5.0
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
