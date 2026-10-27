{ pkgs }:
let
  artifacts = builtins.fromJSON (builtins.readFile ./artifacts.json);
in {
  aspect = pkgs.stdenvNoCC.mkDerivation {
    pname = "aspect-launcher";
    inherit (artifacts.aspect) version;
    src = pkgs.fetchurl { inherit (artifacts.aspect) url sha256; };
    dontUnpack = true;
    dontFixup = true;
    installPhase = ''
      install -Dm755 "$src" "$out/bin/aspect"
    '';
  };
  depot = pkgs.stdenvNoCC.mkDerivation {
    pname = "depot-cli";
    inherit (artifacts.depot) version;
    src = pkgs.fetchurl { inherit (artifacts.depot) url sha256; };
    sourceRoot = ".";
    dontFixup = true;
    installPhase = ''
      install -Dm755 bin/depot "$out/bin/depot"
    '';
  };
  node = pkgs.stdenvNoCC.mkDerivation {
    pname = "nodejs-bin";
    inherit (artifacts.node) version;
    src = pkgs.fetchurl { inherit (artifacts.node) url sha256; };
    # Ubuntu provides the ELF loader and libraries for this verified binary.
    dontFixup = true;
    installPhase = ''
      mkdir -p "$out"
      cp -a . "$out/"
    '';
  };
  coverage = pkgs.stdenvNoCC.mkDerivation {
    pname = "cargo-llvm-cov";
    inherit (artifacts.coverage) version;
    src = pkgs.fetchurl { inherit (artifacts.coverage) url sha256; };
    sourceRoot = ".";
    dontFixup = true;
    installPhase = ''
      install -Dm755 cargo-llvm-cov "$out/bin/cargo-llvm-cov"
    '';
  };
  uv = pkgs.stdenvNoCC.mkDerivation {
    pname = "uv";
    inherit (artifacts.uv) version;
    src = pkgs.fetchurl { inherit (artifacts.uv) url sha256; };
    dontFixup = true;
    installPhase = ''
      install -Dm755 uv "$out/bin/uv"
      install -Dm755 uvx "$out/bin/uvx"
    '';
  };
}
