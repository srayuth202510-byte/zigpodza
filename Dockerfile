# Multi-stage build for zigpod
FROM alpine:3.20 AS builder

RUN apk add --no-cache zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

RUN zig build -Doptimize=ReleaseSafe

FROM alpine:3.20

COPY --from=builder /src/zig-out/bin/zigpod /usr/local/bin/zigpod

ENTRYPOINT ["/usr/local/bin/zigpod"]
CMD ["--help"]
