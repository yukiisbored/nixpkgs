{ stdenv, lib, stdenvNoCC
, pkgsBuildBuild, pkgsBuildHost, pkgsBuildTarget, pkgsHostHost, pkgsTargetTarget
, buildPackages, splicePackages, newScope
, bsdSetupHook, makeSetupHook, fetchcvs, groff, mandoc, byacc, flex
, zlib
, writeText, symlinkJoin
}:

let
  fetchOpenBSD = path: version: sha256: fetchcvs {
    cvsRoot = ":pserver:anoncvs@anoncvs.ca.openbsd.org:/cvsroot";
    module = "src/${path}";
    inherit sha256;
    tag = "OPENBSD_${lib.replaceStrings ["."] ["_"] version}";
  };

  otherSplices = {
    selfBuildBuild = pkgsBuildBuild.openbsd;
    selfBuildHost = pkgsBuildHost.openbsd;
    selfBuildTarget = pkgsBuildTarget.openbsd;
    selfHostHost = pkgsHostHost.openbsd;
    selfTargetTarget = pkgsTargetTarget.openbsd or {}; # might be missing
  };

in lib.makeScopeWithSplicing
  splicePackages
  newScope
  otherSplices
  (_: {})
  (_: {})
  (self: let
    inherit (self) mkDerivation;
  in {

  # Why do we have splicing and yet do `nativeBuildInputs = with self; ...`?
  #
  # We use `lib.makeScopeWithSplicing` because this should be used for all
  # nested package sets which support cross, so the inner `callPackage` works
  # correctly. But for the inline packages we don't bother to use
  # `callPackage`.
  #
  # We still could have tried to `with` a big spliced packages set, but
  # splicing is jank and causes a number of bootstrapping infinite recursions
  # if one is not careful. Pulling deps out of the right package set directly
  # side-steps splicing entirely and avoids those footguns.
  #
  # For non-bootstrap-critical packages, we might as well use `callPackage` for
  # consistency with everything else, and maybe put in separate files too.

  compatIfNeeded = lib.optional (!stdenvNoCC.hostPlatform.isOpenBSD) self.compat;

  mkDerivation = lib.makeOverridable (attrs: let
    stdenv' = if attrs.noCC or false then stdenvNoCC else stdenv;
  in stdenv'.mkDerivation ({
    name = "${attrs.pname or (baseNameOf attrs.path)}-openbsd-${attrs.version}";
    src = fetchOpenBSD attrs.path attrs.version attrs.sha256;

    extraPaths = [ ];

    nativeBuildInputs = with buildPackages.openbsd; [
      bsdSetupHook
      makeMinimal
      install tsort lorder mandoc groff statHook
    ];
    buildInputs = with self; compatIfNeeded;

    HOST_SH = stdenv'.shell;

    MACHINE_ARCH = {
      i486 = "i386";
      i586 = "i386";
      i686 = "i386";
    }.${stdenv'.hostPlatform.parsed.cpu.name}
      or stdenv'.hostPlatform.parsed.cpu.name;

    MACHINE = {
      x86_64 = "amd64";
      aarch64 = "arm64";
      i486 = "i386";
      i586 = "i386";
      i686 = "i386";
    }.${stdenv'.hostPlatform.parsed.cpu.name}
      or stdenv'.hostPlatform.parsed.cpu.name;

    BSD_PATH = attrs.path;

    strictDeps = true;

    meta = with lib; {
      maintainers = with maintainers; [ qbit ];
      platforms = platforms.unix;
      license = licenses.bsd2;
    };
  } // lib.optionalAttrs stdenv'.hasCC {
    # TODO should CC wrapper set this?
    CPP = "${stdenv'.cc.targetPrefix}cpp";
  } // lib.optionalAttrs stdenv'.isDarwin {
    MKRELRO = "no";
  } // lib.optionalAttrs (stdenv'.cc.isClang or false) {
    HAVE_LLVM = lib.versions.major (lib.getVersion stdenv'.cc.cc);
  } // lib.optionalAttrs (stdenv'.cc.isGNU or false) {
    HAVE_GCC = lib.versions.major (lib.getVersion stdenv'.cc.cc);
  } // lib.optionalAttrs (stdenv'.isx86_32) {
    USE_SSP = "no";
  } // lib.optionalAttrs (attrs.headersOnly or false) {
    installPhase = "includesPhase";
    dontBuild = true;
  } // attrs));

  ##
  ## START BOOTSTRAPPING
  ##
  makeMinimal = mkDerivation {
    path = "usr.bin/make";
    sha256 = "0fh0nrnk18m613m5blrliq2aydciv51qhc0ihsj4k63incwbk90n";
    version = "6.9";

    buildInputs = with self; [];
    nativeBuildInputs = with buildPackages.openbsd; [ bsdSetupHook ];

    skipIncludesPhase = true;

    postPatch = ''
      patchShebangs configure
      ${self.make.postPatch}
    '';
    buildPhase = ''
      runHook preBuild

      sh ./buildmake.sh

      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall

      install -D make $out/bin/make
      mkdir -p $out/share
      cp -r $BSDSRCDIR/share/mk $out/share/mk

      runHook postInstall
    '';
    extraPaths = with self; [ make.src ] ++ make.extraPaths;
  };

  # Don't add this to nativeBuildInputs directly.  Use statHook instead.
  stat = mkDerivation {
    path = "usr.bin/stat";
    version = "6.9";
    sha256 = "18nqwlndfc34qbbgqx5nffil37jfq9aw663ippasfxd2hlyc106x";
    nativeBuildInputs = with buildPackages.openbsd; [
      bsdSetupHook
      makeMinimal
      install mandoc groff
    ];
  };

  statHook = makeSetupHook {
    name = "openbsd-stat-hook";
  } (writeText "openbsd-stat-hook-impl" ''
    makeFlagsArray+=(TOOL_STAT=${self.stat}/bin/stat)
  '');

  ##
  ## END BOOTSTRAPPING
  ##

  ##
  ## START COMMAND LINE TOOLS
  ##

  make = mkDerivation {
    path = "usr.bin/make";
    sha256 = "09szl3lp9s081h7f3nci5h9zc78wlk9a6g18mryrznrss90q9ngx";
    version = "6.9";
    postPatch = ''
      # make needs this to pick up our sys make files
      export NIX_CFLAGS_COMPILE+=" -D_PATH_DEFSYSPATH=\"$out/share/mk\""

      substituteInPlace $BSDSRCDIR/share/mk/bsd.lib.mk \
        --replace '_INSTRANLIB=''${empty(PRESERVE):?-a "''${RANLIB} -t":}' '_INSTRANLIB='
      substituteInPlace $BSDSRCDIR/share/mk/bsd.kinc.mk \
        --replace /bin/rm rm
    '' + lib.optionalString stdenv.isDarwin ''
      substituteInPlace $BSDSRCDIR/share/mk/bsd.sys.mk \
        --replace '-Wl,--fatal-warnings' "" \
        --replace '-Wl,--warn-shared-textrel' ""
    '';
    postInstall = ''
      make -C $BSDSRCDIR/share/mk FILESDIR=$out/share/mk install
    '';
    extraPaths = [
      (fetchOpenBSD "share/mk" "6.9" "0qi3ypd5dsxk2c33885fsn68a550nibsxb1jwf5w6bfrvcblzn2z")
    ];
  };

  mtree = mkDerivation {
    path = "usr.sbin/mtree";
    version = "6.9";
    sha256 = "04p7w540vz9npvyb8g8hcf2xa05phn1y88hsyrcz3vwanvpc0yv9";
    extraPaths = with self; [ mknod.src ];
  };

  mknod = mkDerivation {
    path = "sbin/mknod";
    version = "6.9";
    sha256 = "1d9369shzwgixz3nph991i8q5vk7hr04py3n9avbfbhzy4gndqs2";
  };

  getent = mkDerivation {
    path = "usr.bin/getent";
    sha256 = "1qngywcmm0y7nl8h3n8brvkxq4jw63szbci3kc1q6a6ndhycbbvr";
    version = "6.9";
    patches = [ ./getent.patch ];
  };

  getconf = mkDerivation {
    path = "usr.bin/getconf";
    sha256 = "122vslz4j3h2mfs921nr2s6m078zcj697yrb75rwp2hnw3qz4s8q";
    version = "6.9";
  };

  locale = mkDerivation {
    path = "usr.bin/locale";
    version = "6.9";
    sha256 = "0kk6v9k2bygq0wf9gbinliqzqpzs9bgxn0ndyl2wcv3hh2bmsr9p";
    patches = [ ./locale.patch ];
    NIX_CFLAGS_COMPILE = "-DYESSTR=__YESSTR -DNOSTR=__NOSTR";
  };

  config = mkDerivation {
    path = "usr.bin/config";
    version = "6.9";
    sha256 = "08mqq0izd9550dwk181smni51cbiim7rwp208phf25c4mqzaznf4";
    NIX_CFLAGS_COMPILE = [ "-DMAKE_BOOTSTRAP" ];
    nativeBuildInputs = with buildPackages.openbsd; [
      bsdSetupHook
      makeMinimal install mandoc byacc flex
    ];
    buildInputs = with self; compatIfNeeded;
    extraPaths = with self; [ cksum.src ];
  };

  ##
  ## END COMMAND LINE TOOLS
  ##

  ##
  ## START HEADERS
  ##

  include = mkDerivation {
    path = "include";
    version = "6.9";
    sha256 = "127kj61prvj3klc2an5rpgavgah2g6igfgprl45255i264wyg8v3";
    nativeBuildInputs = with buildPackages.openbsd; [
      bsdSetupHook
      makeMinimal
      install mandoc groff nbperf rpcgen
    ];
    extraPaths = with self; [ common ];
    headersOnly = true;
    noCC = true;
    meta.platforms = lib.platforms.openbsd;
    makeFlags = [ "RPCGEN_CPP=${buildPackages.stdenv.cc.cc}/bin/cpp" ];
  };

  common = fetchOpenBSD "common" "6.9" "000n9frjm02h1bdwhb9rbr7wphs8vrj7n09l3v9hhnqrkn7nhy30";

  sys-headers = mkDerivation {
    pname = "sys-headers";
    path = "sys";
    version = "6.9";
    sha256 = "03sv6d7nvnkas4m5z87zxh1rpmggr91ls7di88fwc3cwd3mg3iyx";

    # Fix this error when building bootia32.efi and bootx64.efi:
    # error: PHDR segment not covered by LOAD segment
    patches = [ ./no-dynamic-linker.patch ];

    CONFIG = "GENERIC";

    propagatedBuildInputs = with self; [ include ];
    nativeBuildInputs = with buildPackages.openbsd; [
      bsdSetupHook
      makeMinimal install tsort lorder statHook uudecode config genassym
    ];

    postConfigure = ''
      pushd arch/$MACHINE/conf
      config $CONFIG
      popd
    '';

    makeFlags = [ "FIRMWAREDIR=$(out)/libdata/firmware" ];
    hardeningDisable = [ "pic" ];
    MKKMOD = "no";
    NIX_CFLAGS_COMPILE = [ "-Wa,--no-warn" ];

    postBuild = ''
      make -C arch/$MACHINE/compile/$CONFIG $makeFlags
    '';

    postInstall = ''
      cp arch/$MACHINE/compile/$CONFIG/openbsd $out
    '';

    meta.platforms = lib.platforms.openbsd;
    extraPaths = with self; [ common ];

    installPhase = "includesPhase";
    dontBuild = true;
    noCC = true;
  };

  # The full kernel. We do the funny thing of overridding the headers to the
  # full kernal and not vice versa to avoid infinite recursion -- the headers
  # come earlier in the bootstrap.
  sys = self.sys-headers.override {
    pname = "sys";
    installPhase = null;
    noCC = false;
    dontBuild = false;
  };

  headers = symlinkJoin {
    name = "openbsd-headers-6.9";
    paths = with self; [
      include
      sys-headers
      libpthread-headers
    ];
    meta.platforms = lib.platforms.openbsd;
  };
  ##
  ## END HEADERS
  ##

  ##
  ## START LIBRARIES
  ##
  libutil = mkDerivation {
    path = "lib/libutil";
    version = "6.9";
    sha256 = "02gm5a5zhh8qp5r5q5r7x8x6x50ir1i0ncgsnfwh1vnrz6mxbq7z";
    extraPaths = with self; [ common libc.src sys.src ];
    nativeBuildInputs = with buildPackages.openbsd; [
      bsdSetupHook
      makeMinimal
      byacc install tsort lorder mandoc statHook
    ];
    buildInputs = with self; [ headers ];
    SHLIBINSTALLDIR = "$(out)/lib";
  };

  libedit = mkDerivation {
    path = "lib/libedit";
    version = "6.9";
    sha256 = "1wqhngraxwqk4jgrf5f18jy195yrp7c06n1gf31pbplq79mg1bcj";
    buildInputs = with self; [ libterminfo libcurses ];
    propagatedBuildInputs = with self; compatIfNeeded;
    SHLIBINSTALLDIR = "$(out)/lib";
    makeFlags = [ "LIBDO.terminfo=${self.libterminfo}/lib" ];
    postPatch = ''
      sed -i '1i #undef bool_t' el.h
      substituteInPlace config.h \
        --replace "#define HAVE_STRUCT_DIRENT_D_NAMLEN 1" ""
      substituteInPlace readline/Makefile --replace /usr/include "$out/include"
    '';
    NIX_CFLAGS_COMPILE = [
      "-D__noinline="
      "-D__scanflike(a,b)="
      "-D__va_list=va_list"
    ];
  };

  libcurses = mkDerivation {
    path = "lib/libcurses";
    version = "6.9";
    sha256 = "0pd0dggl3w4bv5i5h0s1wrc8hr66n4hkv3zlklarwfdhc692fqal";
    buildInputs = with self; [ libterminfo ];
    NIX_CFLAGS_COMPILE = [
      "-D__scanflike(a,b)="
      "-D__va_list=va_list"
      "-D__warn_references(a,b)="
    ] ++ lib.optional stdenv.isDarwin "-D__strong_alias(a,b)=";
    propagatedBuildInputs = with self; compatIfNeeded;
    MKDOC = "no"; # missing vfontedpr
    makeFlags = [ "LIBDO.terminfo=${self.libterminfo}/lib" ];
    postPatch = lib.optionalString (!stdenv.isDarwin) ''
      substituteInPlace printw.c \
        --replace "funopen(win, NULL, __winwrite, NULL, NULL)" NULL \
        --replace "__strong_alias(vwprintw, vw_printw)" 'extern int vwprintw(WINDOW*, const char*, va_list) __attribute__ ((alias ("vw_printw")));'
      substituteInPlace scanw.c \
        --replace "__strong_alias(vwscanw, vw_scanw)" 'extern int vwscanw(WINDOW*, const char*, va_list) __attribute__ ((alias ("vw_scanw")));'
    '';
  };

  column = mkDerivation {
    path = "usr.bin/column";
    version = "6.9";
    sha256 = "0r6b0hjn5ls3j3sv6chibs44fs32yyk2cg8kh70kb4cwajs4ifyl";
  };


  libcrypt = mkDerivation {
    path = "lib/libcrypt";
    version = "6.9";
    sha256 = "0siqan1wdqmmhchh2n8w6a8x1abbff8n4yb6jrqxap3hqn8ay54g";
    SHLIBINSTALLDIR = "$(out)/lib";
    meta.platforms = lib.platforms.openbsd;
  };

  libpthread-headers = mkDerivation {
    pname = "libpthread-headers";
    path = "lib/libpthread";
    version = "6.9";
    sha256 = "0mlmc31k509dwfmx5s2x010wxjc44mr6y0cbmk30cfipqh8c962h";
    installPhase = "includesPhase";
    dontBuild = true;
    noCC = true;
    meta.platforms = lib.platforms.openbsd;
  };

  libpthread = self.libpthread-headers.override {
    pname = "libpthread";
    installPhase = null;
    noCC = false;
    dontBuild = false;
    buildInputs = with self; [ headers ];
    SHLIBINSTALLDIR = "$(out)/lib";
    extraPaths = with self; [ common libc.src librt.src sys.src ];
  };

  _mainLibcExtraPaths = with self; [
      common i18n_module.src sys.src
      ld_elf_so.src libpthread.src libm.src libresolv.src
      librpcsvc.src libutil.src librt.src libcrypt.src
  ];

  libc = mkDerivation {
    path = "lib/libc";
    version = "6.9";
    sha256 = "0jg6kpi1xn4wvlqpwnkcv8655hxi0nhcxbk8lzbj7mlr6srxci8j";
    USE_FORT = "yes";
    MKPROFILE = "no";
    extraPaths = with self; _mainLibcExtraPaths ++ [
      (fetchOpenBSD "external/bsd/jemalloc" "6.9" "0cq704swa0h2yxv4gc79z2lwxibk9k7pxh3q5qfs7axx3jx3n8kb")
    ];
    nativeBuildInputs = with buildPackages.openbsd; [
      bsdSetupHook
      makeMinimal
      install mandoc groff flex
      byacc genassym gencat lorder tsort statHook rpcgen
    ];
    buildInputs = with self; [ headers csu ];
    NIX_CFLAGS_COMPILE = "-B${self.csu}/lib";
    meta.platforms = lib.platforms.openbsd;
    SHLIBINSTALLDIR = "$(out)/lib";
    MKPICINSTALL = "yes";
    NLSDIR = "$(out)/share/nls";
    makeFlags = [ "FILESDIR=$(out)/var/db"];
    postInstall = ''
      pushd ${self.headers}
      find . -type d -exec mkdir -p $out/\{} \;
      find . \( -type f -o -type l \) -exec cp -pr \{} $out/\{} \;
      popd

      pushd ${self.csu}
      find . -type d -exec mkdir -p $out/\{} \;
      find . \( -type f -o -type l \) -exec cp -pr \{} $out/\{} \;
      popd

      NIX_CFLAGS_COMPILE+=" -B$out/lib"
      NIX_CFLAGS_COMPILE+=" -I$out/include"
      NIX_LDFLAGS+=" -L$out/lib"

      make -C $BSDSRCDIR/lib/libpthread $makeFlags
      make -C $BSDSRCDIR/lib/libpthread $makeFlags install

      make -C $BSDSRCDIR/lib/libm $makeFlags
      make -C $BSDSRCDIR/lib/libm $makeFlags install

      make -C $BSDSRCDIR/lib/libresolv $makeFlags
      make -C $BSDSRCDIR/lib/libresolv $makeFlags install

      make -C $BSDSRCDIR/lib/librpcsvc $makeFlags
      make -C $BSDSRCDIR/lib/librpcsvc $makeFlags install

      make -C $BSDSRCDIR/lib/i18n_module $makeFlags
      make -C $BSDSRCDIR/lib/i18n_module $makeFlags install

      make -C $BSDSRCDIR/lib/libutil $makeFlags
      make -C $BSDSRCDIR/lib/libutil $makeFlags install

      make -C $BSDSRCDIR/lib/librt $makeFlags
      make -C $BSDSRCDIR/lib/librt $makeFlags install

      make -C $BSDSRCDIR/lib/libcrypt $makeFlags
      make -C $BSDSRCDIR/lib/libcrypt $makeFlags install
    '';
    inherit (self.librt) postPatch;
  };
  #
  # END LIBRARIES
  #

  #
  # START MISCELLANEOUS
  #
  man = mkDerivation {
    path = "share/man";
    noCC = true;
    version = "6.9";
    sha256 = "14sfvz9a5x0kmr9ywsdz09jhw8r1cmhq45wrrz2xwy09b8ykhip6";
    makeFlags = [ "FILESDIR=$(out)/share" ];
  };
  #
  # END MISCELLANEOUS
  #

})
