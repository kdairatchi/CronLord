#!/bin/sh
# scripts/claude-bootstrap.sh
# CronLord environment probe — deterministic, POSIX sh, zero external deps.
# Output: key=value lines, one per line. First line is a timestamp comment.
# Every check is isolated; a failure yields a sentinel, never aborts the script.

set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# ISO8601 UTC timestamp (POSIX date -u)
TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 'unknown')"
printf '# cronlord bootstrap probe — %s\n' "$TS"

# --- shard_version -----------------------------------------------------------
# grep the `version:` key at the top-level of shard.yml (first occurrence,
# which is always the package version in Crystal shard.yml).
shard_version='-'
if [ -f shard.yml ]; then
  _v="$(grep '^version:' shard.yml | head -1 | sed 's/version:[[:space:]]*//' | sed "s/['\"]//g" 2>/dev/null)"
  [ -n "$_v" ] && shard_version="$_v"
fi
printf 'shard_version=%s\n' "$shard_version"

# --- crystal -----------------------------------------------------------------
crystal='-'
_cv="$(crystal --version 2>/dev/null | head -1 | awk '{print $2}')"
[ -n "$_cv" ] && crystal="$_cv"
printf 'crystal=%s\n' "$crystal"

# --- shards ------------------------------------------------------------------
shards='-'
_sv="$(shards --version 2>/dev/null | head -1 | awk '{print $2}')"
[ -n "$_sv" ] && shards="$_sv"
printf 'shards=%s\n' "$shards"

# --- git_sha -----------------------------------------------------------------
git_sha='-'
_sha="$(git rev-parse --short HEAD 2>/dev/null)"
[ -n "$_sha" ] && git_sha="$_sha"
printf 'git_sha=%s\n' "$git_sha"

# --- git_dirty ---------------------------------------------------------------
# Count non-ignored modified/untracked files. git status --porcelain already
# respects .gitignore — no special-casing needed.
git_dirty='-'
_dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d '[:space:]')"
[ -n "$_dirty" ] && git_dirty="$_dirty"
printf 'git_dirty=%s\n' "$git_dirty"

# --- bin ---------------------------------------------------------------------
# CronLord prints help (not --version) to stdout with exit 0. Detect binary
# presence and executability; capture the first word of the first line as version.
bin='missing'
bin_version='-'
if [ -x bin/cronlord ]; then
  bin='ok'
  _bv="$(timeout 2 bin/cronlord 2>/dev/null | head -1 | awk '{print $1}' 2>/dev/null || true)"
  [ -n "$_bv" ] && bin_version="$_bv" || bin_version='-'
fi
printf 'bin=%s\n' "$bin"
printf 'bin_version=%s\n' "$bin_version"

# --- db ----------------------------------------------------------------------
# Reports size if the db file exists, else "fresh".
db='fresh'
if [ -f var/cronlord.db ]; then
  _sz="$(du -h var/cronlord.db 2>/dev/null | cut -f1)"
  [ -n "$_sz" ] && db="$_sz" || db='present'
fi
printf 'db=%s\n' "$db"

# --- config ------------------------------------------------------------------
config='default'
[ -f cronlord.toml ] && config='present'
printf 'config=%s\n' "$config"

# --- server ------------------------------------------------------------------
# curl: 1 s max-time, fail-silently, no redirect following needed for /health.
server='down'
_h="$(timeout 2 curl -fsS --max-time 1 --no-progress-meter \
  http://127.0.0.1:7070/health 2>/dev/null)"
[ $? -eq 0 ] && server='up'
printf 'server=%s\n' "$server"

# --- os ----------------------------------------------------------------------
os='-'
_os="$(uname -sr 2>/dev/null)"
[ -n "$_os" ] && os="$_os"
printf 'os=%s\n' "$os"

# --- wsl ---------------------------------------------------------------------
wsl='0'
case "$(uname -r 2>/dev/null)" in
  *microsoft* | *Microsoft*) wsl='1' ;;
esac
printf 'wsl=%s\n' "$wsl"

# --- cores -------------------------------------------------------------------
cores='-'
_cores="$(nproc 2>/dev/null)"
[ -n "$_cores" ] && cores="$_cores"
printf 'cores=%s\n' "$cores"

# --- ram_total / ram_free ----------------------------------------------------
# `free` output varies between GNU (Linux) and BusyBox (Alpine). Both emit a
# "Mem:" row; columns 2 and 7 are total and available respectively on GNU free.
# BusyBox free -h has the same column order. We use awk to handle either.
ram_total='-'
ram_free='-'
_free="$(free -h 2>/dev/null | awk '/^Mem:/ {print $2, $7}')"
if [ -n "$_free" ]; then
  ram_total="$(printf '%s' "$_free" | awk '{print $1}')"
  ram_free="$(printf '%s' "$_free"  | awk '{print $2}')"
fi
printf 'ram_total=%s\n' "$ram_total"
printf 'ram_free=%s\n' "$ram_free"
