{
  description = "a tool to generate CalDAV Tasks and Calendar events from Logseq Tasks using Logseq's HTTP API";
  inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  inputs.flake-compat.url = "https://git.lix.systems/lix-project/flake-compat/archive/main.tar.gz";
  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in 
    {
      packages.${system} = {
        logseq-caldav = pkgs.callPackage ./logseq-caldav.nix { };
        default = self.packages.x86_64-linux.logseq-caldav;
      };
      overlays.default = final: prev: {
        logseq-caldav = self.packages.${final.stdenv.hostPlatform.system}.logseq-caldav;
      };
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nushell
          vdirsyncer
          pimsync
          difftastic
        ];
      };
    };
}
