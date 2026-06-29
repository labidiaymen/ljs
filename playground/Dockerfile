# Lumen playground compile service.
#
# Builds the `lumen` compiler from the repo plus the compile service, then serves
# POST /compile (returns the compiled .wasm) and GET /health. The service only
# compiles source; it never runs user code. The build context is the REPO ROOT
# (so src/ + build.zig are available):
#
#   docker build -f playground/Dockerfile -t lumen-playground .
FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends curl xz-utils ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Lumen toolchain. The image arch follows the build platform (TARGETARCH is set
# by BuildKit): Fly builds amd64, a local machine may build arm64.
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) ZA=x86_64 ;; \
      arm64) ZA=aarch64 ;; \
      *) echo "unsupported arch: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/0.16.0/zig-${ZA}-linux-0.16.0.tar.xz" | tar -xJ -C /opt; \
    mv /opt/zig-* /opt/zig

# `lumen` invokes the toolchain by name at runtime, so it must stay on PATH.
# `/app` holds the built compiler and service.
ENV PATH=/opt/zig:/app:$PATH

WORKDIR /build
COPY . /build

# Build the compiler and the compile service.
RUN zig build -Dcpu=baseline \
  && mkdir -p /app \
  && cp zig-out/bin/lumen /app/lumen \
  && zig build-exe playground/server.zig -O ReleaseSafe -mcpu=baseline -femit-bin=/app/server

WORKDIR /app
ENV PORT=8080
EXPOSE 8080
CMD ["/app/server"]
