#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
backup=$(mktemp)
cp "$repo_root/nix/flake.lock" "$backup"
restore_lock() {
  cp "$backup" "$repo_root/nix/flake.lock"
  rm -f "$backup"
}
trap restore_lock ERR
trap 'restore_lock; exit 130' INT
trap 'restore_lock; exit 143' TERM
bash "$repo_root/scripts/nix.sh" flake update --flake "path:$repo_root/nix"
bash "$repo_root/scripts/nix.sh" flake check --no-write-lock-file "path:$repo_root/nix"
rm -f "$backup"
trap - ERR INT TERM
echo "The Nix inputs passed build checks. Review the lock file before activation."
