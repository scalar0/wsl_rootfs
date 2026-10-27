# WSL development setup

This repository restores development tools and reviewed settings on Ubuntu 26.04 WSL2.
Create the WSL instance manually.
Use the Linux account and home directory from [the profile](nix/profile.json).
Keep Windows WSL settings unchanged.

Run `just --list` for the command interface and its documentation.
On a fresh instance, `./bootstrap.sh` installs the tools that provide that interface.
Use `./bootstrap.sh --help` for bootstrap options.

## Ownership

| Data | Source |
| --- | --- |
| Nix package selection | [Package catalog](nix/packages.nix) |
| Package revisions | [Nix lock file](nix/flake.lock) |
| Pinned upstream binaries | [Artifact pins](nix/artifacts.json) |
| Account, Python version, and optional tools | [Profile](nix/profile.json) |
| Shell and public settings | [Home Manager module](nix/home.nix) |
| Original shell files | [October 27, 2026 snapshot](backups/original-shell/2026-10-27/README.md) |
| Backup and report contracts | [JSON schemas](schemas) |
| Python dependencies | [uv project](pyproject.toml) and [lock file](uv.lock) |

Nix provides Node and the selected development CLIs.
Node uses the verified upstream binary for the installed version.
Ubuntu provides its ELF loader and runtime libraries.
This avoids the crash from ELF rewriting in the tested package set.

The coverage tool uses the verified upstream release already installed in the old VM.
The pinned Nixpkgs source package failed its instrumentation tests.
Uv uses the installed upstream version because the Nixpkgs version lacks the selected Python download.

Rustup owns Rust toolchains and components.
Uv owns Python runtimes and environments.
Ubuntu owns base system packages and optional lighttpd.
Nix provides LLVM 23.
Windows Docker Desktop integration provides Docker.
No command upgrades the full Ubuntu system or deletes a WSL instance.

The Justfile centralizes the command interface.
Its recipes call the same scripts as bootstrap.
This prevents separate command implementations.

## Host and project tools

The host catalog follows direct host calls and native build configuration.
Bazel provides project tools through each repository's pinned modules.
Installed command paths supply inventory evidence.
Recipe requirements determine host installation.

| Scope | Tools or requirements | Evidence |
| --- | --- | --- |
| Project format and lint | ShellCheck, shfmt, Prettier, Buildifier, Ruff, and project ast-grep | [Format targets](../kernel-toolchain/tools/format/BUILD.bazel) and [lint definitions](../kernel-toolchain/tools/lint/linters.bzl) |
| Project runtimes and test peers | Bazel Rust, Python, Node, pnpm, LLVM, and clangd | [Module declarations](../kernel-toolchain/MODULE.bazel) |
| Native Rust development | Rustup, Nextest, mutation tests, and LLVM 23 with LLD | [Host workflows](../kernel-toolchain/Justfile), [linker configuration](../kernel-toolchain/.cargo/config.toml), and [mutation configuration](../kernel-toolchain/.cargo/mutants.toml) |
| Host source checks | Taplo and xan | [Host workflows](../kernel-toolchain/Justfile) and [specification data tools](../kernel-toolchain/specs/data/Justfile) |
| Other native workspaces | Sccache, Clang, LLD, and Typst | [Wanguard configuration](../wanguard/.cargo/config.toml) and [CV build requirements](../cv-swe/Justfile) |

Native Cargo retains its own compiler, test runner, and coverage tool.
The host LLVM version remains 23.
The host Node runtime remains the earlier explicit selection.
Bazel retains control of the project's separate Node version.

Ast-grep remains available for the requested host code searches.
Graphviz remains available for standalone graphs.
Git tools, shell utilities, and data tools retain their host roles.

The default host profile omits CMake, Ninja, Doxygen, Wild, and Starpls.
The checked workspaces supply no active host requirement for these commands.
Starship is removed from the package catalog and shell configuration.

The restore repository has its own scoped maintenance dependencies.
Its checks obtain ShellCheck and shfmt through the maintenance shell.
Normal bootstrap builds the host profile.

## Settings and credentials

The Nix source directory contains public settings only.
Backups and private runtime settings remain outside that directory.
The Nix store permits reads by local users.
Do not add credentials or private settings to Nix inputs.

Capture uses an explicit file list.
It excludes credential files, repositories, agent sessions, system skills, caches, and toolchains.
It rejects links, invalid settings, known credential formats, and literal credential fields.

A secret check cannot recognize every possible secret.
Review private settings before capture.
Use credential environment references where the application supports them.
Capture accepts UTF-8 settings and user skill files.

The restore checks archive members and checksums before writes.
It refuses conflicting private settings.
Repeated restores accept identical files.
Home Manager conflicts require explicit replacement.
The bootstrap preserves matching Ubuntu skeleton files automatically.
Explicit replacement keeps timestamped copies of existing public settings.

The restore reconnects Windows Git, AWS, and Azure paths.
Windows remains the source for Git identities and the commit template.
It uses the correct GitLab configuration file.

Unlock 1Password on Windows when signing needs access.
Complete GitHub or application login when verification reports missing access.

Plugin selections remain in Codex settings.
The restore refreshes configured marketplaces and reinstalls enabled plugins.
Local marketplace repositories need your manual clone first.
Remote plugin services can require a new login.
The restore does not copy plugin caches or OAuth state.

## Storage and recovery

The default installation budget is 20 GiB.
The default free-space reserve is another 20 GiB.
Bootstrap checks both the Windows backing volume and the Linux file system.
It monitors free space during the Nix build.
It stops the client build when free space crosses the reserve.
An in-flight daemon download can continue briefly after cancellation.

Build temporary directories use disk storage.
Nix builds use one job and two cores.
Programs that ignore TMPDIR can still use /tmp.

A failed bootstrap can run again after the reported problem is fixed.
Home Manager keeps configuration generations.
Generation rollback does not revert Ubuntu packages, Rust toolchains, Python runtimes, or private settings.
Keep the old VM until application and project checks pass.

## Repository deletion checks

Source repositories remain your responsibility.
Clone them manually on the new VM.
The audit never pushes, resets, or changes source repository refs.
Remote checks use temporary Git storage.

A successful repository audit does not approve VM deletion.
The audit also reports unmanaged files under its scan roots.
It blocks on local changes, ignored files, stashes, local metadata, and unverified objects.
It checks current remote history instead of cached tracking refs.
Offline checks and remote failures cannot produce a successful result.

LFS payload verification requires a separate check.
The audit reports LFS state as a blocker.
It does not claim that a Git commit proves remote LFS payload availability.
Agent sessions remain in the old VM.
Their removal needs an explicit decision before future VM deletion.

## Imported settings

The [original shell snapshot](backups/original-shell/2026-10-27/README.md) preserves the current Bash files and the Zsh startup file.
It includes the original prompt, aliases, completion settings, and environment paths.
Checksums protect the original file contents.
Bootstrap does not install or source the snapshot.
Home Manager defines the installed Bash settings.

Git hooks came from the current files under ~/.config/git/hooks.
The import preserves local Git hook changes.
This repository owns the Git hook copies.
The imported commit policy keeps its existing behavior.

The personal rules repository owns Codex rules.
The profile selects its GitHub URL.
Bootstrap clones it into ~/.codex/rules after Windows Git access is configured.
A matching checkout supplies its current files.
Update that checkout through Git or gh.
A conflicting destination stops installation.
The repository deletion audit includes this checkout.

Optional helper support currently provides RTK.
Headroom and Tokensave remain excluded.
Capture omits hooks for disabled helpers and reports each omission.
The setup does not restore editor extensions or install Docker Desktop.

## Validation limits

Fixture tests cover backup corruption, unsafe paths, conflicting settings, Windows links, and local Git loss risks.
Nix checks evaluate and build the locked Home Manager configuration.
A fresh WSL instance must still pass bootstrap, signing, login, and representative project builds before migration.

The current VM has blocked WSL network threads.
Isolated test processes denied netlink sockets.
The Bazel smoke test disabled network metrics to avoid the kernel stall.
These test workarounds do not change the restored configuration.

Python checks file paths and controls Git processes.
Jq handles JSON extraction in shell scripts.
This division keeps archive checks and Git checks testable without shell parsing.

## Sources

| Behavior | Reference |
| --- | --- |
| Nix installation | [Nix installation guide](https://nix.dev/manual/nix/2.34/installation/installing-binary.html) |
| Home Manager flakes | [Standalone setup](https://nix-community.github.io/home-manager/nix-flakes/standalone.html) |
| Nix store privacy | [Nix secrets guidance](https://nix.dev/manual/nix/2.34/store/secrets) |
| Codex login | [OpenAI authentication guide](https://developers.openai.com/codex/auth) |
| Plugin settings and marketplaces | [OpenAI plugin guide](https://developers.openai.com/plugins/build/plugins) |
