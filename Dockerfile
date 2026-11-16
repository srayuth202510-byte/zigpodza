# Multi-stage build for zigpod
# build.zig.zon requires Zig >= 0.17.1; rather than depend on what Alpine packages,
# the builder pins the official static toolchain and verifies its SHA-256.
FROM alpine:3.21 AS builder

ARG ZIG_VERSION=0.17.1
ARG ZIG_SHA256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
RUN apk add --no-cache curl xz \
    && curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

RUN zig build -Doptimize=ReleaseSafe

FROM alpine:3.21

COPY --from=builder /src/zig-out/bin/zigpod /usr/local/bin/zigpod

ENTRYPOINT ["/usr/local/bin/zigpod"]
CMD ["--help"]
