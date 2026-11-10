#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
action=${1:-}
if (( $# != 1 )); then
  echo "Usage: scripts/playback-runtime.sh check|credentials|start|start-explicit|stop|status|failure|unit" >&2
  exit 2
fi

runtime_dir=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}
backend_binary="$runtime_dir/omarchy-spotify-backend"
backend_source_id_file="$runtime_dir/backend-source.sha256"
backend_binary_hash_file="$runtime_dir/backend-binary.sha256"
backend_unit=omarchy-spotify.service
fallback_unit=omarchy-spotifyd.service
soloist_unit=omarchy-spotify-soloist.service
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
installed_backend_unit="$config_root/systemd/user/omarchy-spotify.service"
source_backend_unit="$source_root/systemd/omarchy-spotify.service"
state_root=${XDG_STATE_HOME:-"$HOME/.local/state"}
cache_root=${XDG_CACHE_HOME:-"$HOME/.cache"}
soloist_key_file="$config_root/omarchy-spotify/soloist-api-key"
soloist_launcher="$runtime_dir/run-soloist.sh"

unit_exists() {
  systemctl --user cat "$1" >/dev/null 2>&1
}

backend_install_is_current() {
  local current_source_id expected_source_id expected_binary_hash actual_binary_hash

  [[ -x $backend_binary && -s $backend_source_id_file \
    && -s $backend_binary_hash_file ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  current_source_id=$("$source_root/scripts/backend-source-id.sh") || return 1
  expected_source_id=$(<"$backend_source_id_file")
  [[ $expected_source_id == "$current_source_id" ]] || return 1
  expected_binary_hash=$(<"$backend_binary_hash_file")
  [[ $expected_binary_hash =~ ^[0-9a-f]{64}$ ]] || return 1
  actual_binary_hash=$(sha256sum -- "$backend_binary") || return 1
  [[ ${actual_binary_hash%% *} == "$expected_binary_hash" ]] || return 1
  [[ ! -f $source_backend_unit ]] \
    || { [[ -f $installed_backend_unit ]] \
      && cmp -s -- "$source_backend_unit" "$installed_backend_unit"; }
}

# Spotify Soloist is Spotify's official headless client. Setting it up is an
# explicit user choice (scripts/setup-soloist.sh), so it wins over the other
# runtimes whenever its executable, API key, launcher and unit are all present.
soloist_is_ready() {
  [[ -x $runtime_dir/soloist/soloist ]] || command -v soloist >/dev/null 2>&1 \
    || return 1
  [[ -s $soloist_key_file && -x $soloist_launcher ]] || return 1
  unit_exists "$soloist_unit"
}

preferred_unit() {
  if soloist_is_ready; then
    printf '%s\n' "$soloist_unit"
  elif backend_install_is_current && unit_exists "$backend_unit"; then
    printf '%s\n' "$backend_unit"
  elif command -v spotifyd >/dev/null 2>&1 && unit_exists "$fallback_unit"; then
    printf '%s\n' "$fallback_unit"
  else
    return 1
  fi
}

case $action in
  check)
    preferred_unit >/dev/null
    ;;
  credentials)
    # Soloist signs in with the stored API key and keeps its own session.
    if soloist_is_ready; then
      exit 0
    fi
    credential_paths=(
      "$state_root/omarchy-spotify/oauth/credentials.json"
      "$state_root/omarchy-spotify/zeroconf/credentials.json"
      "$cache_root/spotifyd/oauth/credentials.json"
      "$cache_root/spotifyd/zeroconf/credentials.json"
    )
    for path in "${credential_paths[@]}"; do
      [[ -s $path ]] && exit 0
    done
    exit 1
    ;;
  start|start-explicit)
    unit=$(preferred_unit) || {
      echo "playback-runtime.sh: no installed playback runtime is available" >&2
      exit 1
    }
    failure_path="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/omarchy-spotify/startup-error.json"
    if [[ $action == start-explicit ]]; then
      rm -f -- "$failure_path"
      systemctl --user reset-failed "$unit" || true
    else
      failure_code=$(jq -r '.code // ""' "$failure_path" 2>/dev/null || true)
      case $failure_code in
        invalid_configuration|missing_credentials|reconnect_exhausted) exit 75 ;;
      esac
      [[ $(systemctl --user show "$unit" -p Result --value) != start-limit-hit ]] || exit 75
    fi
    systemctl --user start "$unit"
    ;;
  stop)
    systemctl --user stop "$backend_unit" 2>/dev/null || true
    systemctl --user stop "$fallback_unit" 2>/dev/null || true
    systemctl --user stop "$soloist_unit" 2>/dev/null || true
    ;;
  status)
    unit=$(preferred_unit) || exit 1
    systemctl --user is-active "$unit"
    ;;
  failure)
    unit=$(preferred_unit) || exit 1
    if [[ $(systemctl --user show "$unit" -p Result --value) == start-limit-hit ]]; then
      echo restart_limit
    elif [[ $unit == "$soloist_unit" \
        && $(systemctl --user show "$unit" -p ExecMainStatus --value) == 10 ]]; then
      echo soloist_expired
    elif [[ $unit == "$soloist_unit" \
        && $(systemctl --user show "$unit" -p ExecMainStatus --value) == 78 ]]; then
      echo invalid_configuration
    else
      jq -r '.code // ""' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/omarchy-spotify/startup-error.json" 2>/dev/null || true
    fi
    ;;
  unit)
    preferred_unit
    ;;
  *)
    echo "playback-runtime.sh: unknown action: $action" >&2
    exit 2
    ;;
esac
