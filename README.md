# mulesoft.nix

English | [日本語](./README_JP.md)

A Nix flake packaging MuleSoft tooling for NixOS. Currently one package:
**Anypoint Studio**, MuleSoft's Eclipse-based IDE for Mule applications.

Upstream ships a ~2.2 GB Linux tarball with a bundled Temurin JDK and a bundled
Equo Chromium (CEF). There is nothing to compile; the work is in making that tree
run against nixpkgs' libraries, and in getting an application that refuses to run
from a read-only directory to run out of `/nix/store`.

## Usage

Anypoint Studio is proprietary, so the consuming configuration needs
`nixpkgs.config.allowUnfree = true`.

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

Then either take the package directly:

```nix
environment.systemPackages = [
  inputs.mulesoft.packages.${pkgs.system}.anypoint-studio
];
```

or apply the overlay and use `pkgs.anypoint-studio`:

```nix
nixpkgs.overlays = [ inputs.mulesoft.overlays.default ];
```

### Without installing

```console
$ nix run github:solitarywalker/mulesoft.nix
```

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

## Licence

The flake is MIT (see [LICENSE](./LICENSE)). Anypoint Studio itself is proprietary
MuleSoft software, redistributed by nobody here — the derivation downloads it from
MuleSoft at build time, and is marked `unfree` accordingly.
