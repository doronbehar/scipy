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
      };
    }
  );
}
