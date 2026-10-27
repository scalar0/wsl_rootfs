# Original shell files

This snapshot contains the original shell files from /home/me on October 27, 2026.
Each copy preserves the source bytes and file permissions.
Credential checks and a manual review found no credentials in these files.
SHA256SUMS records the checksum of each original file.

| File | Original role |
| --- | --- |
| [.bashrc](.bashrc) | Interactive Bash settings, prompt, completion, and environment paths |
| [.profile](.profile) | Login settings and environment paths |
| [.bash_aliases](.bash_aliases) | Command aliases |
| [.bash_logout](.bash_logout) | Bash logout settings |
| [.zshrc](.zshrc) | Zsh environment setup |

The source home had no .bash_profile, .bash_login, .bash_completion, or .inputrc.
The snapshot excludes shell history and credentials.

Bootstrap does not install or source these copies.
[Home Manager](../../../nix/home.nix) defines the installed Bash settings.
Use these copies to recover individual settings or compare the generated configuration.
The copies retain old NVM, pnpm, Depot, and LLVM paths.
The Headroom alias also remains in the original .bash_aliases.
Some commands and paths need separate installation before use.

Keep the original files unchanged.
Save later snapshots in a separate dated directory.
