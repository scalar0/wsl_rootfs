#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_root="$repo_root/home"

found_template=false

while IFS= read -r template; do
    found_template=true
    rel="${template#$template_root/}"
    output="$HOME/${rel%.in}"

    mkdir -p "$(dirname "$output")"
    op inject -i "$template" -o "$output"
    printf 'rendered %s\n' "$output"
done < <(find "$template_root" -type f -name '*.in' | sort)

if [ "$found_template" = false ]; then
    printf 'no templates found under %s\n' "$template_root" >&2
    exit 1
fi
