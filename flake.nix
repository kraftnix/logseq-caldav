{
  description = "a tool to generate CalDAV Tasks and Calendar events from Logseq Tasks using Logseq's HTTP API";
  inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  inputs.flake-compat.url = "https://git.lix.systems/lix-project/flake-compat/archive/main.tar.gz";
  outputs = { self, nixpkgs, ... }: {
    packages.x86_64-linux.logseq-caldav = nixpkgs.legacyPackages.x86_64-linux.callPackage ./logseq-caldav.nix { };
    packages.x86_64-linux.default = self.packages.x86_64-linux.logseq-caldav;
  };
}
