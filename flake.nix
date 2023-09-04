{
  description = "compile_commands generation for the zig build system. flake only supports x86_64-linux.";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShell.${system} =
        pkgs.mkShell
          {
            packages = with pkgs; [
              zig_0_11
            ];
          };
    };
}
