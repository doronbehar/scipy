{
  description = "SciPy library main repository";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  # Using ?submodules=1 is annoying, and takes too long when one uses this
  # flake as a dependency with `url = "git+..."`. This UX is under work in Nix.
  # Unfortunately, we have to manually edit the revisions in those URLs to
  # match those in .git/modules/<submodule-path>/HEAD
  inputs.propack = {
    url = "github:scipy/PROPACK/cc32f3ba6cf941e4f9f96d96e2fc5762ea0c1014";
    flake = false;
  };
  inputs.unuran = {
    url = "github:scipy/unuran/a63d39160e5ecc4402e7ed0e8417f4c3ff9634cb";
    flake = false;
  };
  inputs.highs = {
    url = "github:scipy/highs/4a122958a82e67e725d08153e099efe4dad099a2";
    flake = false;
  };
  inputs.boost_math = {
    url = "github:boostorg/math/7203fa2def6347b0d5f8fe1e8522d5b0a618db9d";
    flake = false;
  };
  inputs.gitignore = {
    url = "github:hercules-ci/gitignore.nix";
    # Use the same nixpkgs
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self
    , nixpkgs
    , flake-utils
    , propack
    , unuran
    , highs
    , boost_math
    , gitignore
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
      version = "${versionBase}-${version_rev}-flake";
      # For calling ./pkg.nix
      inherit (gitignore.lib) gitignoreFilterWith;
      sharedBuildArgs = {
        src = lib.cleanSourceWith {
          filter = gitignoreFilterWith {
            basePath = ./.;
            extraRules = ''
              flake*
              ./azure-pipelines.yml
              ./ci/*
            '';
          };
          src = ./.;
        };
        inherit version versionAttrs;
        submodules = { 
          # Ideally this would have been parsed by .gitmodules
          "scipy/sparse/linalg/_propack/PROPACK" = propack;
          "scipy/_lib/unuran" = unuran;
          "scipy/_lib/highs" = highs;
          "scipy/_lib/boost_math" = boost_math;
        };
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
        pkgs.python3.pkgs.debugpy
        # To test debian packages
        pkgs.dpkg
        # To run `./dev.py`
        python.pkgs.pydevtool # See https://nixpk.gs/pr-tracker.html?pr=224484
        pkgs.python3.pkgs.rich-click
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
      # generate a `python` interpreter, with some python packages overriden
      pythonOverrides = self: super: {
        # See https://github.com/mesonbuild/meson-python/issues/321
        meson-python = super.meson-python.overridePythonAttrs(old: {
          patches = [
            # A fix for cross compilation https://github.com/mesonbuild/meson-python/pull/322
            (pkgs.fetchpatch {
              url = "https://github.com/mesonbuild/meson-python/commit/3678a77a7b6252e8fe8c984a3b2eba4b36d45417.patch";
              hash = "sha256-UmcniQ8mRpDKWYTpx3PUOxGWhett81tf5jOqBPo+dak=";
            })
          ];
        });
        # TODO: Add to nixpkgs
        pydevtool = super.python.pkgs.callPackage ./pydevtool.nix { };
        scipy = super.python.pkgs.callPackage ./pkg.nix (sharedBuildArgs // {
          inherit (self) meson-python;
        });
        scipy-tested = self.scipy.override {
          doCheck = true;
        };
      };
      python = (pkgs.python3.override {
        packageOverrides = pythonOverrides;
      }).overrideAttrs(old: {
        meta = old.meta // {
          description = "Python with a current scipy and patched meson-python";
        };
      });
      python-armv7l-hf-multiplatform = (pkgs.pkgsCross.armv7l-hf-multiplatform.python3.override {
        packageOverrides = pythonOverrides;
      }).overrideAttrs(old: {
        meta = old.meta // {
          description = "Python (cross compiled) with current scipy and patched meson-python";
        };
      });
      # Mostly copied from https://github.com/juliosueiras-nix/nix-utils, only
      # with support for specifying target package
      deb-rpm-shared-buildPhase = {pkg, targetArch}: ''
        export HOME=$PWD
        mkdir -p pkgtree/nix/store/
        mkdir -p pkgtree/bin
        for item in "$(cat ${pkgs.referencesByPopularity pkg})"; do
          cp -r $item pkgtree/nix/store/
        done

        cp -r ${pkg}/bin/* pkgtree/bin/

        chmod -R a+rwx pkgtree/nix
        chmod -R a+rwx pkgtree/bin
      '';
      # TODO: Actually support changing the architecture after
      buildRPM = {pkg, targetArch}: pkgs.stdenv.mkDerivation {
        name = "${pkg.name}.rpm";
        buildInputs = [
          pkgs.rpm
        ];
        unpackPhase = "true";
        buildPhase = (deb-rpm-shared-buildPhase {inherit pkg targetArch;}) + ''
          # TODO: Implement this
        '';
        installPhase = ''
          # TODO: Implement this
        '';
      };
      buildDeb = {pkg, targetArch}: pkgs.stdenv.mkDerivation {
        name = "${pkg.name}.deb";
        buildInputs = [
          pkgs.dpkg
        ];
        unpackPhase = "true";
        buildPhase = (deb-rpm-shared-buildPhase {inherit pkg targetArch;}) + ''
          mkdir pkgtree/DEBIAN
          cat << EOF > pkgtree/DEBIAN/control
          Package: ${pkg.name}
          Version: ${version}
          Maintainer: "Scipy developers"
        ''
        # TODO: Ideally we would parse `pkgs.stdenv.gcc.arch` or a similar
        # attribute and use this argument such that dpkg-deb will be
        # satisfied with our name of the platform.
        + ''
          Architecture: ${targetArch}
          Description: ${pkg.meta.description}
          EOF
        '';
        installPhase = ''
          dpkg-deb -b pkgtree
          mv pkgtree.deb $out
        '';
        meta = {
          description = "Debian package of ${pkg.name} compiled for architecture ${targetArch}";
        };
      };
    in {
      devShells = {
        default = pkgs.mkShell {
          inherit buildInputs propagatedBuildInputs;
          # nativeCheckInputs is not evaluated by pkgs.mkShell
          nativeBuildInputs = nativeBuildInputs ++ nativeCheckInputs;
        };
      };
      lib = {
        inherit
          buildDeb
          # From some reason, applying multiple packageOverrides on a python
          # interpreter applies only the latest packageOverrides (TODO: Open a
          # nixpkgs issue about this). Hence, we need to let other users of
          # this flake the ability to do the same as us in their `flake.nix`.
          pythonOverrides
        ;
      };
      packages = {
        inherit (python.pkgs)
          scipy
          scipy-tested
        ;
        scipy-armv7l-hf-multiplatform = python-armv7l-hf-multiplatform.pkgs.scipy;
        # No cross compiled tested scipy ofcourse
        pythonEnv = (python.withPackages(ps: [
          self.packages.${system}.scipy
        ])).overrideAttrs (old: {
          meta = old.meta // {
            description = "Python environment including ${self.packages.${system}.scipy.name}";
          };
        });
        pythonEnv-armv7l-hf-multiplatform = (python-armv7l-hf-multiplatform.withPackages(ps: [
          self.packages.${system}.scipy-armv7l-hf-multiplatform
        ])).overrideAttrs (old: {
          meta = old.meta // {
            description = "Python (cross compiled) environment including ${self.packages.${system}.scipy.name}";
          };
        });
        pythonEnv-armv7l-hf-multiplatform-with-tests = (python-armv7l-hf-multiplatform.withPackages(ps: [
          self.packages.${system}.scipy-armv7l-hf-multiplatform
          python-armv7l-hf-multiplatform.pkgs.pytest
          python-armv7l-hf-multiplatform.pkgs.pytest-cov
          python-armv7l-hf-multiplatform.pkgs.pytest-timeout
          python-armv7l-hf-multiplatform.pkgs.pytest-xdist
          python-armv7l-hf-multiplatform.pkgs.mpmath
          python-armv7l-hf-multiplatform.pkgs.gmpy2
          python-armv7l-hf-multiplatform.pkgs.threadpoolctl
          python-armv7l-hf-multiplatform.pkgs.pooch
          # This is missing from Nixpkgs at the moment
          #python-armv7l-hf-multiplatform.pkgs.scikit-umfpack
          #python-armv7l-hf-multiplatform.pkgs.asv
          python-armv7l-hf-multiplatform.pkgs.pydevtool
          python-armv7l-hf-multiplatform.pkgs.rich-click
        ])).overrideAttrs (old: {
          meta = old.meta // {
            description = "Python (cross compiled) environment including ${self.packages.${system}.scipy.name} and other testing dependencies";
          };
        });
        inherit
          python
          python-armv7l-hf-multiplatform
        ;
        # Debian packages
        pythonEnv-deb-native = buildDeb {
          pkg = self.packages.${system}.pythonEnv;
          targetArch = "amd64";
        };
        pythonEnv-deb-armv7l-hf-multiplatform = buildDeb {
          pkg = self.packages.${system}.pythonEnv-armv7l-hf-multiplatform;
          targetArch = "armhf";
        };
        pythonEnv-deb-armv7l-hf-multiplatform-with-tests = buildDeb {
          pkg = self.packages.${system}.pythonEnv-armv7l-hf-multiplatform-with-tests;
          targetArch = "armhf";
        };
      };
    }
  );
}
