#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apt_frontend="${BOOTSTRAP_APT_FRONTEND:-noninteractive}"
TZ="${TZ:-Etc/UTC}"
readonly repo_root apt_frontend TZ

default_phases=(
    prepare-system
    core-packages
    apt-repositories
    tool-packages
    rust-toolchain
    rust-crates
    node-tooling
    codex-cli
    secrets
    auth
    link-home
)

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

apt_get() {
    as_root env DEBIAN_FRONTEND="$apt_frontend" apt-get "$@"
}

read_manifest() {
    local file="$1"
    grep -Ehv '^\s*(#|$)' "$file"
}

map_manifest() {
    local file="$1"
    local -n arr="$2"
    mapfile -t arr < <(read_manifest "$file")
}

install_manifest() {
    local path="$1"
    local -a pkgs=()

    map_manifest "$path" pkgs
    if [ "${#pkgs[@]}" -gt 0 ]; then
        apt_get update
        apt_get install -y "${pkgs[@]}"
    fi
}

configure_timezone() {
    apt_get update
    apt_get install -y tzdata

    if [ ! -e "/usr/share/zoneinfo/$TZ" ]; then
        printf 'unknown timezone: %s\n' "$TZ" >&2
        return 1
    fi

    as_root ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
    printf '%s\n' "$TZ" | as_root tee /etc/timezone >/dev/null
    as_root env DEBIAN_FRONTEND="$apt_frontend" dpkg-reconfigure -f noninteractive tzdata >/dev/null
}

upgrade_system() {
    apt_get update
    apt_get upgrade -y
}

setup_op_keyring() {
    curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | \
        as_root gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

    printf 'deb [arch=%s signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/%s stable main\n' \
        "$(dpkg --print-architecture)" \
        "$(dpkg --print-architecture)" | \
        as_root tee /etc/apt/sources.list.d/1password.list >/dev/null

    as_root mkdir -p /etc/debsig/policies/AC2D62742012EA22
    curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol | \
        as_root tee /etc/debsig/policies/AC2D62742012EA22/1password.pol >/dev/null

    as_root mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
    curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | \
        as_root gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
}

setup_gh_keyring() {
    local out

    as_root mkdir -p -m 755 /etc/apt/keyrings
    out="$(mktemp)"
    wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
    as_root tee /etc/apt/keyrings/githubcli-archive-keyring.gpg < "$out" >/dev/null
    as_root chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    as_root mkdir -p -m 755 /etc/apt/sources.list.d
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
        "$(dpkg --print-architecture)" | \
        as_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    rm -f "$out"
}

setup_latest_lld() {
    local asset_suffix release_api release_info release_tag package_name package_url bundle_url
    local tmpdir archive bundle extracted_root install_root version_dir current_link

    case "$(uname -m)" in
        x86_64|amd64)
            asset_suffix="Linux-X64.tar.xz"
            ;;
        aarch64|arm64)
            asset_suffix="Linux-ARM64.tar.xz"
            ;;
        *)
            printf 'unsupported architecture for LLVM release archive: %s\n' "$(uname -m)" >&2
            return 1
            ;;
    esac

    release_api="https://api.github.com/repos/llvm/llvm-project/releases/latest"
    release_info="$(
        curl -fsSL "$release_api" | jq -r --arg suffix "$asset_suffix" '
            .tag_name as $tag
            | ([
                .assets[]
                | select(.name | startswith("LLVM-") and endswith($suffix))
                | {name, url: .browser_download_url}
              ][0]) as $pkg
            | ([
                .assets[]
                | select(.name == ($pkg.name + ".jsonl"))
                | .browser_download_url
              ][0]) as $bundle
            | if $pkg and $bundle then
                [$tag, $pkg.name, $pkg.url, $bundle] | @tsv
              else
                empty
              end
        '
    )"

    if [ -z "$release_info" ]; then
        printf 'failed to resolve the latest LLVM release asset or attestation bundle\n' >&2
        return 1
    fi

    IFS=$'\t' read -r release_tag package_name package_url bundle_url <<< "$release_info"

    install_root="/opt/llvm"
    version_dir="$install_root/$release_tag"
    current_link="$install_root/current"

    if [ ! -x "$version_dir/bin/ld.lld" ]; then
        tmpdir="$(mktemp -d)"
        archive="$tmpdir/$package_name"
        bundle="$archive.jsonl"

        curl -fsSL -o "$archive" "$package_url"
        curl -fsSL -o "$bundle" "$bundle_url"
        gh attestation verify --repo llvm/llvm-project "$archive" --bundle "$bundle"
        tar -C "$tmpdir" -xf "$archive"
        extracted_root="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

        if [ -z "$extracted_root" ]; then
            printf 'failed to unpack the LLVM release archive\n' >&2
            return 1
        fi

        as_root mkdir -p "$install_root"
        as_root rm -rf "$version_dir"
        as_root mv "$extracted_root" "$version_dir"
        rm -rf "$tmpdir"
    fi

    as_root ln -sfn "$version_dir" "$current_link"
    "$current_link/bin/ld.lld" --version
}

configure_rust_linker() {
    local cargo_config tmp_config

    cargo_config="$HOME/.cargo/config.toml"
    tmp_config="$(mktemp)"

    mkdir -p "$(dirname "$cargo_config")"

    cat <<'CFG' > "$tmp_config"
[target.'cfg(target_os = "linux")']
linker = "/opt/llvm/current/bin/clang"
rustflags = ["-C", "link-arg=-fuse-ld=/opt/llvm/current/bin/ld.lld"]
CFG

    if [ -f "$cargo_config" ] && ! cmp -s "$tmp_config" "$cargo_config"; then
        cp "$cargo_config" "$cargo_config.bak.$(date +%Y%m%d-%H%M%S)"
    fi

    mv "$tmp_config" "$cargo_config"
}

install_rust_toolchain() {
    curl -fsSL https://sh.rustup.rs | \
        sh -s -- -y -v --default-toolchain="stable" --component="rust-analyzer,llvm-tools,rust-src,rust-analysis,rust-docs"

    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
    rustup update
    setup_latest_lld
    configure_rust_linker
}

install_rust_crates() {
    local -a crates=()

    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
    map_manifest "$repo_root/manifests/crates.txt" crates
    if [ "${#crates[@]}" -gt 0 ]; then
        cargo install "${crates[@]}"
    fi
}

install_node_tooling() {
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
    export NVM_DIR="$HOME/.nvm"

    # shellcheck disable=SC1090
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    # shellcheck disable=SC1090
    [ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
    nvm install --latest-npm
}

install_codex_cli() {
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1090
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

    if ! command -v npm >/dev/null 2>&1; then
        printf 'npm is required; run the node-tooling phase first\n' >&2
        return 1
    fi

    npm install -g @openai/codex
}

run_secrets() {
    if [ "${BOOTSTRAP_SKIP_SECRETS:-0}" = "1" ]; then
        printf 'skipping secrets phase\n'
        return 0
    fi

    bash "$repo_root/scripts/expand-secrets.sh"
}

run_auth() {
    if [ "${BOOTSTRAP_SKIP_AUTH:-0}" = "1" ]; then
        printf 'skipping auth phase\n'
        return 0
    fi

    op account add --address my.1password.eu
    eval "$(op signin --account my)"
    op read "op://VCS/gh/credential" | gh auth login -p=ssh --skip-ssh-key --with-token
}

run_link_home() {
    if [ "${BOOTSTRAP_SKIP_LINK_HOME:-0}" = "1" ]; then
        printf 'skipping link-home phase\n'
        return 0
    fi

    "$repo_root/scripts/link-home.sh"
}

usage() {
    cat <<'HELP'
Usage: ./bootstrap.sh [phase ...]

When no phase is specified, the full local bootstrap runs.

Available phases:
  prepare-system   Configure timezone and run dist-upgrade non-interactively.
  core-packages    Install packages from manifests/core-apt.pkg.
  apt-repositories Configure the GitHub CLI, Git PPA, and 1Password APT repos.
  tool-packages    Install packages from manifests/tools.pkg.
  rust-toolchain   Install rustup, the stable toolchain, latest LLVM LLD, and cargo linker config.
  rust-crates      Install crates from manifests/crates.txt.
  node-tooling     Install nvm and the latest npm.
  codex-cli        Install @openai/codex globally via npm.
  secrets          Expand local secret-backed templates.
  auth             Sign in to 1Password and GitHub CLI.
  link-home        Rebuild repo-managed home symlinks.

Environment flags:
  TZ=Region/City                Timezone to preseed before apt runs. Default: Etc/UTC.
  BOOTSTRAP_SKIP_SECRETS=1      Skip secret expansion.
  BOOTSTRAP_SKIP_AUTH=1         Skip 1Password and GitHub auth.
  BOOTSTRAP_SKIP_LINK_HOME=1    Skip home symlink rebuild.
HELP
}

run_phase() {
    local phase="$1"

    case "$phase" in
        prepare-system)
            configure_timezone
            upgrade_system
            ;;
        core-packages)
            install_manifest "$repo_root/manifests/core-apt.pkg"
            ;;
        apt-repositories)
            apt_get update
            as_root env DEBIAN_FRONTEND="$apt_frontend" add-apt-repository -y ppa:git-core/ppa
            setup_op_keyring
            setup_gh_keyring
            ;;
        tool-packages)
            install_manifest "$repo_root/manifests/tools.pkg"
            ;;
        rust-toolchain)
            install_rust_toolchain
            ;;
        rust-crates)
            install_rust_crates
            ;;
        node-tooling)
            install_node_tooling
            ;;
        codex-cli)
            install_codex_cli
            ;;
        secrets)
            run_secrets
            ;;
        auth)
            run_auth
            ;;
        link-home)
            run_link_home
            ;;
        -h|--help)
            usage
            ;;
        *)
            printf 'unknown bootstrap phase: %s\n' "$phase" >&2
            usage >&2
            return 1
            ;;
    esac
}

if [ "$#" -eq 0 ]; then
    phases=("${default_phases[@]}")
else
    phases=("$@")
fi

for phase in "${phases[@]}"; do
    printf '==> %s\n' "$phase"
    run_phase "$phase"
done
