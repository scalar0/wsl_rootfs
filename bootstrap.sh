#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read_manifest() {
local file="$1"
grep -Ehv '^\s*(#|$)' "$file"
}

map_manifest() {
local file="$1"
local -n arr="$2"
mapfile -t arr < <(read_manifest "$file")
}

upgrade_system() {
apt-get update && \
apt-get install -y build-essential software-properties-common pkg-config libssl-dev jq gh 1password-cli git git-lfs && \
apt-get upgrade -y && \
apt-get full-upgrade -y && \
apt-get autoremove -y
}

setup_op_keyring() {
curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | \
gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

printf 'deb [arch=%s signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/%s stable main\n' \
"$(dpkg --print-architecture)" \
"$(dpkg --print-architecture)" | \
tee /etc/apt/sources.list.d/1password.list >/dev/null

mkdir -p /etc/debsig/policies/AC2D62742012EA22
curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol | \
tee /etc/debsig/policies/AC2D62742012EA22/1password.pol >/dev/null

mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | \
gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
}

setup_gh_keyring() {
local out

mkdir -p -m 755 /etc/apt/keyrings
out="$(mktemp)"
wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
tee /etc/apt/keyrings/githubcli-archive-keyring.gpg < "$out" >/dev/null
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
mkdir -p -m 755 /etc/apt/sources.list.d
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
"$(dpkg --print-architecture)" | \
tee /etc/apt/sources.list.d/github-cli.list >/dev/null
rm -f "$out"
}

setup_ppa_keyring() {
add-apt-repository -y ppa:git-core/ppa
}

setup_keyring() {
setup_op_keyring
setup_gh_keyring
setup_ppa_keyring
}

configure_git() {
ln -s /mnt/c/Users/"$USER"/.gitconfig "$HOME/.gitconfig" && \
ln -s /mnt/c/Users/"$USER"/.config/git/gh.gitconfig "$HOME/.config/git/gh.gitconfig" && \
ln -s /mnt/c/Users/"$USER"/.config/git/gh.gitconfig "$HOME/.config/git/gl.gitconfig" && \
ln -s /mnt/c/Users/"$USER"/.config/git/.gitcommit "$HOME/.config/git/.gitcommit" && \
cp ./op.gitconfig "$HOME/.config/git/op.gitconfig" && \
mergiraf languages --gitattributes > "$HOME/.gitattributes"
}

install_rust_tooling() {
curl -fsSL https://sh.rustup.rs | \
sh -s -- -y -v --default-toolchain="stable" --component="rust-analyzer,llvm-tools,rust-src,rust-analysis,rust-docs"

# shellcheck disable=SC1090
. "$HOME/.cargo/env"
rustup update
cargo install --locked ripgrep cargo-nextest ast-grep cargo-llvm-cov cargo-mutants mergiraf sccache wild-linker
}

install_py_tooling() {
curl -LsSf https://astral.sh/uv/install.sh | sh && \
source $HOME/.local/bin/env && \
uv python update-shell && \
uv python install --managed-python --default
}

install_node_tooling() {
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
export NVM_DIR="$HOME/.nvm"

# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

nvm install --latest-npm && \
nvm use node && \
nvm alias default node && \
npm install -g @openai/codex prettier lefthook
}

install_starfish() {
curl -sS https://starship.rs/install.sh | sh -s -- -y && \
echo 'eval "$(starship init bash)"' >> "$HOME/.bashrc"
}

configure_agents() {
git clone git@github.com:scalar0/skills.git "$HOME/.agents/skills" && \
git clone git@github.com:scalar0/rules.git "$HOME/.codex/rules"
}


main() {
setup_keyring
upgrade_system
install_rust_tooling
install_py_tooling
install_node_tooling
install_starfish
configure_git
configure_agents
cp ./.bash_aliases "$HOME/.bash_aliases"
}

main "$@"
