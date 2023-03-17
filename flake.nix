{
  description = "SciPy library main repository";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self
    , nixpkgs
    , flake-utils
  }:
  flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
      };
      inherit (pkgs) lib;
      version_utils = lib.splitString "\n" (builtins.readFile ./tools/version_utils.py);
      versionAttrs = lib.genAttrs ["MAJOR" "MINOR" "MICRO"] (part:
        builtins.replaceStrings ["${part} = "] [""] (builtins.elemAt
          (builtins.filter (s: lib.hasPrefix "${part} = " s) version_utils)
        0)
      );
      versionBase = "${versionAttrs.MAJOR}.${versionAttrs.MINOR}.${versionAttrs.MICRO}";
      # https://discourse.nixos.org/t/passing-git-commit-hash-and-tag-to-build-with-flakes/11355/2
      version_rev = if (self ? rev) then (builtins.substring 0 7 self.rev) else "dirty";
      # For calling ./pkg.nix
      sharedBuildArgs = {
        version = "${versionBase}-${version_rev}-flake";
        src = self;
        inherit versionAttrs;
      };
      # The rest is mostly for the devShell
      nativeBuildInputs = [
        pkgs.python3.pkgs.cython
        pkgs.gfortran
        pkgs.python3.pkgs.meson-python
        pkgs.python3.pkgs.pythran
        pkgs.pkg-config
        pkgs.python3.pkgs.wheel
        # For text editor
        pkgs.python3.pkgs.jedi-language-server
        # Currently broken
        #pkgs.python3.pkgs.debugpy
        # To test debian packages
        pkgs.dpkg
      ];
      buildInputs = [
        pkgs.python3.pkgs.numpy.blas
        pkgs.python3.pkgs.pybind11
        pkgs.libxcrypt
      ];
      propagatedBuildInputs = [
        pkgs.python3.pkgs.numpy
      ];
      nativeCheckInputs = [
        pkgs.python3.pkgs.nose
        pkgs.python3.pkgs.pytest
        pkgs.python3.pkgs.pytest-xdist
        pkgs.python3.pkgs.pooch
      ];
      # Override python packages, see:
      # https://github.com/mesonbuild/meson-python/issues/321
      pythonOverrides = self: super: {
        meson-python = super.meson-python.overridePythonAttrs(old: {
          patches = [
            # A fix for cross compilation https://github.com/mesonbuild/meson-python/pull/322
            (pkgs.fetchpatch {
              url = "https://github.com/mesonbuild/meson-python/commit/3678a77a7b6252e8fe8c984a3b2eba4b36d45417.patch";
              hash = "sha256-UmcniQ8mRpDKWYTpx3PUOxGWhett81tf5jOqBPo+dak=";
            })
          ];
        });
      };
      python = pkgs.python3.override {
        packageOverrides = pythonOverrides;
      };
      python-armv7l-hf-multiplatform = pkgs.pkgsCross.armv7l-hf-multiplatform.python3.override {
        packageOverrides = pythonOverrides;
      };
      # Mostly copied from https://github.com/juliosueiras-nix/nix-utils, only
      # with support for specifying target package
      deb-rpm-shared-buildPhase = {pkg, targetArch}: ''
        export HOME=$PWD
        mkdir -p ./nix/store/
        mkdir -p ./bin
        for item in "$(cat ${pkgs.lib.referencesByPopularity pkg})"; do
          cp -r $item ./nix/store/
        done

        cp -r ${pkg}/bin/* ./bin/

        chmod -R a+rwx ./nix
        chmod -R a+rwx ./bin
      '';
      buildRPM = {pkg, targetArch}: pkgs.stdenv.mkDerivation {
        name = "rpm-${pkg.name}";
        buildInputs = [
          pkgs.fpm
          pkgs.rpm
        ];
        unpackPhase = true;
        buildPhase = (deb-rpm-shared-buildPhase {inherit pkg targetArch;}) + ''
          fpm -s dir -t rpm --name ${pkg.name} nix bin
        '';

        installPhase = ''
          mkdir -p $out
          cp -r *.rpm $out
        '';
      };
      buildDeb = {pkg, targetArch}: pkgs.stdenv.mkDerivation {
        name = "deb-${pkg.name}";
        buildInputs = [
          pkgs.fpm
        ];
        unpackPhase = true;
        buildPhase = (deb-rpm-shared-buildPhase {inherit pkg targetArch;}) + ''
          fpm -s dir -t deb --name ${pkg.name} nix bin
        '';

        installPhase = ''
          mkdir -p $out
          cp -r *.deb $out
        '';
      };

    in {
      devShells = {
        default = pkgs.mkShell {
          inherit nativeBuildInputs buildInputs propagatedBuildInputs nativeCheckInputs;
        };
      };
      # Build each package with:
      #
      #     nix build -L .?submodules=1\#$PKG
      packages = {
        scipy = python.pkgs.callPackage ./pkg.nix (sharedBuildArgs // {
        });
        scipy-armv7l-hf-multiplatform = python-armv7l-hf-multiplatform.pkgs.callPackage ./pkg.nix (sharedBuildArgs // {
        });
        pythonEnv = python.withPackages(ps: [
          self.packages.${system}.scipy
        ]);
        pythonEnv-armv7l-hf-multiplatform = python-armv7l-hf-multiplatform.withPackages(ps: [
          self.packages.${system}.scipy-armv7l-hf-multiplatform
        ]);
        meson-python = python.pkgs.meson-python;
        pythonEnv-deb-native = buildDeb self.packages.${system}.pythonEnv;
        pythonEnv-deb-armv7l-hf-multiplatform = buildDeb {
          pkg = self.packages.${system}.pythonEnv;
          targetArch = pkgs.stdenv.linuxArch;
        };
        # For testing debian bundling - evaluating scipy everytime requires
        # submodules fetching etc and rebuilding scipy everytime. See also:
        # https://github.com/NixOS/nix/issues/6633#issuecomment-1472479052
        testEnv-armv7l-hf-multiplatform = python-armv7l-hf-multiplatform.withPackages(ps: [
          ps.requests
        ]);
        testEnv-deb-armv7l-hf-multiplatform = buildDeb {
          pkg = self.packages.${system}.pythonEnv;
          targetArch = pkgs.stdenv.linuxArch;
        };
      };
    }
  );
}
