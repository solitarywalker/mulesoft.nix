# mulesoft.nix

English | [日本語](./README_JP.md)

A Nix flake packaging MuleSoft tooling for NixOS.

| Package | What it is |
|---|---|
| `anypoint-studio` | MuleSoft's Eclipse-based IDE for Mule applications |
| `mule-runtime` | Mule Runtime CE, the standalone server that runs those applications |
| `advanced-rest-client` | ARC, MuleSoft's desktop HTTP client |

None is built from source — upstream ships prebuilt trees, and the work in every
case is making them run against nixpkgs' libraries and out of `/nix/store`.

## Usage

Anypoint Studio is proprietary, so the consuming configuration needs
`nixpkgs.config.allowUnfree = true`. Advanced REST Client is Apache-2.0 and Mule
Runtime CE is CPAL-1.0; neither needs anything special.

### Flake input

```nix
{
  inputs.mulesoft = {
    url = "github:solitarywalker/mulesoft.nix";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.flake-utils.follows = "flake-utils";
  };
}
```

Then either take the packages directly:

```nix
environment.systemPackages = with inputs.mulesoft.packages.${pkgs.system}; [
  anypoint-studio
  mule-runtime
  advanced-rest-client
];
```

or apply the overlay and use `pkgs.anypoint-studio`, `pkgs.mule-runtime` and
`pkgs.advanced-rest-client`:

```nix
nixpkgs.overlays = [ inputs.mulesoft.overlays.default ];
```

### Without installing

```console
$ nix run github:solitarywalker/mulesoft.nix                       # Anypoint Studio
$ nix run github:solitarywalker/mulesoft.nix#mule-runtime -- console
$ nix run github:solitarywalker/mulesoft.nix#advanced-rest-client
```

# Anypoint Studio

Upstream ships a ~2.2 GB Linux tarball with a bundled Temurin JDK and a bundled
Equo Chromium (CEF). There is nothing to compile; the work is in making that tree
run against nixpkgs' libraries, and in getting an application that refuses to run
from a read-only directory to run out of `/nix/store`.

## Where things live at runtime

| Path | Contents |
|---|---|
| `$XDG_DATA_HOME/anypoint-studio/<version>/install` | the install location Studio sees — symlinks into the store, plus one real copy (below) |
| `$XDG_DATA_HOME/anypoint-studio/<version>/configuration` | Equinox's configuration area and OSGi bundle cache |
| `$XDG_DATA_HOME/anypoint-studio/<version>/p2` | p2 profile registry |
| `~/AnypointStudio/studio-workspace` | the default workspace (upstream's own default, unchanged) |

The first directory is rebuilt from scratch whenever the store path changes, which
takes about a minute. Nothing in it is user data — the workspace is elsewhere — so
deleting it is always safe and is the first thing to try if Studio stops starting.

## What the package does

### The install directory has to be writable

`org.mule.tooling.utils.lifecycle.LifeCycleManager#postContextCreate` runs

```java
new File(Platform.getInstallLocation().getURL().toURI()).canWrite()
```

and on `false` opens a modal whose only button is **Exit**, then calls
`System.exit(-1)`. It is not a warning that can be clicked past.

That is a single `canWrite()` on the install directory itself — not recursive, and
it never looks at the files underneath. So the install location only has to *be* a
writable directory; its contents may stay in the store. The launcher therefore
builds a per-user directory of symlinks to the store's top-level entries and hands
it to Equinox as the install area. Nothing is copied.

`-install` has to be passed explicitly. Putting the launcher inside the symlink
directory and starting it from there does not work: the launcher derives the
install area from the startup jar and canonicalises the path, which follows
`plugins/` straight back into the store and re-arms the dialog.

`-configuration` then moves Equinox's writable state out of that directory, and
drags the p2 data area with it — `config.ini` sets
`eclipse.p2.data.area=@config.dir/../p2`, so with the configuration one level
below, p2 lands beside it rather than on the read-only `p2` symlink inside it.

### …and the bundled Mule runtime has to be writable too

To run a project at design time the tooling copies
`plugins/org.mule.tooling.server.*/mule` into its own data area — and copies it
with attributes preserved. From the store that produces a tree of mode-444 files,
which it then tries to write:

```
MuleControllerException: Error while initializing wrapper conf...
Caused by: java.nio.file.AccessDeniedException: …/conf/wrapper.conf
```

and the runtime instance marks itself `Instance.invalid`. That one bundle is
therefore copied out of the store (~470 MB, once per build) so the source is 644
and the copy inherits it. Its `org.mule.tooling.server.*.jar` siblings are
ordinary jars and stay symlinks.

### …and its start script looks for `ps` in the FHS

That same runtime is started through a Tanuki wrapper script, and the script
opens by locating `ps` and `tr` in a fixed list — `/usr/ucb`, `/usr/bin`, `/bin`.
Unlike its lookup for `id` a few lines above, the list carries no empty entry, so
`$PATH` is never consulted, and none of those directories exist here. Every
deployment ends before it reaches Java:

```
Unable to locate ps.
Please report this message along with the location of the command on your system.
```

`postPatch` prepends the `procps` and `coreutils` store paths to the two lists,
which keeps the lookup independent of whatever `PATH` the tooling hands the
subprocess. The `case "$PS_BIN" in '/usr/bin/ps')` branches further down in the
script are guarded by `$DIST_OS = solaris`; on Linux every `ps` invocation takes
the default branch, so an unrecognised path is fine there.

### The secure-storage password provider is pinned

Equinox picks the highest-priority secure-storage password provider available,
which is `org.eclipse.equinox.security.ui.defaultpasswordprovider` — the one that
asks for a master password in a modal dialog. Studio reads the Anypoint Platform
session from inside a CEF callback nested in the login dialog's own event loop:

```
SecurePreferences.put <- LoginManager.saveActiveAuthUser
                      <- WebLogin$5.changing
                      <- Chromium.lambda$17 <- Display.runAsyncMessages
                      <- Window.runEventLoop
```

Opening a second modal from there wedges the SWT UI thread. The dialog never
paints, and KWin — seeing a window that has stopped answering its ping — has
`kwin_killer_helper` SIGABRT the process once `KillPingTimeout` elapses. Studio
dies during startup with no `hs_err` and nothing in the workspace log; the core
dump has every thread parked in a syscall and `si_pid` pointing at the helper.

`launcher.sh` disables that provider. The bundle ships a second one —
`LinuxKeystoreIntegrationJNA` from `org.eclipse.equinox.security.linux` (priority
5, hint `AutomaticPasswordGeneration`), which would read the password from the
session's Secret Service over libsecret and never ask — but it does not appear in
the selector's candidate list on this build, and with nothing left the storage
fails outright rather than hanging:

```
StorageException: No secure storage modules found.
  at PasswordProviderSelector.findStorageModule(PasswordProviderSelector.java:220)
```

So the master password is supplied instead, through `-eclipse.password`, which
`SecurePreferencesMapper` accepts and uses directly without consulting any
provider. `launcher.sh` generates it once from `/dev/urandom` into
`$XDG_DATA_HOME/anypoint-studio/master-password`, mode 600 — beside `$base`, not
inside it, because `$base` is discarded on every upgrade and losing the password
would make the existing `secure_storage` undecryptable. Disabling the provider is
kept as a second line of defence so no dialog can reappear if the password is ever
not picked up.

Both live in `launcher.sh` rather than in the user's Preferences: the preference
file is in `$base/configuration` and would not survive an upgrade.

Anyone who can read the home directory can read both the password and the storage
it protects, which is no worse than Equinox's own default provider but is not a
keyring. Point `-eclipse.password` elsewhere, or drop it and re-enable the prompt,
if that trade is wrong for you.

### The bundled JDK is kept

Upstream's `AnypointStudio.ini` points `-vm` at
`plugins/org.mule.tooling.jdk.linux.x86_64_*`, and that is left alone. It is not
merely a bundled runtime the way Eclipse's JustJ is:
`configuration/org.eclipse.equinox.simpleconfigurator/bundles.info` registers it as
the OSGi bundle `org.mule.tooling.jdk.linux.x86_64`, and the tooling resolves it
from there to start the design-time Mule runtime — the log says
`Default JRE set: org.mule.tooling.jdk.linux.x86_64` on every start. Substituting
`pkgs.jdk17` would fix the `-vm` line and leave that bundle dangling, so the whole
Temurin 17.0.12 tree goes through `autoPatchelfHook` with everything else.

### Native libraries

`autoPatchelfHook` handles the ELF files that sit on disk. SWT's natives do not:
they ship *inside* `org.eclipse.swt.gtk.linux.x86_64_*.jar` and are extracted to
`~/.swt` on first launch, long after patchelf could have seen them. Those, and the
libraries SWT and CEF `dlopen` by soname, resolve through `LD_LIBRARY_PATH` on the
wrapper instead. `wrapGAppsHook3` supplies the GTK environment (GSettings schemas,
the gdk-pixbuf loader cache, GIO modules).

Before patching, the natives for every platform that is not Linux x86-64 are
dropped from the JNA and Tanuki bundles. Both pick their native by name at
runtime, so the rest is dead weight — and `autoPatchelfHook` decides what to patch
from the ELF machine type alone, so it walks into the Solaris and FreeBSD x86-64
binaries (same machine, different OSABI) and dies when patchelf refuses them.

### The download

```
https://www.mulesoft.com/downloads/studio/latest/AnypointStudio-<version>-linux64.tar.gz
```

Akamai fronts this and answers 403 to curl's default User-Agent — and to a browser
User-Agent on its own. Both a browser UA and a `Referer` are needed, so `fetchurl`
carries them in `curlOptsList`. The `mule-studio` S3 bucket behind the CDN is not
anonymously readable, so there is no mirror.

## Known limitations

- **Installing software into Studio** (Help → Install New Software, and Studio's
  own updater) writes into `plugins/`, which is a symlink into the store. It will
  fail. Adding connectors from Exchange is unaffected — that writes a Maven
  dependency into the project's `pom.xml`, not into the installation.
- **Tuning the JVM** by editing `AnypointStudio.ini` is not possible for the same
  reason. Pass VM arguments on the command line instead, e.g.
  `anypoint-studio -vmargs -Xmx4g`.
- x86-64 Linux only. Upstream also publishes an aarch64 macOS build; nothing here
  is written for it.

# Mule Runtime

Repackaged from the Community Edition `mule-standalone` tarball. There is nothing
native to speak of — the distribution is jars plus a Tanuki Java Service Wrapper —
so the work is in the two places it assumes an FHS system, and in getting a server
that writes throughout its own installation directory to run out of `/nix/store`.

```console
$ mule console          # foreground, Ctrl-C to stop
$ mule start | status | stop | restart | dump
```

## Where things live at runtime

| Path | Contents |
|---|---|
| `$XDG_DATA_HOME/mule-runtime/<version>` | the `MULE_HOME` the server actually runs from — symlinks into the store, plus the directories it writes to |
| `…/<version>/apps`, `…/domains` | deployment targets, and where artifacts are exploded |
| `…/<version>/conf` | upstream's configuration, copied once so it can be edited |
| `…/<version>/logs` | `mule.log` and the per-application logs |
| `…/<version>/lib/user` | the distribution's own drop-in directory for your jars |

That directory holds real user data, so — unlike Anypoint Studio's install area —
it is refreshed in place rather than rebuilt: on a new store path the symlinks are
recreated and everything else is left alone. It is version-scoped, so a version
bump starts from upstream's defaults in a fresh directory.

## What the package does

### The installation directory has to be writable

Mule writes throughout `MULE_HOME`, and none of it can be turned off from the
outside: `bin/launcher` regenerates `conf/wrapper-additional.conf` on every start,
`wrapper.conf` puts the wrapper log in `logs/`, applications are exploded into
`apps/`, `MuleFoldersUtil#getExecutionFolder` uses `.mule/`, and `bin/mule` puts
the pid file in the root.

Upstream's own answer to this is `MULE_BASE`, and it very nearly works —
`MuleFoldersUtil` resolves `conf`, `logs`, `apps`, `domains`, `services` and
`.mule` against it, so a read-only `MULE_HOME` gets most of the way. What stops it
is `RepositoryServiceFactory#createRepositoryFolder`, which resolves through
`getMuleLibFolder()` — `MULE_HOME`, not `MULE_BASE` — and takes the whole container
down with it when the `mkdir` fails:

```
java.lang.RuntimeException: Could not create dependencies folder with path …/lib/mule/repository
Caused by: java.nio.file.AccessDeniedException: …/lib/mule/repository
```

`-Dmule.repository.folder` moves that one directory, but then `lib/user` — which
the distribution's own README invites you to drop jars into — and
`lib/mule-artifact-patches` are still in the store.

So `MULE_HOME` points at a per-user farm of symlinks instead, the same shape
Anypoint Studio uses for Equinox's install area. Only `conf`, `logs`, `apps`,
`domains`, `lib/mule` and `lib/user` are real directories; everything else is a
symlink, and inside `lib/mule` all 88 jars are symlinks too. Nothing is copied but
`conf`, and existing files there are never overwritten, so tuning survives a
rebuild. `MULE_BASE` is then left alone — `bin/mule` defaults it to `MULE_HOME`,
which is already writable.

`MULE_HOME` has to be exported rather than inferred. `bin/mule` derives it from its
own path when unset, and resolves symlinks while doing so, which follows `bin/`
straight back into the store.

### …and the start script looks for `ps` in the FHS

`bin/mule` opens by locating `ps`, and looks in exactly three directories —
`/usr/ucb`, `/usr/bin`, `/bin` — never consulting `$PATH`. None of them exist here,
so every invocation dies before it reaches Java:

```
Unable to locate 'ps'.
Please report this message along with the location of the command on your system.
```

`postPatch` points the first candidate at the `procps` store path, which leaves the
fallbacks unreachable and keeps the lookup independent of whatever `PATH` a caller
has. The only code that cares which `ps` this is sits behind `$DIST_OS = solaris`
branches in `getpid()`/`testpid()`; on Linux both take the default branch.

The rest of the script shells out for nearly everything else too, and it is invoked
from a wrapper rather than a login shell, so coreutils, gawk, gettext, gnugrep,
gnused and procps go on its `PATH` explicitly. `gettext` is reached only by the
`status` command, which formats its message through it.

### The JDK is pinned

`jdk21`, set as `JAVA_HOME` on the wrapper. Mule 4.12's manifest declares
`Supported-Jdks: [17,26)` and `Recommended-Jdks: [17,18),[21,26)`, so 21 sits
inside both. Leaving it unset would fall through to `bin/mule`'s own `which java`,
and a server should not change JVM because a shell profile did. Override with
`mule-runtime.override { jdk21 = pkgs.jdk17; }`.

### Foreign Tanuki natives are dropped

The wrapper ships one native per platform Tanuki supports and picks between them
from `uname`, so on Linux x86-64 the rest is dead weight. Dropping them is not just
tidiness: `autoPatchelfHook` decides what to patch from the ELF machine type alone,
so it walks straight into the Solaris x86 and FreeBSD x86 binaries — same
architecture, different OSABI — and dies when patchelf refuses them.

### The download

```
https://repository.mulesoft.org/nexus/content/repositories/releases/org/mule/distributions/mule-standalone/<version>/mule-standalone-<version>.tar.gz
```

A plain Maven artifact — no CDN and no User-Agent games, unlike the Studio
download. The Enterprise Edition (`mule-ee-distribution-standalone`) lives in a
credentialed repository and needs a licence to run; this is the CE one.

## Known limitations

- **Community Edition.** No EE-only connectors, no clustering, no runtime manager
  agent, and Anypoint Studio projects that use EE features will not deploy here.
- **A version bump starts a fresh `MULE_HOME`.** The per-user directory is
  version-scoped so that `conf` always matches the runtime, which means deployed
  applications, domains and configuration edits do not carry across an upgrade.
  Copy `apps/` over by hand, or point `-Dmule.deployment…` elsewhere.
- x86-64 Linux only.

# Advanced REST Client

Repackaged from the official Linux `.deb` of **17.0.9** (March 2022), which is the
last release there will be: the project is retired and its repository archived.

Everything lands under `~/.config/advanced-rest-client` — `settings.json`,
`state.json`, `themes-esm/`, `workspace/`, `logs/` and Chromium's own profile
data. Nothing is written back into the store, so there is no launcher shim here of
the kind Anypoint Studio needs.

## What the package does

### The bundled Electron stays

The sources are on GitHub and the app is plain JavaScript, so the obvious moves
are to build it with `buildNpmPackage`, or at least to run upstream's `app.asar`
under a current `pkgs.electron`. Neither works.

The renderer is bundled by `npm run bundle:ui` out of ~90 `@advanced-rest-client/*`
packages that no longer resolve as they did in 2022. And the main process is
loaded through [`esm`](https://github.com/standard-things/esm), a CommonJS/ESM
shim abandoned in 2020 that monkey-patches V8 internals. Under a modern Electron
it dies during load, before any of ARC's own code runs:

```
App threw an error during load
TypeError: Function.prototype.apply was called on undefined
    at .../app.asar/node_modules/esm/esm.js:1:224377
    at Object.<anonymous> (.../app.asar/src/io/main.js:12:1)
```

So ARC only starts under the Electron 17 it ships with, and this is the usual
prebuilt-Chromium job instead: patch the interpreter and the RUNPATHs, then wrap.

### The `.deb`, not the `.tar.gz`

Both are published for the same release. electron-builder puts the hicolor icon
set and a desktop entry only in the distro packages, and its `tar.gz` is 40 MB
larger for the same tree.

### `chrome-sandbox` is removed

`chrome-sandbox` is the setuid sandbox helper, and nothing in the store can be
setuid, so this copy can never do the job it exists for.

Dropping it changes nothing observable — ARC starts and runs identically with a
non-setuid copy put back next to the binary. The helper is never reached, because
Electron 17 launches renderers with `--no-sandbox` by default, which `pgrep -af`
confirms with the file present as well as absent. It goes anyway rather than ship
a privileged-path binary that cannot work.

### ANGLE's `libGL` has to be on the right RUNPATH

`autoPatchelfHook` resolves `DT_NEEDED`; Chromium's `dlopen()` set is invisible to
it. The first attempt used `runtimeDependencies`, which only extends the RUNPATH
of a file that has an unresolved `DT_NEEDED` to satisfy — so it reached the main
binary and stopped. But a `dlopen()` resolves against the RUNPATH of the *calling*
object, and the caller is `libEGL.so`, whose RUNPATH was still empty:

```
ANGLE Display::initialize error 12289: Could not dlopen libGL.so.1
Exiting GPU process due to errors during initialization
```

That is not a crash — Chromium falls back to software rendering, so the symptom is
just a sluggish UI. `appendRunpaths` fixes it by appending to every ELF: libglvnd
and pciutils for ANGLE, libnotify for the Notification API, libsecret for
`safeStorage`, libudev for hotplug, libpulseaudio for audio.

### `--skip-app-update` is baked into the wrapper

`ApplicationUpdater.start()` arms `setTimeout(() => this.check(), 5000)` with
electron-updater's `autoDownload` at its default, so five seconds after every
launch ARC tries to fetch and install a release over its own install directory.
That cannot work in the store — and because the `.deb` ships no
`resources/app-update.yml`, it does not even fail quietly: it raises an updater
error in the UI. The flag takes the branch that disables `autoDownload` and
`autoInstallOnAppQuit` and returns before the timer is set. (There is nothing to
find in any case; 17.0.9 is final.)

## Known limitations

- **Frozen on Chromium 98, with unsandboxed renderers.** Electron 17 went
  end-of-life in 2022 and upstream is gone, so its accumulated CVEs are
  permanent. And `WindowsManager.createBaseWindowOptions()` leaves
  `webPreferences.sandbox` unset — Electron only began defaulting that to `true`
  in 20 — so every ARC renderer runs with `--no-sandbox`. That is upstream's
  choice, not this packaging's, and it cannot be changed from the outside without
  changing how the app runs. This is a tool that talks HTTP to whatever you point
  it at; treat it accordingly.
- **No Wayland-native mode.** `--ozone-platform-hint=auto`, which is how the other
  Electron packages here reach Wayland, arrived in Chromium 102. On 98 it is an
  unknown switch, so ARC runs on XWayland.
- **One line of noise per launch:**
  ```
  xdg-mime: application argument missing
  ```
  `start.js` calls `app.setAsDefaultProtocolClient('arc-file')`, and the
  registration does succeed — `~/.config/mimeapps.list` gets
  `x-scheme-handler/arc-file=advanced-rest-client.desktop`. What fails is
  `xdg-settings`' read-back check afterwards, which under Plasma queries a source
  that does not reflect the write it just made; believing it failed, it tries to
  restore the previous handler, and there was none.
- x86-64 Linux only.

## Licence

The flake is MIT (see [LICENSE](./LICENSE)). No application is redistributed
here — every derivation downloads from upstream at build time. Anypoint Studio is
proprietary MuleSoft software and is marked `unfree` accordingly; Mule Runtime CE
is CPAL-1.0 and Advanced REST Client is Apache-2.0.
