{
  description = "ReqCassette flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
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
        unstable-packages = final: _prev: {
          unstable = import nixpkgs-unstable {
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
              unstable.beamMinimal28Packages.elixir_1_20
              unstable.beamMinimal28Packages.elixir-ls
              unstable.beamMinimal28Packages.erlang
              unstable.beamMinimal28Packages.rebar3
              unstable.livebook
              rebar3
              nodePackages.prettier
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
