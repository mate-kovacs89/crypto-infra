#!/usr/bin/env bash
# Build a deployment zip for the healthz-monitor Lambda.
#
# Node.js 22 Lambda runtime bundles AWS SDK v3, so we do NOT package
# node_modules — the zip contains only index.mjs + package.json (the
# "type": "module" field is what the runtime actually needs).
#
# Output: dist/healthz-monitor.zip (gitignored).

set -euo pipefail

cd "$(dirname "$0")"
mkdir -p dist
rm -f dist/healthz-monitor.zip
zip -q dist/healthz-monitor.zip index.mjs package.json
echo "built: $(pwd)/dist/healthz-monitor.zip ($(wc -c < dist/healthz-monitor.zip) bytes)"
