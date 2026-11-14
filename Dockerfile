# Multi-stage build for zigpod
# Alpine 3.21 community is the first Alpine release shipping zig 0.13.0,
# matching build.zig.zon minimum_zig_version (Alpine 3.20 only has zig 0.12.0).
FROM alpine:3.21 AS builder

RUN apk add --no-cache zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

RUN zig build -Doptimize=ReleaseSafe

FROM alpine:3.21

COPY --from=builder /src/zig-out/bin/zigpod /usr/local/bin/zigpod

ENTRYPOINT ["/usr/local/bin/zigpod"]
CMD ["--help"]
