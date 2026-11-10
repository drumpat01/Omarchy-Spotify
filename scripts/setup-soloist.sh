#!/usr/bin/env bash
set -euo pipefail

# Sets up Spotify Soloist, Spotify's official headless Spotify Connect client,
# as this plugin's playback device. Use it when the built-in backend cannot
# play because Spotify refuses its audio keys ("error audio key 0 1").
#
# Soloist is proprietary. Spotify's terms forbid redistributing it, so this
# plugin never ships it: you download it from Spotify yourself, or pass
# --download to fetch it from Spotify's own server.

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
official_url_base="https://soloist-builds.spotifycdn.com"
downloads_page="https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates"
key_page="https://developer.spotify.com/dashboard/soloist"

archive=""
download=0
pair=0
replace_key=0

usage() {
  cat <<EOF
Usage: scripts/setup-soloist.sh [--download | --archive FILE] [--replace-key] [--pair]

  --download      Fetch the current Soloist build from Spotify's server.
  --archive FILE  Install a Soloist archive you downloaded yourself from
                  $downloads_page
  --replace-key   Ask for a new Soloist API key even when one is stored.
  --pair          After setup, wait for a Spotify app on this network to
                  select the device once, so Soloist can store its session.

With neither --download nor --archive, an already installed Soloist is used
(from the plugin's runtime directory or your PATH). Run it again with
--download to replace a build that has expired after 90 days.
EOF
}

while (( $# > 0 )); do
  case $1 in
    --download) download=1; shift ;;
    --archive)
      [[ $# -ge 2 ]] || { echo "setup-soloist.sh: --archive requires a file" >&2; exit 2; }
      archive=$2
      shift 2
      ;;
    --replace-key) replace_key=1; shift ;;
    --pair) pair=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "setup-soloist.sh: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done
if (( download )) && [[ -n $archive ]]; then
  echo "setup-soloist.sh: use either --download or --archive, not both" >&2
  exit 2
fi

runtime_dir=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
config_dir="$config_root/omarchy-spotify"
config_file="$config_dir/spotifyd.conf"
key_file="$config_dir/soloist-api-key"
unit_dir="$config_root/systemd/user"
unit_file="$unit_dir/omarchy-spotify-soloist.service"
soloist_dir="$runtime_dir/soloist"
launcher="$runtime_dir/run-soloist.sh"

work_dir=""
cleanup() { [[ -z $work_dir ]] || rm -rf -- "$work_dir"; }
trap cleanup EXIT

install_archive() {
  local source_archive=$1 found
  work_dir=$(mktemp -d)
  # Refuse entries that would escape the extraction directory.
  if tar -tzf "$source_archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "setup-soloist.sh: the archive contains unsafe paths" >&2
    exit 1
  fi
  tar -xzf "$source_archive" -C "$work_dir" --no-same-owner
  found=$(find "$work_dir" -type f -name soloist -print -quit)
  [[ -n $found ]] || {
    echo "setup-soloist.sh: the archive does not contain a soloist executable" >&2
    exit 1
  }
  install -d -m 700 -- "$runtime_dir" "$soloist_dir"
  install -m 755 -- "$found" "$soloist_dir/soloist"
}

if (( download )); then
  case $(uname -m) in
    x86_64) asset=soloist_release_x86_64.tar.gz ;;
    *)
      echo "setup-soloist.sh: --download knows only the x86_64 build." >&2
      echo "Download the build for $(uname -m) from $downloads_page" >&2
      echo "and pass it with --archive." >&2
      exit 1
      ;;
  esac
  command -v curl >/dev/null 2>&1 || {
    echo "setup-soloist.sh: curl is required for --download" >&2
    exit 1
  }
  work_download=$(mktemp -d)
  echo "Downloading $asset from Spotify..."
  if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fSL --retry 2 \
      -o "$work_download/$asset" "$official_url_base/$asset"; then
    rm -rf -- "$work_download"
    echo "setup-soloist.sh: the download failed. Get the build from" >&2
    echo "$downloads_page and pass it with --archive." >&2
    exit 1
  fi
  install_archive "$work_download/$asset"
  rm -rf -- "$work_download"
elif [[ -n $archive ]]; then
  [[ -f $archive ]] || { echo "setup-soloist.sh: no such file: $archive" >&2; exit 1; }
  install_archive "$archive"
fi

if [[ -x $soloist_dir/soloist ]]; then
  binary="$soloist_dir/soloist"
elif binary=$(command -v soloist 2>/dev/null); then
  :
else
  echo "setup-soloist.sh: Spotify Soloist is not installed." >&2
  echo "Run this again with --download, or download it from" >&2
  echo "$downloads_page and pass the file with --archive." >&2
  exit 1
fi

set +e
version=$("$binary" --version 2>&1)
version_status=$?
set -e
if (( version_status == 10 )); then
  echo "setup-soloist.sh: this Soloist build has expired (builds last 90 days)." >&2
  echo "Run this again with --download to install the current build." >&2
  exit 10
fi
if (( version_status != 0 )); then
  echo "setup-soloist.sh: $binary could not run on this computer" >&2
  exit 1
fi
echo "Using Spotify Soloist: ${version%%$'\n'*}"

install -d -m 700 -- "$config_dir" "$unit_dir" "$runtime_dir"
if [[ ! -f $config_file ]]; then
  install -m 600 -- "$source_root/config/spotifyd.conf" "$config_file"
fi

if [[ ! -s $key_file ]] || (( replace_key )); then
  if [[ -t 0 ]]; then
    echo "Create a Soloist API key at $key_page"
    echo "(the Spotify account that creates it needs Premium), then paste it here."
    IFS= read -rsp "Soloist API key (hidden): " api_key
    echo
  else
    IFS= read -r api_key || true
  fi
  api_key=${api_key//[[:space:]]/}
  if [[ -z $api_key || ${#api_key} -gt 512 || $api_key =~ [^[:graph:]] ]]; then
    echo "setup-soloist.sh: that does not look like an API key; nothing was saved" >&2
    exit 3
  fi
  temporary=$(mktemp "${key_file}.tmp.XXXXXX")
  chmod 600 "$temporary"
  printf '%s\n' "$api_key" >"$temporary"
  mv -f -- "$temporary" "$key_file"
  unset api_key
  echo "Saved the API key with owner-only permissions."
else
  echo "Keeping the stored API key (use --replace-key to change it)."
fi

install -m 755 -- "$source_root/scripts/run-soloist.sh" "$launcher"
install -m 644 -- "$source_root/systemd/omarchy-spotify-soloist.service" "$unit_file"
systemctl --user daemon-reload
# The other playback runtimes cannot run next to Soloist under the same name.
systemctl --user stop omarchy-spotify.service omarchy-spotifyd.service \
  >/dev/null 2>&1 || true
systemctl --user reset-failed omarchy-spotify-soloist.service >/dev/null 2>&1 || true

echo "Installed playback unit: $unit_file"

if (( pair )); then
  echo
  echo "Waiting for pairing. In the Spotify app on your phone or another"
  echo "computer on this network, open the device list and choose this"
  echo "computer. Press Ctrl+C to skip."
  "$launcher" --pair || {
    echo "setup-soloist.sh: pairing did not finish. You can pair later by" >&2
    echo "selecting this computer from any Spotify app while it is running." >&2
  }
fi

cat <<'EOF'

Soloist is now the plugin's playback device. Restart the shell, or click
"Start this computer" in the plugin, and playback starts on demand.
The first time, select this computer once from a Spotify app's device list
(or run this script again with --pair) so Soloist can store its session.
EOF
