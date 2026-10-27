{ pkgs, profile, vendor }:
let
  llvm = pkgs.llvmPackages_23;
  entry = package: commands: {
    inherit package;
    metadata = {
      name = pkgs.lib.getName package;
      version = package.version or "unknown";
      storePath = "${package}";
      inherit commands;
    };
  };
  entries = with pkgs; [
    (entry git [ "git" ])
    (entry git-lfs [ "git-lfs" ])
    (entry gh [ "gh" ])
    (entry _1password-cli [ "op" ])
    (entry nix [ "nix" "nix-env" "nix-store" "nix-build" ])
    (entry just [ "just" ])
    (entry jq [ "jq" ])
    (entry ripgrep [ "rg" ])
    (entry ast-grep [ "ast-grep" ])
    (entry vendor.uv [ "uv" "uvx" ])
    (entry rustup [ "rustup" ])
    (entry vendor.node [ "node" "npm" ])
    (entry codex [ "codex" ])
    (entry bazelisk [ "bazelisk" ])
    (entry vendor.aspect [ "aspect" ])
    (entry vendor.depot [ "depot" ])
    (entry llvm.clang [ "clang" "clang++" ])
    (entry llvm.lld [ "ld.lld" ])
    (entry llvm.lldb [ "lldb" ])
    (entry pkg-config [ "pkg-config" ])
    (entry graphviz [ "dot" ])
    (entry cargo-nextest [ "cargo-nextest" ])
    (entry vendor.coverage [ "cargo-llvm-cov" ])
    (entry cargo-mutants [ "cargo-mutants" ])
    (entry mergiraf [ "mergiraf" ])
    (entry sccache [ "sccache" ])
    (entry taplo [ "taplo" ])
    (entry tokei [ "tokei" ])
    (entry typst [ "typst" ])
    (entry xan [ "xan" ])
    (entry tmux [ "tmux" ])
    (entry htop [ "htop" ])
    (entry perl [ "perl" ])
    (entry zstd [ "zstd" ])
  ] ++ pkgs.lib.optionals profile.optional.helpers [
    (entry rtk [ "rtk" ])
  ];
in {
  packages = map (item: item.package) entries;
  metadata = map (item: item.metadata) entries;
}
