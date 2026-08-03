#!@shell@
# Studio's install location has to be a writable directory, and the Mule runtime
# it ships has to be readable *and* writable. See anypoint-studio.nix for why.
# Both are arranged here, once, in a per-user directory outside the store.
set -eu

store=@out@/share/anypoint-studio
base=${XDG_DATA_HOME:-$HOME/.local/share}/anypoint-studio/@version@

if [ "$(cat "$base/.nix-store-path" 2>/dev/null || true)" != "$store" ]; then
  echo "anypoint-studio: preparing $base (first run of this build, ~1 min)" >&2
  rm -rf "$base"
  mkdir -p "$base/install/plugins"

  for entry in "$store"/*; do
    [ "$entry" = "$store/plugins" ] || ln -s "$entry" "$base/install/"
  done

  for plugin in "$store"/plugins/*; do
    case "$plugin" in
      # The tooling copies this bundle's mule/ tree into its own data area to run
      # the design-time runtime, and copies it with attributes preserved — so a
      # 444 source produces a 444 copy that it then fails to write to. It is the
      # one bundle that has to arrive as real, writable files. Its siblings
      # org.mule.tooling.server.*.jar are ordinary jars and stay symlinks, hence
      # the -d test.
      */org.mule.tooling.server.*)
        if [ -d "$plugin" ]; then
          cp -r --no-preserve=mode "$plugin" "$base/install/plugins/"
          continue
        fi
        ;;
    esac
    ln -s "$plugin" "$base/install/plugins/"
  done

  # Equinox picks the highest-priority secure-storage password provider it can
  # see, and that is org.eclipse.equinox.security.ui.defaultpasswordprovider —
  # the one that asks for a master password in a modal dialog. Studio then reads
  # the Anypoint Platform session from inside a CEF callback that is itself
  # nested in the login dialog's event loop:
  #
  #     SecurePreferences.put <- LoginManager.saveActiveAuthUser
  #                           <- WebLogin$5.changing
  #                           <- Chromium.lambda$17 <- Display.runAsyncMessages
  #                           <- Window.runEventLoop
  #
  # Opening a second modal from there wedges the SWT UI thread: the dialog never
  # paints, and KWin — which sees a window that stops answering its ping — has
  # kwin_killer_helper SIGABRT the process once KillPingTimeout elapses. Studio
  # dies during startup with no hs_err and no Java-level error; the core dump has
  # every thread parked in a syscall and si_pid pointing at the helper.
  #
  # So that provider is disabled here. The bundle ships a second one —
  # LinuxKeystoreIntegrationJNA from org.eclipse.equinox.security.linux, which
  # would take the password from the session's Secret Service over libsecret and
  # never ask — but it does not turn up in the selector's candidate list on this
  # build, and with nothing left storage fails outright:
  #
  #     StorageException: No secure storage modules found.
  #       at PasswordProviderSelector.findStorageModule(PasswordProviderSelector.java:220)
  #
  # which costs the Anypoint Platform session instead of hanging. The password
  # below is what actually keeps storage working; disabling the provider is kept
  # as the belt to that braces, so a dialog cannot reappear if the password is
  # ever not picked up.
  #
  # The key name and its ConfigurationScope location are what
  # org.eclipse.equinox.internal.security.storage.PasswordProviderSelector reads.
  # This file lives under $base, so it goes wherever $base goes — hence writing it
  # here rather than leaving it to Preferences, which would be lost on the next
  # build. Removing the line restores upstream behaviour (and the hang).
  mkdir -p "$base/configuration/.settings"
  cat >"$base/configuration/.settings/org.eclipse.equinox.security.prefs" <<'PREFS'
eclipse.preferences.version=1
org.eclipse.equinox.security.preferences.disabledProviders=org.eclipse.equinox.security.ui.defaultpasswordprovider
PREFS

  printf '%s\n' "$store" >"$base/.nix-store-path"
fi

# With no password provider left, something has to supply the secure storage's
# master password, and org.eclipse.equinox.internal.security.storage
# .SecurePreferencesMapper takes one from -eclipse.password. A password given that
# way is used directly and the providers are never consulted, so there is nothing
# left to open a dialog.
#
# The file sits beside $base rather than inside it: $base is thrown away whenever
# the store path moves, and losing the password would make the existing
# ~/.eclipse/org.eclipse.equinox.security/secure_storage undecryptable on the next
# upgrade. It is generated once, from urandom, and readable only by its owner —
# which is the same protection the storage file itself gets, and no worse than
# Equinox's own default provider. Anyone who can read the home directory can read
# both; use a real keyring instead if that is not acceptable.
pwfile=${XDG_DATA_HOME:-$HOME/.local/share}/anypoint-studio/master-password
if [ ! -f "$pwfile" ]; then
  mkdir -p "$(dirname "$pwfile")"
  (umask 077; head -c 32 /dev/urandom | base64 >"$pwfile")
fi

# These come first so a caller can still add their own -data and the rest;
# Equinox takes the first occurrence of a location argument.
exec "$store/AnypointStudio" \
  -install "file:$base/install" \
  -configuration "$base/configuration" \
  -eclipse.password "$pwfile" \
  "$@"
