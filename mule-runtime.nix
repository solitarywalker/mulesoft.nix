# Mule Runtime — MuleSoft's standalone integration server, repackaged from the
# Community Edition tarball on repository.mulesoft.org.
#
# There is nothing to compile: the distribution is jars plus a Tanuki Java
# Service Wrapper. The work is in the two places it assumes an FHS system — the
# start script's hunt for `ps`, and the wrapper binary's interpreter — and in
# getting a server that writes throughout its own installation directory to run
# out of a read-only /nix/store.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,

  # Mule 4.12's manifest declares Supported-Jdks [17,26) and Recommended-Jdks
  # [17,18),[21,26), so 21 is inside both. It is pinned rather than left to
  # whatever `java` the caller has on PATH, because bin/mule's fallback for an
  # unset JAVA_HOME is `which java` and a server should not change JVM because a
  # shell profile did. Override it if you need a different one:
  # mule-runtime.override { jdk21 = pkgs.jdk17; }
  jdk21,

  # bin/mule is a POSIX sh script that shells out for nearly everything, and it
  # is invoked from the wrapper below rather than from a login shell, so its
  # tools have to be put on PATH explicitly. gettext is only reached by the
  # `status` command, which formats its message through it.
  coreutils,
  gawk,
  gettext,
  gnugrep,
  gnused,
  procps,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "mule-runtime";
  version = "4.12.0";

  src = fetchurl {
    # The Community Edition distribution is a plain Maven artifact — no CDN, no
    # User-Agent games, unlike the Studio download. The Enterprise Edition
    # (mule-ee-distribution-standalone) lives in a credentialed repository and
    # needs a licence to run; this is the CE one.
    url = "https://repository.mulesoft.org/nexus/content/repositories/releases/org/mule/distributions/mule-standalone/${finalAttrs.version}/mule-standalone-${finalAttrs.version}.tar.gz";
    hash = "sha256-PYYK5gZgUe840e3/d4wRxMBndUuK0E8IgJ25n4+jhf8=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  dontConfigure = true;
  dontBuild = true;

  postPatch = ''
    # The wrapper ships one native per platform Tanuki supports and picks between
    # them at runtime from `uname`, so on Linux x86-64 every other copy is dead
    # weight. Dropping them is not tidiness: autoPatchelfHook decides what to
    # patch from the ELF machine type alone, so it walks straight into the
    # Solaris x86 and FreeBSD x86 binaries — same architecture, different
    # OSABI — and dies when patchelf refuses them.
    find lib/boot/tanuki -maxdepth 1 -type f \
      \( -name 'libwrapper-*' ! -name 'libwrapper-linux-x86-64.so' \
         -o -name 'wrapper-windows-*' \) -delete
    find lib/boot/tanuki/exec -maxdepth 1 -type f ! -name 'wrapper-linux-x86-64' -delete

    # bin/mule opens by locating `ps`, and looks in exactly three FHS directories
    # — /usr/ucb, /usr/bin, /bin — never consulting $PATH. None of them exist
    # here, so every invocation dies before it reaches Java:
    #
    #     Unable to locate 'ps'.
    #     Please report this message along with the location of the command on your system.
    #
    # Pointing the first candidate at the store leaves the fallbacks unreachable
    # and keeps the lookup independent of whatever PATH a caller has. The only
    # code that cares which `ps` this is sits behind `$DIST_OS = solaris`
    # branches in getpid()/testpid(); on Linux both take the default branch, so
    # an unrecognised path is fine there.
    substituteInPlace bin/mule \
      --replace-fail 'PSEXE="/usr/ucb/ps"' 'PSEXE="${procps}/bin/ps"'
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/mule-runtime
    cp -r . $out/share/mule-runtime

    runHook postInstall
  '';

  # substituteAll reads @shell@/@out@/@version@ out of the builder environment,
  # so this attribute is what puts a shell in the launcher's shebang.
  shell = stdenv.shell;

  # The launcher exists because Mule writes throughout MULE_HOME, and none of
  # those writes can be turned off from the outside:
  #
  #   conf/       bin/launcher regenerates wrapper-additional.conf here on every
  #               start, via lib/launcher/mule-wrapper-additional-parameters-parser.jar
  #   logs/       wrapper.conf points wrapper.logfile at %MULE_BASE%/logs
  #   apps/       deployment target, and where an app is exploded
  #   domains/    same, for domains
  #   .mule/      MuleFoldersUtil#getExecutionFolder — VM queues, tooling state
  #   lib/mule/repository
  #               RepositoryServiceFactory#createRepositoryFolder, which fails
  #               the container's construction outright if it cannot mkdir it:
  #                 java.lang.RuntimeException: Could not create dependencies folder
  #                 Caused by: java.nio.file.AccessDeniedException: …/lib/mule/repository
  #   .mule.pid   bin/mule sets PIDDIR to $MULE_BASE/.
  #
  # Upstream's own answer to a read-only installation is MULE_BASE, and it very
  # nearly works — MuleFoldersUtil resolves conf, logs, apps, domains, services
  # and .mule against it. But getMuleLibFolder() is MULE_HOME, so the dependency
  # repository above lands in the store no matter what MULE_BASE says, and only
  # a -Dmule.repository.folder override moves it. That override then leaves
  # lib/user — the directory the distribution's own README invites you to drop
  # jars into — and lib/mule-artifact-patches read-only in the store.
  #
  # So MULE_HOME points at a per-user farm of symlinks to the store instead,
  # exactly as anypoint-studio does for Equinox's install area. Every path above
  # is then a real directory in the farm, upstream's layout is intact, and
  # nothing is copied but conf/. See mule-runtime-launcher.sh for the details.
  postFixup = ''
    mkdir -p $out/libexec
    substituteAll ${./mule-runtime-launcher.sh} $out/libexec/mule
    chmod +x $out/libexec/mule

    makeWrapper $out/libexec/mule $out/bin/mule \
      --set JAVA_HOME "${jdk21}" \
      --prefix PATH : "${
        lib.makeBinPath [
          coreutils
          gawk
          gettext
          gnugrep
          gnused
          procps
        ]
      }"
  '';

  meta = {
    description = "MuleSoft's standalone runtime for deploying and running Mule applications";
    homepage = "https://www.mulesoft.com/platform/mule";
    downloadPage = "https://repository.mulesoft.org/nexus/content/repositories/releases/org/mule/distributions/mule-standalone/";
    license = lib.licenses.cpal10;
    sourceProvenance = with lib.sourceTypes; [
      binaryBytecode
      binaryNativeCode
    ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "mule";
  };
})
