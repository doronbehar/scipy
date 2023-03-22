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
      version = "${versionBase}-${version_rev}-flake";
      # For calling ./pkg.nix
      sharedBuildArgs = {
        src = self;
        inherit version versionAttrs;
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
      python = (pkgs.python3.override {
        packageOverrides = pythonOverrides;
      }).overrideAttrs(old: {
        meta = old.meta // {
          description = "Python with a not-yet-released patch to meson-python";
        };
      });
      python-armv7l-hf-multiplatform = (pkgs.pkgsCross.armv7l-hf-multiplatform.python3.override {
        packageOverrides = pythonOverrides;
      }).overrideAttrs(old: {
        meta = old.meta // {
          description = "Python (cross compiled) with a not-yet-released patch to meson-python";
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
          inherit nativeBuildInputs buildInputs propagatedBuildInputs nativeCheckInputs;
        };
      };
      # Build each package with:
      #
      #     nix build -L .?submodules=1\#$PKG
      packages = {
        scipy = python.pkgs.callPackage ./pkg.nix (sharedBuildArgs // {
        });
        scipy-tested = self.packages.${system}.scipy.override {
          doCheck = true;
        };
        scipy-armv7l-hf-multiplatform = python-armv7l-hf-multiplatform.pkgs.callPackage ./pkg.nix (sharedBuildArgs // {
        });
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
          python-armv7l-hf-multiplatform.pkgs.asv
          python-armv7l-hf-multiplatform.pkgs.mpmath
          python-armv7l-hf-multiplatform.pkgs.gmpy2
          python-armv7l-hf-multiplatform.pkgs.threadpoolctl
          python-armv7l-hf-multiplatform.pkgs.scikit-umfpack
          python-armv7l-hf-multiplatform.pkgs.pooch
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
          # TODO: Ideally we would parse `pkgs.stdenv.gcc.arch` or a similar
          # attribute and use this argument such that dpkg-deb will be
          # satisfied with our name of the platform.
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
