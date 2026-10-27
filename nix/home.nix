{ config, pkgs, lib, profile, catalog, ... }:
{
  home.username = profile.username;
  home.homeDirectory = profile.homeDirectory;
  home.stateVersion = "26.05";
  home.packages = catalog.packages ++ [
    (pkgs.writeShellScriptBin "bazel" ''
      exec ${pkgs.bazelisk}/bin/bazelisk "$@"
    '')
  ];
  programs.home-manager.enable = true;
  xdg.mime.enable = false;
  programs.bash = {
    enable = true;
    enableCompletion = true;
    historyControl = [ "ignoreboth" ];
    historySize = 1000;
    historyFileSize = 2000;
    shellOptions = [ "histappend" "checkwinsize" "globstar" ];
    shellAliases = {
      ll = "ls -alF";
      la = "ls -A";
      l = "ls -CF";
      sg = "ast-grep";
    };
    profileExtra = ''
      if [ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
      fi
    '';
    initExtra = ''
      export PATH="$HOME/.nix-profile/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
    '';
  };
  home.sessionPath = [
    "${config.home.homeDirectory}/.nix-profile/bin"
    "${config.home.homeDirectory}/.cargo/bin"
    "${config.home.homeDirectory}/.local/bin"
  ];
  home.sessionVariables = {
    RIPGREP_CONFIG_PATH = "${config.home.homeDirectory}/.ripgreprc";
    TMPDIR = "${config.home.homeDirectory}/.local/state/wsl-rootfs/tmp";
    UV_PYTHON_PREFERENCE = "only-managed";
  };
  home.file = {
    ".gitconfig".source = ./files/gitconfig;
    ".ripgreprc".source = ./files/ripgreprc;
    ".tmux.conf".source = ./files/tmux.conf;
    ".gitattributes".source = pkgs.runCommand "mergiraf-gitattributes" { } ''
      ${pkgs.mergiraf}/bin/mergiraf languages --gitattributes > "$out"
    '';
    ".config/git/hooks" = { source = ./files/git-hooks; recursive = true; };
    ".config/wsl-rootfs/catalog.json".text = builtins.toJSON catalog.metadata;
  };
  home.activation.buildTemporaryDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "${config.home.homeDirectory}/.local/state/wsl-rootfs/tmp"
    run chmod 700 "${config.home.homeDirectory}/.local/state/wsl-rootfs/tmp"
  '';
}
