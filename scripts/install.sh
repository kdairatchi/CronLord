#!/bin/sh
# CronLord installer. Fetches a release binary, drops the systemd unit,
# creates the cronlord user + data dir, and starts the service.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/kdairatchi/CronLord/main/scripts/install.sh | sudo sh
#
# Environment:
#   CRONLORD_VERSION  override the release tag (default: latest)
#   CRONLORD_PREFIX   install prefix (default: /usr/local)
#   CRONLORD_NO_START skip systemctl start at the end

set -eu

REPO="kdairatchi/CronLord"
PREFIX="${CRONLORD_PREFIX:-/usr/local}"
VERSION="${CRONLORD_VERSION:-latest}"
DATA_DIR="/var/lib/cronlord"
ETC_DIR="/etc/cronlord"
SERVICE="/etc/systemd/system/cronlord.service"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "please run as root (try: sudo $0)"
  fi
}

detect_arch() {
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) echo "linux-amd64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *) die "unsupported architecture: $uname_m" ;;
  esac
}

resolve_url() {
  arch="$1"
  if [ "$VERSION" = "latest" ]; then
    tag_url="https://api.github.com/repos/${REPO}/releases/latest"
    tag="$(curl -fsSL "$tag_url" | awk -F'"' '/tag_name/ {print $4; exit}')" \
      || die "could not resolve latest release tag"
  else
    tag="$VERSION"
  fi
  echo "https://github.com/${REPO}/releases/download/${tag}/cronlord-${arch}.tar.gz"
}

ensure_user() {
  if ! id cronlord >/dev/null 2>&1; then
    log "creating cronlord system user"
    useradd --system --home-dir "$DATA_DIR" --create-home \
      --shell /usr/sbin/nologin cronlord
  fi
}

install_binary() {
  url="$1"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  log "downloading $url"
  curl -fsSL "$url" -o "$tmp/cronlord.tar.gz" \
    || die "download failed — check CRONLORD_VERSION or network"
  tar -xzf "$tmp/cronlord.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/cronlord" "$PREFIX/bin/cronlord"
  log "installed $PREFIX/bin/cronlord"
}

install_config() {
  mkdir -p "$ETC_DIR" "$DATA_DIR"
  chown -R cronlord:cronlord "$DATA_DIR"
  if [ ! -f "$ETC_DIR/cronlord.toml" ]; then
    cat >"$ETC_DIR/cronlord.toml" <<'TOML'
[server]
host = "127.0.0.1"
port = 7070

[storage]
data_dir = "/var/lib/cronlord"
TOML
    log "wrote $ETC_DIR/cronlord.toml"
  fi
}

install_service() {
  cat >"$SERVICE" <<UNIT
[Unit]
Description=CronLord — visual self-hosted cron scheduler
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cronlord
Group=cronlord
WorkingDirectory=$DATA_DIR
ExecStart=$PREFIX/bin/cronlord server --config $ETC_DIR/cronlord.toml
Restart=on-failure
RestartSec=5
Environment=CRONLORD_DATA=$DATA_DIR

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR
ReadOnlyPaths=$ETC_DIR

[Install]
WantedBy=multi-user.target
UNIT
  log "wrote $SERVICE"
  systemctl daemon-reload
}

main() {
  need_root
  command -v curl  >/dev/null || die "curl is required"
  command -v tar   >/dev/null || die "tar is required"
  command -v systemctl >/dev/null || die "this installer assumes systemd"

  arch="$(detect_arch)"
  url="$(resolve_url "$arch")"

  ensure_user
  install_binary "$url"
  install_config
  install_service

  if [ -z "${CRONLORD_NO_START:-}" ]; then
    systemctl enable --now cronlord
    log "cronlord is running on http://127.0.0.1:7070"
  else
    log "install complete — start with: systemctl enable --now cronlord"
  fi
}

main "$@"
