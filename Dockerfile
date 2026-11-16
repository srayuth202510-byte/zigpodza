# Multi-stage build for zigpod
# build.zig.zon requires Zig >= 0.17.1; rather than depend on what Alpine packages,
# the builder pins the official static toolchain and verifies its SHA-256.
FROM alpine:3.21 AS builder

ARG ZIG_VERSION=0.17.1
ARG ZIG_SHA256_X86_64=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
ARG ZIG_SHA256_AARCH64=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
# Pick the toolchain matching the build platform (x86_64 or aarch64) and fail
# closed on any other architecture.
RUN set -eu; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)  sha="${ZIG_SHA256_X86_64}" ;; \
        aarch64) sha="${ZIG_SHA256_AARCH64}" ;; \
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    apk add --no-cache curl xz; \
    curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"; \
    echo "${sha}  /tmp/zig.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/zig.tar.xz -C /opt; \
    ln -s "/opt/zig-${arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

RUN zig build -Doptimize=ReleaseSafe

FROM alpine:3.21

COPY --from=builder /src/zig-out/bin/zigpod /usr/local/bin/zigpod

ENTRYPOINT ["/usr/local/bin/zigpod"]
CMD ["--help"]
