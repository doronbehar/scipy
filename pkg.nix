{ lib
, stdenv
, src
, version
, versionAttrs
, buildPackages
, writeText
, python
, pythonOlder
, buildPythonPackage
, substituteAll
, cython
, gfortran
, meson
, meson-python
, pkg-config
, pythran
, wheel
, nose
, pytest
, pytest-xdist
, numpy
, pybind11
, pooch
, libxcrypt
}:

let
  cpuFamily = platform: with platform;
    /**/ if isAarch32 then "arm"
    else if isAarch64 then "aarch64"
    else if isx86_32  then "x86"
    else if isx86_64  then "x86_64"
    else platform.parsed.cpu.family + builtins.toString platform.parsed.cpu.bits;
  compilerPrefix = lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) "${stdenv.targetPlatform.config}-";
  crossFile = writeText "cross-file.conf" ''
    [properties]
    needs_exe_wrapper = ${lib.boolToString (!stdenv.buildPlatform.canExecute stdenv.hostPlatform)}

    [host_machine]
    system = '${stdenv.targetPlatform.parsed.kernel.name}'
    cpu_family = '${cpuFamily stdenv.targetPlatform}'
    cpu = '${stdenv.targetPlatform.parsed.cpu.name}'
    endian = ${if stdenv.targetPlatform.isLittleEndian then "'little'" else "'big'"}

    [build_machine]
    system = '${stdenv.buildPlatform.parsed.kernel.name}'
    cpu_family = '${cpuFamily stdenv.buildPlatform}'
    cpu = '${stdenv.buildPlatform.parsed.cpu.name}'
    endian = ${if stdenv.buildPlatform.isLittleEndian then "'little'" else "'big'"}

    [binaries]
    llvm-config = 'llvm-config-native'
    c = '${stdenv.cc}/bin/${compilerPrefix}gcc'
    cpp = '${stdenv.cc}/bin/${compilerPrefix}g++'
    strip = '${stdenv.cc}/bin/${compilerPrefix}strip'
    fortran = '${buildPackages.gfortran}/bin/${compilerPrefix}gfortran'
    pkg-config = '${buildPackages.pkg-config}/bin/${compilerPrefix}pkg-config'
  '';
in buildPythonPackage {
  pname = "scipy";
  inherit version;
  format = "pyproject";

  inherit src;

  # Mostly a copy of pipBuildHook, only with an additional --config-settings
  # handling cross compilation of meson being run by meson-python, see:
  # https://github.com/mesonbuild/meson-python/pull/167
  buildPhase = ''
    runHook preBuild

    echo "Running meson setup"
    mkdir -p build
    meson setup --cross-file=${crossFile} build

    echo "Creating a wheel..."
    mkdir -p dist
    ${python.pythonForBuild.interpreter} -m pip wheel \
      --verbose \
      --no-index \
      --no-deps \
      --no-clean \
      --no-build-isolation \
      --wheel-dir dist \
      --config-settings 'builddir=build' \
      .
    echo "Finished creating a wheel..."

    runHook postBuild
    echo "Finished executing pipBuildPhase"
  '';
  # NIX_DEBUG=6;

  nativeBuildInputs = [ cython gfortran meson-python pythran pkg-config wheel ];

  buildInputs = [
    numpy.blas
    pybind11
    pooch
  ] ++ lib.optionals (pythonOlder "3.9") [
    libxcrypt
  ];

  propagatedBuildInputs = [ numpy ];

  nativeCheckInputs = [ nose pytest pytest-xdist ];

  doCheck = !(stdenv.isx86_64 && stdenv.isDarwin);

  preConfigure = ''
    sed -i '0,/from numpy.distutils.core/s//import setuptools;from numpy.distutils.core/' setup.py
    export NPY_NUM_BUILD_JOBS=$NIX_BUILD_CORES
  '';

  # disable stackprotector on aarch64-darwin for now
  #
  # build error:
  #
  # /private/tmp/nix-build-python3.9-scipy-1.6.3.drv-0/ccDEsw5U.s:109:15: error: index must be an integer in range [-256, 255].
  #
  #         ldr     x0, [x0, ___stack_chk_guard];momd
  #
  hardeningDisable = lib.optionals (stdenv.isAarch64 && stdenv.isDarwin) [ "stackprotector" ];

  checkPhase = ''
    runHook preCheck
    pushd "$out"
    export OMP_NUM_THREADS=$(( $NIX_BUILD_CORES / 4 ))
    # Here 'python.pythonForBuild.interpreter' isn't required, as checkPhase is
    # used only when compiling nativly.
    ${python.interpreter} -c "import scipy; scipy.test('fast', verbose=10, parallel=$NIX_BUILD_CORES)"
    popd
    runHook postCheck
  '';

  requiredSystemFeatures = [ "big-parallel" ]; # the tests need lots of CPU time

  passthru = {
    blas = numpy.blas;
    inherit versionAttrs;
    inherit crossFile;
  };

  setupPyBuildFlags = [ "--fcompiler='gnu95'" ];

  SCIPY_USE_G77_ABI_WRAPPER = 1;

  meta = with lib; {
    description = "SciPy (pronounced 'Sigh Pie') is open-source software for mathematics, science, and engineering";
    homepage = "https://www.scipy.org/";
    license = licenses.bsd3;
  };
}
