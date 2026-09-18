#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

bash -n scripts/docker-entrypoint.sh
bash -n scripts/futu-opend-cli

python3 - <<'PY'
from pathlib import Path
import yaml
for path in [Path('compose.yaml'), Path('.github/workflows/docker-publish.yml')]:
    with path.open('r', encoding='utf-8') as f:
        yaml.safe_load(f)
    print(f'YAML OK: {path}')
PY

grep -q 'FROM ubuntu:24.04' Dockerfile
grep -q 'ghcr.io/lqepoch/futu_api_docker:latest' compose.yaml

echo 'Static validation passed.'
