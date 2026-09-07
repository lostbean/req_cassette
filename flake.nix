{
  description = "ReqCassette flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        toolchain-nixpkgs = if system == "x86_64-darwin" then nixpkgs else nixpkgs-unstable;

        unstable-packages = final: _prev: {
          unstable = import toolchain-nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        };

        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            unstable-packages
          ];
          config.allowUnfree = true;
        };

        isDarwin = builtins.match ".*-darwin" pkgs.stdenv.hostPlatform.system != null;

        shell = pkgs.mkShell {
          buildInputs =
            with pkgs;
            [
              unstable.beamMinimal29Packages.elixir_1_20
              unstable.beamMinimal29Packages.elixir-ls
              unstable.beamMinimal29Packages.erlang
              unstable.beamMinimal29Packages.rebar3
              unstable.livebook
              rebar3
              prettier
              ast-grep

            ]
            ++ (
              if isDarwin then
                [
                ]
              else
                [ ]
            );
          shellHook = ''
            echo "req cassette dev environment"
          '';
        };

      in
      {
        devShells.default = shell;
      }
    );
}
