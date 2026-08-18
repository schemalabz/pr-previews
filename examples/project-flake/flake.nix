{
  description = "Minimal app flake exporting a previews attrset for pr-previews";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # Your production build — anything that yields a runnable store path.
      # It produces its OWN entrypoint: $out/bin/start references the node
      # from THIS flake's nixpkgs, so the preview runs the app on the
      # toolchain that built it (never on the preview host's toolchain).
      packages.${system}.myapp-prod = pkgs.buildNpmPackage {
        pname = "myapp-prod";
        version = "0.1.0";
        src = ./.;
        npmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        postInstall = ''
          mkdir -p $out/bin
          cat > $out/bin/start <<EOF
          #!${pkgs.runtimeShell}
          cd $out/lib/node_modules/myapp
          exec ${pkgs.nodejs}/bin/node dist/server.js
          EOF
          chmod +x $out/bin/start
        '';
      };

      # Consumed by the preview host:
      #   services.pr-previews.projects = myapp.previews;
      previews.myapp = {
        hostPattern = "pr-@id@.preview.example.com";
        basePort = 3000;
        startScript = _: ctx: ''
          exec "$APP_DIR/bin/start"
        '';
      };
    };
}
