#!/usr/bin/env bash
set -euo pipefail

ZIGPOD="${ZIGPOD:-zigpod}"
IMAGE="${IMAGE:-alpine:3.20}"
NAME="zigpod-demo-$$"

echo "1. Pulling image: ${IMAGE}"
"$ZIGPOD" pull "$IMAGE"

echo "2. Running detached container: ${NAME}"
"$ZIGPOD" run -d --name "$NAME" "$IMAGE" sh -c "echo 'Hello from zigpod demo!'; sleep 1"

echo "3. Listing containers (ps -a):"
"$ZIGPOD" ps -a

echo "4. Fetching container logs:"
"$ZIGPOD" logs "$NAME"

echo "5. Removing demo container:"
"$ZIGPOD" rm -f "$NAME"
