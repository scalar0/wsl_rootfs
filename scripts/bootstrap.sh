#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
backup=
windows=
replace=false
check_only=false
while (($#)); do
  case "$1" in
  --state)
    [[ $# -ge 2 ]] || exit 1
    backup=$2
    shift 2
    ;;
  --windows-profile)
    [[ $# -ge 2 ]] || exit 1
    windows=$2
    shift 2
    ;;
  --replace-existing)
    replace=true
    shift
    ;;
  --check)
    check_only=true
    shift
    ;;
  --help)
    echo "Usage: bootstrap.sh [--state PATH] [--windows-profile PATH] [--replace-existing] [--check]"
    exit 0
    ;;
  *)
    echo "Unknown bootstrap argument. Use --help." >&2
    exit 1
    ;;
  esac
done
[[ $EUID != 0 ]] || {
  echo "Start bootstrap as the Linux user." >&2
  exit 1
}
# shellcheck source=/dev/null
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 26.04 ]] || {
  echo "Bootstrap needs Ubuntu 26.04." >&2
  exit 1
}
[[ $(uname -m) == x86_64 && $(uname -r) == *WSL2* ]] || {
  echo "Bootstrap needs x86_64 WSL2." >&2
  exit 1
}
[[ $(ps -p 1 -o comm=) == systemd ]] || {
  echo "Enable systemd before bootstrap." >&2
  exit 1
}
if ! command -v jq >/dev/null; then
  [[ $check_only == false ]] || {
    echo "The preflight check needs jq." >&2
    exit 1
  }
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends jq
fi
profile="$repo_root/nix/profile.json"
[[ $(id -un) == "$(jq -r '.username' "$profile")" &&
$HOME == "$(jq -r '.homeDirectory' "$profile")" ]] || {
  echo "The Linux account does not match nix/profile.json." >&2
  exit 1
}
if [[ -z $windows ]]; then
  windows=$(powershell.exe -NoProfile -NonInteractive -Command \
    "[Environment]::GetFolderPath('UserProfile')" | tr -d '\r')
  windows=$(wslpath -u "$windows")
fi
[[ -d $windows ]] || {
  echo "The Windows profile path is unavailable." >&2
  exit 1
}
windows=$(cd -- "$windows" && pwd -P)
reserve=$(jq -r '.reserveBytes' "$profile")
budget=$(jq -r '.installBudgetBytes' "$profile")
for directory in "$windows" "$HOME"; do
  kind=$(findmnt -n -o FSTYPE -T "$directory")
  [[ $kind != tmpfs && $kind != ramfs ]] || {
    echo "Bootstrap needs disk-backed storage." >&2
    exit 1
  }
  available=$(df -B1 --output=avail "$directory" | tail -1)
  ((available >= reserve + budget)) || {
    echo "Free space is below the installation budget and reserve." >&2
    exit 1
  }
done
[[ -f $repo_root/nix/flake.lock ]] || {
  echo "The Nix lock file is missing." >&2
  exit 1
}
if [[ -n $backup ]]; then
  backup=$(cd -- "$backup" && pwd -P)
  [[ -f $backup/manifest.json && -f $backup/settings.tar.gz ]] || {
    echo "The settings backup is incomplete." >&2
    exit 1
  }
fi
if [[ $check_only == true ]]; then
  echo "Platform, account, paths, lock file, and storage checks passed."
  exit 0
fi
state="$HOME/.local/state/wsl-rootfs"
mkdir -p "$state/tmp"
chmod 700 "$state" "$state/tmp"
export TMPDIR="$state/tmp"
exec 9>"$state/bootstrap.lock"
flock -n 9 || {
  echo "Another bootstrap process holds the lock." >&2
  exit 1
}
sudo bash "$repo_root/scripts/system.sh"
if [[ ! -x /nix/var/nix/profiles/default/bin/nix ]] && ! command -v nix >/dev/null; then
  if [[ -e /nix/store ]]; then
    echo "Nix has a partial installation. Repair it before retrying." >&2
    exit 1
  fi
  version=$(jq -r '.version' "$repo_root/nix/installer.json")
  system=$(jq -r '.system' "$repo_root/nix/installer.json")
  checksum=$(jq -r '.sha256' "$repo_root/nix/installer.json")
  download="$state/tmp/nix-$version-$system.tar.xz"
  curl --fail --show-error --location --retry 2 --connect-timeout 15 --max-time 300 \
    "https://releases.nixos.org/nix/nix-$version/nix-$version-$system.tar.xz" -o "$download"
  if ! printf '%s  %s\n' "$checksum" "$download" | sha256sum --check --status; then
    echo "The Nix archive checksum does not match. Check the download before retrying." >&2
    exit 1
  fi
  tar -xJf "$download" -C "$state/tmp"
  bash "$state/tmp/nix-$version-$system/install" \
    --daemon --yes --no-channel-add --no-modify-profile
fi
if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
  # shellcheck source=/dev/null
  source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
sudo bash "$repo_root/scripts/system.sh"
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
bash "$repo_root/scripts/nix.sh" build --no-write-lock-file --no-link --dry-run "path:$repo_root/nix#default"
bash "$repo_root/scripts/nix.sh" build --no-write-lock-file --out-link "$state/current" "path:$repo_root/nix#default" &
build_pid=$!
trap 'kill -TERM "$build_pid" 2>/dev/null || true' INT TERM
while kill -0 "$build_pid" 2>/dev/null; do
  for directory in "$windows" "$HOME"; do
    available=$(df -B1 --output=avail "$directory" | tail -1)
    if ((available < reserve)); then
      kill -TERM "$build_pid" 2>/dev/null || true
      wait "$build_pid" || true
      echo "The build stopped to preserve disk space." >&2
      exit 1
    fi
  done
  sleep 3
done
wait "$build_pid"
trap - INT TERM
export PATH="$state/current/home-path/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
bash "$repo_root/scripts/tool.sh" validate
bash "$repo_root/scripts/tool.sh" scan-public
if [[ -n $backup ]]; then
  bash "$repo_root/scripts/tool.sh" check-backup "$backup"
fi
preflight=(prepare-home "$state/current/home-files")
[[ $replace == false ]] || preflight+=(--replace-existing)
bash "$repo_root/scripts/tool.sh" "${preflight[@]}"
"$state/current/activate"
export PATH="$HOME/.nix-profile/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
bash "$repo_root/scripts/tool.sh" links --windows-profile "$windows"
bash "$repo_root/scripts/tool.sh" rules
if [[ -n $backup ]]; then
  bash "$repo_root/scripts/tool.sh" restore "$backup"
fi
channel=$(jq -r '.rustChannel' "$profile")
mapfile -t components < <(jq -r '.rustComponents[]' "$profile")
if ! rustup toolchain list | grep -q "^$channel-"; then
  rustup toolchain install "$channel" --profile default --no-self-update
fi
for component in "${components[@]}"; do
  if ! rustup component list --toolchain "$channel" --installed | grep -Eq "^$component(-|$)"; then
    rustup component add --toolchain "$channel" "$component"
  fi
done
rustup default "$channel"
uv python install "$(jq -r '.pythonVersion' "$profile")" --default
access_status=0
bash "$repo_root/scripts/tool.sh" access --interactive --plugins || access_status=$?
if ((access_status == 1)); then
  exit 1
fi
if ((access_status == 2)); then
  echo "Some account or plugin checks need attention. Review the access report." >&2
fi
bash "$repo_root/scripts/tool.sh" verify --sign
