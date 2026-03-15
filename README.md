# dotfiles

Symlink-indexed dotfiles for this WSL2 Ubuntu environment.

## Layout

- `home/` mirrors paths under `$HOME` using symlinks that point to the live
  files in `$HOME`
- `etc/` stores machine-level files that should be linked manually with `sudo`
- `manifests/` records package, tool, and editor state that is not itself symlinked
- `scripts/link-home.sh` rebuilds the symlinks inside `home/`

## Use

Run the full bootstrap:

```bash
./bootstrap.sh
```

Or run just the link rebuild as a dry run:

```bash
./scripts/link-home.sh --dry-run
```

Apply only the repo symlinks:

```bash
./scripts/link-home.sh
```

Run the installer scripts in a clean Ubuntu container:

```bash
./scripts/run-installers-in-docker.sh
```

Run only a subset of installers inside that container:

```bash
./scripts/run-installers-in-docker.sh scripts/install-git.sh scripts/install-rust.sh
```

If an existing file already exists inside `home/` and is not the expected
symlink, it is moved into `.backups/<timestamp>/...` inside the repo before the
symlink is created.

## Manual Machine Steps

1. Replace the placeholders in any `home/**/*.in` template with your real
   1Password secret references.
2. Run `./bootstrap.sh`.
3. Restore any remaining local-only secret files listed in
   `manifests/local-only.md`.
4. Link the WSL config manually:

```bash
sudo ln -sfn "$(pwd)/etc/wsl.conf" /etc/wsl.conf
```

5. Restart WSL after changing `/etc/wsl.conf`:

```powershell
wsl --shutdown
```

## Notes

- Git is expected from `ppa:git-core/ppa`, not the default Ubuntu archive.
- The tracked files live at their normal paths under `$HOME`; the repo stores
  symlinks that reference those paths.
- Secret-backed local files are kept out of the symlink index. They are
  rendered locally from `*.in` templates with `op inject`.
- The Rust toolchain is installed during bootstrap, then crate binaries are
  installed from `manifests/crates.txt`.
- Git commit signing depends on 1Password's WSL signer at
  `/mnt/c/Users/main/AppData/Local/Microsoft/WindowsApps/op-ssh-sign-wsl.exe`.
- Git transport is configured to use `ssh.exe` from Windows.
- Docker is expected through Docker Desktop WSL integration, not a distro-local
  Docker install.
- The Docker installer test image lives at `docker/ubuntu-installers/Dockerfile`
  and mounts the repo into `/workspace` when invoked via
  `scripts/run-installers-in-docker.sh`.
