#!/usr/bin/env bash
# AteKit's tests on Linux, for cloud agent containers that have Docker but no Swift.
# Usage: scripts/test-linux.sh [swift test args, e.g. --filter FeedStore]
# First run pulls swift:6.2-noble (~1 GB) and builds the dependencies (a few minutes); after that a
# change rebuilds in ~15s and the whole suite runs in ~4s. Build products live in AteKit/.build-linux
# so they never mix with a Mac's AteKit/.build.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
image="swift:6.2-noble"

if ! docker info >/dev/null 2>&1; then
  (sudo -n dockerd >/tmp/dockerd.log 2>&1 || dockerd >/tmp/dockerd.log 2>&1) &
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null

# Cloud containers reach the network through a proxy with its own CA; pass both through when set.
extra=()
for ca in /root/.ccr/ca-bundle.crt "${SSL_CERT_FILE:-}"; do
  if [ -n "$ca" ] && [ -f "$ca" ]; then
    extra+=(-v "$ca:/proxy-ca.crt:ro" -e GIT_SSL_CAINFO=/proxy-ca.crt -e SSL_CERT_FILE=/proxy-ca.crt)
    break
  fi
done
for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy; do
  [ -n "${!v:-}" ] && extra+=(-e "$v=${!v}")
done

exec docker run --rm --network host -v "$repo:/ate" -w /ate "${extra[@]}" "$image" \
  swift test --package-path AteKit --scratch-path AteKit/.build-linux "$@"
