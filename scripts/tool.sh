#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec uv run --project "$repo_root" --locked python "$repo_root/tools/wsl_rootfs.py" "$@"
