# Anypoint Studio — MuleSoft's Eclipse-based IDE, repackaged from the official
# Linux tarball.
#
# There is nothing to build here: upstream ships a ~2.2 GB prebuilt Eclipse
# product with a bundled Temurin JDK and a bundled Equo Chromium (CEF). The work
# is entirely in making that tree run against nixpkgs' libraries and out of a
# read-only /nix/store.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  copyDesktopItems,
  makeDesktopItem,
  unzip,

  # launcher.sh builds the per-user install directory with these, so they cannot
  # be left to whatever PATH the desktop session happens to hand us. coreutils
  # is also patched into the design-time runtime's start script; see postPatch.
  coreutils,
  procps,

  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  dbus-glib,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  libGL,
  libGLU,
  libgbm,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxkbcommon,
  libxrandr,
  libxrender,
  libxtst,
  nspr,
  nss,
  pango,
  systemdLibs,
  wayland,
  webkitgtk_4_1,
  zlib,
}:

let
  # Two audiences for this list.
  #
  # As buildInputs it feeds autoPatchelfHook, which rewrites the ELF files that
  # actually sit on disk: the launcher, the Equo/CEF natives and the bundled JDK.
  #
  # As LD_LIBRARY_PATH it covers the ones that do not. SWT ships its natives
  # *inside* org.eclipse.swt.gtk.linux.x86_64_*.jar and extracts them to
  # ~/.swt/lib/linux/x86_64 on first launch — patchelf never sees those files, so
  # their DT_NEEDED (libgtk-3, libgdk-3, libGL, libGLU, …) has to resolve through
  # the search path instead. Same story for the libraries SWT and CEF dlopen by
  # soname at runtime rather than link against (libsecret, webkitgtk).
  runtimeLibs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    dbus-glib
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libGL
    libGLU
    libgbm
    libsecret
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxi
    libxkbcommon
    libxrandr
    libxrender
    libxtst
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    systemdLibs
    wayland
    webkitgtk_4_1
    zlib
  ];
in

stdenv.mkDerivation (finalAttrs: {
  pname = "anypoint-studio";
  version = "7.27.0";

  src = fetchurl {
    # The only host that serves this is www.mulesoft.com; the mule-studio S3
    # bucket behind it answers 403 to anonymous requests, so there is no mirror
    # to fall back on.
    #
    # Note the `latest/` path segment: it is not a floating "latest" redirect,
    # the version is in the file name and old versions stay reachable — but it is
    # upstream's own wording, and they have removed superseded builds before.
    # Should this 404 one day, the fix is a version bump, not a URL rewrite.
    url = "https://www.mulesoft.com/downloads/studio/latest/AnypointStudio-${finalAttrs.version}-linux64.tar.gz";
    hash = "sha256-M+Onn0aWy1Wr8DjNhyQ2ZLrNeTeUrvJhLVlMtQLc9oM=";

    # Akamai fronts the download and rejects curl's default User-Agent with 403,
    # and rejects a browser User-Agent on its own too — both headers are needed.
    # Homebrew's cask carries the same Referer for the macOS build.
    curlOptsList = [
      "--user-agent"
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
      "--referer"
      "https://www.mulesoft.com/lp/dl/anypoint-mule-studio"
    ];
  };

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    makeWrapper
    unzip
    wrapGAppsHook3
  ];

  # gsettings-desktop-schemas carries no library, only schemas; it is here rather
  # than in runtimeLibs so that wrapGAppsHook3 finds it on GSETTINGS_SCHEMAS_PATH
  # without a dead entry landing on LD_LIBRARY_PATH.
  buildInputs = runtimeLibs ++ [ gsettings-desktop-schemas ];

  # wrapGAppsHook3 is here for the GTK environment it computes (GSettings schemas,
  # the gdk-pixbuf loader cache, GIO modules) — not for its wrapping. There is no
  # executable in $out/bin for it to wrap; the single wrapper is built by hand in
  # postFixup so that it can also carry LD_LIBRARY_PATH.
  #
  # The wrapping happens in postFixup and not installPhase, because the hook only
  # fills gappsWrapperArgs from preFixup. Wrapping any earlier picks up an
  # all-but-empty array — the symptom is a wrapper with no XDG_DATA_DIRS, and a
  # workbench that dies on the first file dialog with "Settings schema
  # org.gtk.Settings.FileChooser is not installed".
  dontWrapGApps = true;

  dontConfigure = true;
  dontBuild = true;

  # Two bundles ship one native per supported platform and pick between them at
  # runtime by directory or file name, so on a Linux x86-64 machine every other
  # copy is dead weight. Dropping them is not just tidiness: autoPatchelfHook
  # decides what to patch from the ELF machine type alone, so it walks straight
  # into the Solaris and FreeBSD x86-64 binaries — same machine, different
  # OSABI — and dies when patchelf refuses them.
  postPatch = ''
    find plugins/com.sun.jna_*/com/sun/jna -mindepth 1 -maxdepth 1 -type d \
      ! -name linux-x86-64 -exec rm -rf {} +

    for tanuki in plugins/org.mule.tooling.server.*/mule/lib/boot/tanuki; do
      find "$tanuki" -maxdepth 1 -type f \
        \( -name 'libwrapper-*' ! -name 'libwrapper-linux-x86-64.so' \
           -o -name 'wrapper-windows-*' \) -delete
      find "$tanuki/exec" -maxdepth 1 -type f ! -name 'wrapper-linux-x86-64' -delete
    done

    # Deploying an application makes the tooling run the bundled runtime through
    # its Tanuki start script, and that script opens by locating `ps` and `tr` in
    # a fixed list of FHS directories. Unlike its lookup for `id` just above, the
    # list carries no empty entry, so $PATH is never consulted — and none of the
    # listed directories exist here. The deployment dies before it reaches Java:
    #
    #     Unable to locate ps.
    #     Please report this message along with the location of the command on your system.
    #
    # Prepending the store paths keeps the lookup independent of whatever PATH
    # the tooling hands the subprocess. The `case "$PS_BIN" in '/usr/bin/ps')`
    # branches further down are guarded by `$DIST_OS = solaris`; on Linux every
    # ps invocation takes the default branch, so an unrecognised path is fine.
    substituteInPlace plugins/org.mule.tooling.server.*/mule/bin/mule \
      --replace-fail 'resolveLocation PS_BIN ps "/usr/ucb;/usr/bin;/bin" 1' \
                     'resolveLocation PS_BIN ps "${procps}/bin;/usr/ucb;/usr/bin;/bin" 1' \
      --replace-fail 'resolveLocation TR_BIN tr "/usr/bin;/bin" 1' \
                     'resolveLocation TR_BIN tr "${coreutils}/bin;/usr/bin;/bin" 1'
  '';

  # Upstream's AnypointStudio.ini keeps the launcher pointed at the JDK it ships
  # in plugins/org.mule.tooling.jdk.linux.x86_64_*, and that is left alone on
  # purpose. It is not merely a bundled runtime the way Eclipse's JustJ is:
  # configuration/org.eclipse.equinox.simpleconfigurator/bundles.info registers it
  # as the OSGi bundle org.mule.tooling.jdk.linux.x86_64, and the tooling resolves
  # it from there to start the design-time Mule runtime. Swapping in pkgs.jdk17
  # would fix the -vm line and leave that bundle dangling, so instead the whole
  # Temurin 17.0.12 tree goes through autoPatchelfHook with everything else.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/anypoint-studio
    cp -r . $out/share/anypoint-studio

    # The top-level icon.xpm is the only icon outside a jar, and XPM is a poor
    # source for a modern icon theme. The branding bundle carries proper PNGs at
    # every hicolor size, so unpack those instead. (It also has @2x variants,
    # which are just the next size up under a macOS name — skip them.)
    for size in 16 32 48 64 128 256 512; do
      unzip -q -j -o $out/share/anypoint-studio/plugins/org.mule.tooling.branding_*.jar \
        "icons/branding/icon_''${size}x''${size}.png" -d icons
      install -Dm444 icons/icon_''${size}x''${size}.png \
        $out/share/icons/hicolor/''${size}x''${size}/apps/anypoint-studio.png
    done

    runHook postInstall
  '';

  # substituteAll reads @shell@/@out@/@version@ out of the builder environment, so
  # this attribute is what puts a shell in launcher.sh's shebang.
  shell = stdenv.shell;

  # launcher.sh, which postFixup instantiates below, exists for one reason:
  #
  # Studio refuses to run out of a read-only install directory, and it is not a
  # warning that can be clicked past: org.mule.tooling.utils.lifecycle
  # .LifeCycleManager#postContextCreate does
  #
  #     new File(Platform.getInstallLocation().getURL().toURI()).canWrite()
  #
  # and on false shows a modal whose only button is Exit, then System.exit(-1).
  # That is one canWrite() on the install directory itself — not a recursive
  # check, and nothing that inspects the files under it. So the install location
  # only has to *be* a writable directory; what it contains may stay in the store.
  #
  # Hence the symlink farm below: a per-user directory of symlinks to the store's
  # top-level entries, handed to Equinox as the install area. Nothing is copied.
  #
  # -install has to be passed explicitly. Pointing the launcher at a farm entry
  # instead does not work: the launcher derives the install area from the startup
  # jar and canonicalises the path, which follows plugins/ straight back into the
  # store and re-arms the dialog. (Verified both ways — -debug prints the install
  # location it settled on.)
  #
  # -configuration then moves Equinox's writable state out of the farm, and drags
  # the p2 data area with it: config.ini says eclipse.p2.data.area=@config.dir/../p2,
  # so with the configuration one level below the farm, p2 lands in $base/p2 rather
  # than on the read-only p2 symlink inside it.
  #
  # One bundle does have to be a real copy rather than a symlink. To run a project
  # at design time the tooling copies plugins/org.mule.tooling.server.*/mule into
  # configuration/org.eclipse.osgi/*/data/.runtimes/tooling-*, and it copies with
  # attributes preserved: from the store that yields a tree of mode-444 files,
  # which it then tries to write. The visible failure is
  #
  #     MuleControllerException: Error while initializing wrapper conf...
  #     Caused by: java.nio.file.AccessDeniedException: …/conf/wrapper.conf
  #
  # and the runtime instance marks itself Instance.invalid. Copying that one
  # bundle out of the store (~470 MB, once per build) makes the source 644 and the
  # copy inherits it.
  #
  # $base is version-scoped, and rebuilt from scratch whenever the store path moves
  # under it. Equinox's bundle cache in configuration/org.eclipse.osgi holds
  # absolute paths into the store, so a cache left over from a previous closure is
  # the usual cause of a workbench that will not start after an upgrade. Throwing
  # the whole directory away is cheap here — it holds no user data, the workspace
  # lives in ~/AnypointStudio/studio-workspace.
  #
  # That rebuild is also why launcher.sh, and not the user's Preferences, is where
  # the Equinox secure-storage password provider gets selected: the preference file
  # sits in $base/configuration and would be discarded on every upgrade. The
  # reasoning for the setting itself is at the point of use in launcher.sh.
  postFixup = ''
    mkdir -p $out/libexec
    substituteAll ${./launcher.sh} $out/libexec/anypoint-studio
    chmod +x $out/libexec/anypoint-studio

    makeWrapper $out/libexec/anypoint-studio $out/bin/anypoint-studio \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : "${lib.makeBinPath [ coreutils ]}" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeLibs}"
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "anypoint-studio";
      desktopName = "Anypoint Studio";
      comment = "Eclipse-based IDE for designing and testing Mule applications";
      exec = "anypoint-studio %F";
      icon = "anypoint-studio";
      categories = [
        "Development"
        "IDE"
      ];
      keywords = [
        "Mule"
        "MuleSoft"
        "Anypoint"
      ];
      # SWT derives WM_CLASS from the launcher's file name, which upstream keeps
      # as AnypointStudio regardless of what the wrapper in $out/bin is called.
      startupWMClass = "AnypointStudio";
    })
  ];

  meta = {
    description = "MuleSoft's Eclipse-based IDE for designing and testing Mule applications";
    homepage = "https://www.mulesoft.com/platform/studio";
    downloadPage = "https://www.mulesoft.com/lp/dl/anypoint-mule-studio";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [
      binaryNativeCode
      binaryBytecode
    ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "anypoint-studio";
  };
})
