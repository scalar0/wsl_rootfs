#!/usr/bin/env bash
set -euo pipefail

[[ $EUID == 0 ]] || {
  echo "Run this system step through sudo." >&2
  exit 1
}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
mapfile -t packages < <(jq -r '.basePackages[]' "$repo_root/nix/profile.json")
if [[ $(jq -r '.optional.lighttpd' "$repo_root/nix/profile.json") == true ]]; then
  packages+=(lighttpd)
fi
missing=()
for package in "${packages[@]}"; do
  [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) == "install ok installed" ]] ||
    missing+=("$package")
done
if ((${#missing[@]})); then
  apt-get update
  apt-get install -y --no-install-recommends "${missing[@]}"
fi
kind=$(findmnt -n -o FSTYPE -T /var/tmp)
[[ $kind != tmpfs && $kind != ramfs ]] || {
  echo "Nix needs disk-backed storage under /var/tmp." >&2
  exit 1
}
install -d -m 1777 /var/tmp/wsl-rootfs-nix
install -d -m 755 /etc/nix /etc/systemd/system/nix-daemon.service.d
changed=false
temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT
cp "$repo_root/nix/daemon.conf" "$temporary"
if ! cmp -s "$temporary" /etc/nix/wsl-rootfs.conf; then
  install -m 644 "$temporary" /etc/nix/wsl-rootfs.conf
  changed=true
fi
touch /etc/nix/nix.conf
if ! grep -qxF '!include wsl-rootfs.conf' /etc/nix/nix.conf; then
  printf '\n!include wsl-rootfs.conf\n' >>/etc/nix/nix.conf
  changed=true
fi
cat >"$temporary" <<'NIX_SERVICE'
[Service]
Environment=TMPDIR=/var/tmp/wsl-rootfs-nix
NIX_SERVICE
if ! cmp -s "$temporary" /etc/systemd/system/nix-daemon.service.d/wsl-rootfs.conf; then
  install -m 644 "$temporary" /etc/systemd/system/nix-daemon.service.d/wsl-rootfs.conf
  changed=true
fi
if [[ $changed == true ]]; then
  systemctl daemon-reload
  if systemctl is-active --quiet nix-daemon.service; then
    systemctl restart nix-daemon.service
  fi
fi
if [[ $(jq -r '.optional.lighttpd' "$repo_root/nix/profile.json") == true ]]; then
  systemctl enable --now lighttpd.service
fi
