{
  description = "Swift development environment with LSP and tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs"; # Use the latest stable channel
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }: flake-utils.lib.eachDefaultSystem (system: let
    pkgs = import nixpkgs { inherit system; };

  in {
    devShell = pkgs.mkShell {
      name = "swift-dev-env";

      packages = with pkgs; [
        swift           # Swift compiler and standard tools
        sourcekit-lsp   # Language server for Swift
        swiftformat     # Formatter for Swift code
        git             # Version control system
        clang           # For building C dependencies
        cmake           # Build system, required for some Swift packages
        pkg-config      # Needed for resolving dependencies
      ];

      # Environment variables for better tool integration
      shellHook = ''
        export PATH=$PATH:${pkgs.sourcekit-lsp}/bin
        echo "Swift development environment is ready!"
      '';
    };
  });
}
