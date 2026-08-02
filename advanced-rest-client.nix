# Advanced REST Client — MuleSoft's HTTP client, repackaged from the official
# Linux .deb.
#
# ARC is an Electron app whose sources are on GitHub, so building it from source
# looks tempting. It is not viable:
#
#   * The renderer is not in the tree. `npm run bundle:ui` (tasks/ui-build.js)
#     assembles it at prepare time out of ~90 @advanced-rest-client/* packages,
#     so reproducing it means re-resolving a 2022 dependency graph off npm.
#   * The main process is loaded through `esm` (standard-things/esm), a CommonJS
#     ESM shim abandoned in 2020. It monkey-patches V8 internals, and on any
#     modern Node it dies during load:
#
#         TypeError: Function.prototype.apply was called on undefined
#             at .../node_modules/esm/esm.js
#             at src/io/main.js:12
#
#     That is not a build problem but a runtime one, and it is what rules out the
#     usual nixpkgs trick of running upstream's app.asar under a current
#     pkgs.electron. Verified against nixpkgs' electron — ARC only starts under
#     the Electron 17 it ships with.
#
# So the bundled Electron stays, and the work is the usual prebuilt-Chromium
# chore: patch the interpreter and the RUNPATHs, then wrap.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  copyDesktopItems,
  dpkg,
  makeDesktopItem,
  makeWrapper,
  wrapGAppsHook3,

  # shell.openExternal() shells out to xdg-open; without it every "open in
  # browser" and every OAuth sign-in flow silently does nothing.
  #
  # It also makes start.js:148's app.setAsDefaultProtocolClient('arc-file')
  # reachable, and that prints one line of noise to stderr per launch:
  #
  #     xdg-mime: application argument missing
  #
  # The registration itself succeeds — ~/.config/mimeapps.list gets
  # x-scheme-handler/arc-file=advanced-rest-client.desktop. What fails is
  # xdg-settings' read-back check afterwards, which under Plasma queries a
  # source that does not reflect the write it just made; believing it failed, it
  # tries to restore the previous handler, and there was none, so it calls
  # `xdg-mime default "" x-scheme-handler/arc-file`. Cosmetic: the association
  # works, and nothing here caused it beyond making xdg-utils reachable at all.
  xdg-utils,

  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  libdrm,
  libGL,
  libgbm,
  libnotify,
  libpulseaudio,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libxshmfence,
  nspr,
  nss,
  pango,
  pciutils,
  systemdLibs,
}:

let
  # Chromium's dlopen()ed set: nothing here appears in any DT_NEEDED, so
  # autoPatchelfHook cannot discover them and buildInputs alone leaves them
  # unresolvable. They are appended to the RUNPATH of every ELF instead of going
  # onto LD_LIBRARY_PATH in the wrapper, which would also be inherited by
  # xdg-open and everything else ARC spawns.
  #
  # appendRunpaths rather than runtimeDependencies: the latter only extends the
  # RUNPATH of a file that has an unresolved DT_NEEDED to satisfy, so it reached
  # the main binary and stopped there — and a dlopen() resolves against the
  # RUNPATH of the *calling* object. libEGL.so, which is what actually loads
  # libGL, kept an empty RUNPATH and the GPU process died on every start with
  #
  #     ANGLE Display::initialize error 12289: Could not dlopen libGL.so.1
  #     Exiting GPU process due to errors during initialization
  #
  # falling back to software rendering (visible as a sluggish UI, not a crash).
  #
  # libGL/pciutils are ANGLE's, libnotify backs the Notification API, libsecret
  # backs safeStorage, systemdLibs is libudev for device and display hotplug,
  # libpulseaudio is the audio backend Chromium prefers before falling back to
  # ALSA.
  dlopenLibs = [
    libGL
    libnotify
    libpulseaudio
    libsecret
    pciutils
    systemdLibs
  ];
in

stdenv.mkDerivation (finalAttrs: {
  pname = "advanced-rest-client";
  version = "17.0.9";

  # The .deb rather than the tar.gz of the same release: electron-builder puts
  # the hicolor icon set and a desktop entry only in the distro packages, and its
  # tar.gz is 40 MB larger for the same tree.
  #
  # 17.0.9 (March 2022) is where this ends. ARC was retired — the repository is
  # archived and upstream now points people at Postman/Insomnia — so this version
  # is not a snapshot of a moving target, it is the last one there will be.
  src = fetchurl {
    url = "https://github.com/advanced-rest-client/arc-electron/releases/download/v${finalAttrs.version}/arc-linux-${finalAttrs.version}-amd64.deb";
    hash = "sha256-Cn30kJeCkwaVPjBz6XS8CvViZnPSn/dzomMXV1nTe+8=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    dpkg
    makeWrapper
    wrapGAppsHook3
  ];

  # gsettings-desktop-schemas carries schemas and no library; it is a buildInput
  # so that wrapGAppsHook3 puts it on GSETTINGS_SCHEMAS_PATH. Without it GTK's
  # file chooser aborts the app on the first "save response to file".
  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gsettings-desktop-schemas
    gtk3
    libdrm
    libgbm
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    libxshmfence
    nspr
    nss
    pango
    stdenv.cc.cc.lib
  ];

  appendRunpaths = map (drv: "${lib.getLib drv}/lib") dlopenLibs;

  # dpkg's unpack hook leaves the payload in ./root.
  sourceRoot = "root";

  dontConfigure = true;
  dontBuild = true;

  # wrapGAppsHook3 is here for the environment it computes, not its wrapping:
  # there is no binary in $out/bin at preFixup time for it to find. The one
  # wrapper is built by hand in postFixup, which is also the earliest point at
  # which gappsWrapperArgs is populated.
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/advanced-rest-client
    cp -r opt/AdvancedRestClient/. $out/share/advanced-rest-client

    # chrome-sandbox is the setuid sandbox helper, and nothing in the store can
    # be setuid, so this copy can never do the job it exists for.
    #
    # Removing it changes nothing observable: ARC starts and runs identically
    # either way (checked by putting a non-setuid copy back next to the binary).
    # The helper is simply never reached — Electron 17 launches renderers with
    # --no-sandbox by default, which `pgrep -af` confirms with the file present
    # as well as absent. It goes anyway, rather than ship a privileged-path
    # binary that cannot work.
    #
    # Worth knowing what that default means, though: ARC's renderers are not
    # sandboxed. That is upstream's doing — WindowsManager
    # .createBaseWindowOptions() leaves webPreferences.sandbox unset, and
    # Electron only began defaulting it to true in 20 — and it is not something
    # packaging can change without changing how the app runs.
    rm $out/share/advanced-rest-client/chrome-sandbox

    # electron-builder ships the whole payload mode 755, .pak data blobs and
    # locale files included. Only the two remaining ELF executables are programs.
    chmod -R a-x,a+rX $out/share/advanced-rest-client
    chmod +x $out/share/advanced-rest-client/{advanced-rest-client,chrome_crashpad_handler}

    cp -r usr/share/icons $out/share/icons

    runHook postInstall
  '';

  # --skip-app-update is not a preference, it is a correctness fix.
  # ApplicationUpdater.start() arms `setTimeout(() => this.check(), 5000)` with
  # electron-updater's autoDownload left at its default, so five seconds after
  # every launch ARC tries to fetch and install a release over its own install
  # directory. In the store that cannot work; and because the .deb ships no
  # resources/app-update.yml, the attempt does not even fail quietly — it raises
  # an updater error in the UI. The flag takes the branch that disables
  # autoDownload and autoInstallOnAppQuit and returns before the timer is set.
  # (For the record there is nothing to find: 17.0.9 is the final release.)
  #
  # Nothing else needs redirecting. ApplicationPaths.setHome() looks for a
  # portable ../.arc next to the executable, does not find one in the store, and
  # falls back to app.getPath('userData') — so settings, themes, workspace and
  # state all land under ~/.config/advanced-rest-client already.
  #
  # No Wayland flags on purpose. --ozone-platform-hint=auto, which the other
  # Electron packages here pass under NIXOS_OZONE_WL, arrived in Chromium 102;
  # this is Chromium 98, where it is an unknown switch. ARC runs on XWayland.
  postFixup = ''
    makeWrapper $out/share/advanced-rest-client/advanced-rest-client \
      $out/bin/advanced-rest-client \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}" \
      --add-flags "--skip-app-update"
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "advanced-rest-client";
      desktopName = "Advanced REST Client";
      genericName = "HTTP Client";
      comment = "Test and debug HTTP requests";
      exec = "advanced-rest-client %U";
      icon = "advanced-rest-client";
      terminal = false;
      categories = [
        "Development"
        "WebDevelopment"
      ];
      keywords = [
        "ARC"
        "HTTP"
        "REST"
        "API"
        "MuleSoft"
      ];
      # Registered in package.json's build.protocols and handled by
      # WindowsManager's second-instance hook, which is what %U above feeds.
      mimeTypes = [ "x-scheme-handler/arc-file" ];
      # Upstream's own .desktop in the .deb says AdvancedRestClient here, and
      # that is wrong: ARC never calls app.setName(), so Electron falls back to
      # the executable's basename. `wmctrl -lx` on a running window reports
      # advanced-rest-client.advanced-rest-client. With upstream's value the
      # window does not match this entry when pinned to a panel.
      startupWMClass = "advanced-rest-client";
    })
  ];

  meta = {
    description = "MuleSoft's desktop HTTP client for testing and debugging APIs";
    longDescription = ''
      Advanced REST Client (ARC) is a desktop HTTP client for designing,
      testing and debugging API requests, with request history, workspaces,
      environments and OAuth support.

      Upstream retired the project after ${finalAttrs.version}; this packages the
      final Linux release, which ships a bundled Electron ${"17"} and is
      therefore frozen on Chromium 98.
    '';
    homepage = "https://github.com/advanced-rest-client/arc-electron";
    downloadPage = "https://github.com/advanced-rest-client/arc-electron/releases";
    license = lib.licenses.asl20;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "advanced-rest-client";
  };
})
