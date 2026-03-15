#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./scripts/link-home.sh [--dry-run]

Replace every file in repo/home with a symlink that points to the live file in
$HOME. Existing differing files inside the repo are moved to
./.backups/<timestamp>/...
EOF
}

dry_run=false

case "${1:-}" in
    "")
        ;;
    --dry-run)
        dry_run=true
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="$repo_root/home"
manifest="$repo_root/manifests/tracked-paths.txt"
backup_root="$repo_root/.backups/$(date +%Y%m%d-%H%M%S)"
created_backup_root=false

log() {
    printf '%s\n' "$*"
}

ensure_backup_dir() {
    if [ "$created_backup_root" = false ]; then
        mkdir -p "$backup_root"
        created_backup_root=true
    fi
}

move_to_backup() {
    local dest="$1"
    local rel="$2"
    ensure_backup_dir
    mkdir -p "$backup_root/$(dirname "$rel")"
    mv "$dest" "$backup_root/$rel"
}

link_one() {
    local repo_path="$1"
    local rel="${repo_path#$source_root/}"
    local home_path="$HOME/$rel"

    if [ ! -e "$home_path" ] && [ ! -L "$home_path" ]; then
        log "skip ~/$rel (missing target)"
        return
    fi

    mkdir -p "$(dirname "$repo_path")"

    if [ -L "$repo_path" ]; then
        if [ "$(readlink "$repo_path")" = "$home_path" ]; then
            log "ok   home/$rel"
            return
        fi

        if [ "$dry_run" = true ]; then
            log "swap home/$rel (different symlink)"
        else
            move_to_backup "$repo_path" "$rel"
        fi
    elif [ -e "$repo_path" ]; then
        if [ "$dry_run" = true ]; then
            log "swap home/$rel (backup existing)"
        else
            move_to_backup "$repo_path" "$rel"
        fi
    else
        log "new  home/$rel"
    fi

    if [ "$dry_run" = true ]; then
        return
    fi

    rm -f "$repo_path"
    ln -s "$home_path" "$repo_path"
    log "link home/$rel"
}

while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    link_one "$source_root/$rel"
done < "$manifest"

if [ "$dry_run" = false ] && [ "$created_backup_root" = true ]; then
    log "backup root: $backup_root"
fi
