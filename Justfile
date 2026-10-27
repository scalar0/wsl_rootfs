set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

# Show the command interface.
default:
    @just --list

# Capture checked settings. Optional flags: --destination PATH or --windows-profile PATH.
capture *args:
    bash scripts/tool.sh capture "$@"

# Show command paths and Windows links without reading credentials.
inventory:
    bash scripts/tool.sh inventory

# Apply the locked setup. Optional flags: --state PATH, --windows-profile PATH, --replace-existing.
restore *args:
    bash bootstrap.sh "$@"

# Check the platform and storage without installation.
preflight *args:
    bash bootstrap.sh --check "$@"

# Check a backup before use.
check-backup path:
    bash scripts/tool.sh check-backup "$1"

# Report repository deletion blockers. Use --offline to omit remote checks. Exit 2 means blocked.
audit *args:
    bash scripts/tool.sh audit "$@"

# Clone the personal Codex rules repository selected in the profile.
rules:
    bash scripts/tool.sh rules

# Reconnect accounts and plugins. Add --interactive for login prompts.
access *args:
    bash scripts/tool.sh access --plugins "$@"

# Check tools, Windows access, and disk-backed temporary storage. Exit 2 means incomplete.
verify:
    bash scripts/tool.sh verify --sign

# Update Nix inputs and build checks without activation. Restore the lock file after failure.
update:
    bash scripts/update.sh

# Update the Rust channel from the profile.
update-rust:
    rustup update "$(jq -r '.rustChannel' nix/profile.json)"

# Activate a retained Home Manager generation. System packages and private settings remain unchanged.
rollback generation:
    bash scripts/rollback.sh "$1"

# Validate restore code in the maintenance shell. Enable required Nix features for this command.
check:
    bash scripts/nix.sh develop --no-write-lock-file "path:{{justfile_directory()}}/nix" --command just _check

# Keep validation dependencies outside the host profile.
[private]
_check:
    uv run --locked --group dev ruff check tools tests
    uv run --locked --group dev ruff format --check tools tests
    bash scripts/tool.sh validate
    bash scripts/tool.sh scan-public
    for manifest in backups/original-shell/*/SHA256SUMS; do (cd "$(dirname "$manifest")" && sha256sum --check --strict SHA256SUMS); done
    shellcheck bootstrap.sh scripts/*.sh
    shfmt -d -i 2 bootstrap.sh scripts/*.sh
    mkdir -p .state
    uv run --locked --group dev pytest --basetemp .state/pytest

# Build the locked Home Manager configuration with required Nix features. This command does not activate it.
check-nix:
    bash scripts/nix.sh flake check --no-write-lock-file "path:{{justfile_directory()}}/nix"
