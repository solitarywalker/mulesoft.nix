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

  printf '%s\n' "$store" >"$base/.nix-store-path"
fi

# These come first so a caller can still add their own -data and the rest;
# Equinox takes the first occurrence of a location argument.
exec "$store/AnypointStudio" \
  -install "file:$base/install" \
  -configuration "$base/configuration" \
  "$@"
