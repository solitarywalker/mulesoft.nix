#!@shell@
# Mule writes throughout MULE_HOME and cannot be told not to; mule-runtime.nix
# lists what writes where, and why MULE_BASE does not cover all of it. This
# builds the per-user installation directory it runs from instead: a farm of
# symlinks to the store, real only where something is actually written.
set -eu

store=@out@/share/mule-runtime
base=${XDG_DATA_HOME:-$HOME/.local/share}/mule-runtime/@version@

if [ "$(cat "$base/.nix-store-path" 2>/dev/null || true)" != "$store" ]; then
  # Unlike anypoint-studio's install area, this directory holds user data —
  # deployed applications, domains, edited configuration, logs — so it is
  # refreshed in place rather than thrown away. Everything that points into the
  # store is a symlink and is rebuilt; the real directories are left untouched.
  mkdir -p "$base/lib/mule" "$base/lib/user" "$base/conf" "$base/logs" \
           "$base/apps" "$base/domains"

  for entry in "$base"/* "$base"/lib/* "$base"/lib/mule/*; do
    if [ -L "$entry" ]; then
      rm -f "$entry"
    fi
  done

  for entry in "$store"/*; do
    case "${entry##*/}" in
      conf | logs | apps | domains | lib) continue ;;
    esac
    ln -s "$entry" "$base/"
  done

  # lib itself has to be a real directory for two of its children: lib/mule,
  # because Mule creates its dependency repository inside it and resolves that
  # path through MULE_HOME rather than MULE_BASE, and lib/user, because that is
  # where the distribution's README tells you to put your own jars. Everything
  # under them is still a symlink — 88 jars in lib/mule, none of them copied.
  for entry in "$store"/lib/*; do
    case "${entry##*/}" in
      mule | user) continue ;;
    esac
    ln -s "$entry" "$base/lib/"
  done

  ln -s "$store"/lib/mule/* "$base/lib/mule/"

  # conf is copied, not symlinked: bin/launcher writes wrapper-additional.conf
  # in here on every start, and wrapper.conf is where you are expected to tune
  # the JVM. Files that already exist are left alone so that tuning survives a
  # rebuild. Nothing is lost by that on an upgrade — $base is version-scoped, so
  # a new Mule version starts from its own defaults in a fresh directory.
  for entry in "$store"/conf/*; do
    [ -e "$base/conf/${entry##*/}" ] || cp "$entry" "$base/conf/"
  done
  chmod -R u+w "$base/conf"

  printf '%s\n' "$store" >"$base/.nix-store-path"
fi

# bin/mule falls back to deriving MULE_HOME from its own path, and it resolves
# symlinks while doing so — which would follow bin/ straight back into the store
# and undo all of the above. Setting it explicitly is what keeps the farm in
# play. MULE_BASE is left alone: the script defaults it to MULE_HOME, and the
# farm is already the writable directory MULE_BASE exists to provide.
export MULE_HOME=$base

exec "$store/bin/mule" "$@"
