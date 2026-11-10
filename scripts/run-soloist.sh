#!/usr/bin/env bash
set -euo pipefail

# Launches Spotify Soloist, Spotify's official headless Spotify Connect client,
# as the plugin's playback device. setup-soloist.sh installs a copy of this
# file next to the other runtime files, so it must not depend on the plugin
# checkout. Nothing here prints the API key.

runtime_dir=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
state_root=${XDG_STATE_HOME:-"$HOME/.local/state"}
cache_root=${XDG_CACHE_HOME:-"$HOME/.cache"}
config_file="$config_root/omarchy-spotify/spotifyd.conf"
key_file="$config_root/omarchy-spotify/soloist-api-key"

soloist_binary() {
  if [[ -x $runtime_dir/soloist/soloist ]]; then
    printf '%s\n' "$runtime_dir/soloist/soloist"
  else
    command -v soloist 2>/dev/null
  fi
}

binary=$(soloist_binary) || {
  echo "run-soloist.sh: Spotify Soloist is not installed" >&2
  exit 78
}

[[ -s $key_file ]] || {
  echo "run-soloist.sh: no Soloist API key is stored; run setup-soloist.sh" >&2
  exit 78
}
# Read the first line only and drop surrounding whitespace, so a pasted
# trailing newline or space cannot become part of the key.
IFS= read -r api_key <"$key_file" || true
api_key=${api_key//[[:space:]]/}
[[ -n $api_key ]] || {
  echo "run-soloist.sh: the stored Soloist API key is empty" >&2
  exit 78
}

# The plugin keeps the device name in its playback config. Use the same value
# so the plugin recognises the Soloist device as this computer.
device_name=""
if [[ -f $config_file ]]; then
  device_name=$(sed -n 's/^device_name[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' \
    "$config_file" | head -n 1)
fi
device_name=${device_name:-"Omarchy Spotify"}

data_dir="$state_root/omarchy-spotify/soloist"
cache_dir="$cache_root/omarchy-spotify/soloist"
install -d -m 700 -- "$data_dir" "$cache_dir"

exec "$binary" \
  --device-name "$device_name" \
  --api-key "$api_key" \
  --data-dir "$data_dir" \
  --cache-dir "$cache_dir" \
  --cache-size 1000 \
  "$@"
