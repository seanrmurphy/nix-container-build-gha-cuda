{
  description = "A basic flake using pyproject.toml project metadata - builds a CUDA docker image";

  inputs = {

    pyproject-nix = {
      url = "github:nix-community/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs = {
      url = "nixpkgs/nixos-23.11";
    };

  };

  outputs = { self, nixpkgs, pyproject-nix, ... }:
    let
      system = "x86_64-linux";
      revision = "${self.shortRev or "dirty"}";

      # Loads pyproject.toml into a high-level project representation
      # Do you notice how this is not tied to any `system` attribute or package sets?
      # That is because `project` refers to a pure data representation.
      project = pyproject-nix.lib.project.loadPyproject {
        # Read & unmarshal pyproject.toml relative to this project root.
        # projectRoot is also used to set `src` for renderers such as buildPythonPackage.
        projectRoot = ./.;
      };

      # This example is only using x86_64-linux

      # to add cuda stuff
      pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
            cudaCapabilities = [ "7.5" "8.6" ];
            cudaForwardCompat = false;
          };
      };

      # We are using the default nixpkgs Python3 interpreter & package set.
      #
      # This means that you are purposefully ignoring:
      # - Version bounds
      # - Dependency sources (meaning local path dependencies won't resolve to the local path)
      #
      # To use packages from local sources see "Overriding Python packages" in the nixpkgs manual:
      # https://nixos.org/manual/nixpkgs/stable/#reference
      #
      # Or use an overlay generator such as pdm2nix:
      # https://github.com/adisbladis/pdm2nix
      python = pkgs.python3;

      # Returns a function that can be passed to `python.withPackages`
      arg = project.renderers.withPackages { inherit python; };

      # Returns a wrapped environment (virtualenv like) with all our packages
      pythonEnv = python.withPackages arg;

      # Returns an attribute set that can be passed to `pkgs.buildPythonPackage`.
      attrs = project.renderers.buildPythonPackage { inherit python; };

      # Pass attributes to buildPythonPackage.
      # Here is a good spot to add on any missing or custom attributes.
      pythonPackage =  python.pkgs.buildPythonPackage (attrs);

      buildApplicationImage =
        let
          # we must somehow know something about the application here...
          port = "5000";
        in
        pkgs.dockerTools.buildLayeredImage
          {
            name = "nix-build-application-image-cuda";
            tag = revision;
            contents = [ pythonEnv pkgs.bash pkgs.findutils pkgs.uutils-coreutils-noprefix ];
            config = {
              Cmd = [
                # must know that the name of the application is app, as defined in the pyproject.toml file
                # in this case, the app is not using CUDA but it can...
                "${pythonPackage}/bin/app"
              ];
              ExposedPorts = {
                "${port}/tcp" = { };
              };
            };
          };

      buildPackageImage =
        pkgs.dockerTools.buildLayeredImage
          {
            name = "nix-build-package-image-cuda";
            tag = revision;
            # the pythonEnv is really just required here...the rest are handy utilities
            contents = [ pythonEnv pkgs.bash pkgs.findutils pkgs.uutils-coreutils-noprefix ];
            config = {
              # just run bash when the container starts; note that bash is only installed if the package is specified above 
              Cmd = [
                "${pkgs.bash}/bin/bash"
              ];
              # this is probably too static but it works
              Env = [ "LD_LIBRARY_PATH=/usr/lib64" ];
            };

            # when building a container image this way, no /tmp is created; this is required to make libs 
            # available from the host system to the container 
            # note that the leading slash MUST NOT be there; otherwise this does not work
            fakeRootCommands = ''
              #!${pkgs.runtimeShell}
              mkdir -p tmp
              chmod -R 1777 tmp
            '';
          };
    in
    {

      # Create a development shell containing dependencies from `pyproject.toml`
      devShells.${system}.default =
        # Create a devShell like normal.
        pkgs.mkShell {
          packages = [ pythonEnv ];
        };

      packages.${system} = {
        # default is built with `nix build`
        default = pythonPackage;

        # built with `nix build .#ociPackageImage`
        # the result is a gzip'd tarball - it can be imported to docker with `docker load < result` 
        ociPackageImage = buildPackageImage;

        # built with `nix build .#ociApplicationImage`
        # the result is a gzip'd tarball - it can be imported to docker with `docker load < result` 
        ociApplicationImage = buildApplicationImage;
      };

      # for `nix run`
      app.${system}.default = pythonPackage;

    };
}
