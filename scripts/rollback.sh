#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && $1 =~ ^[0-9]+$ ]] || {
  echo "Supply a Home Manager generation number." >&2
  exit 1
}
generation="$HOME/.local/state/nix/profiles/home-manager-$1-link"
[[ -x $generation/activate ]] || {
  echo "The generation is unavailable." >&2
  exit 1
}
exec "$generation/activate"
