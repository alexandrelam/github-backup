#!/usr/bin/env bash
#
# gh-backup.sh - back up all your GitHub repositories to local disk.
#
#   * Repos pushed to within the last CUTOFF_DAYS (default 365): full clone
#     (all branches, all tags, full history). Re-runs fetch only what changed.
#   * Older repos: shallow clone (--depth 1, all branches). If an old repo
#     becomes active again, it is automatically "unshallowed" to full history.
#     A repo that already has full history is never made shallow again.
#   * Resumable: progress is recorded per repo. If the script is killed or the
#     machine reboots, the next start resumes the unfinished run, skips repos
#     already done, and deletes half-finished clones.
#
# Usage:
#   gh-backup.sh              run (or resume) a backup
#   gh-backup.sh --dry-run    list repos and what would happen, change nothing
#   gh-backup.sh --fresh      throw away an unfinished run and start a new one
#   gh-backup.sh --help
#
# Configuration: environment variables, or a config file (see README.md).

set -Eeuo pipefail
umask 077

# ---------------------------------------------------------------- config ----
CONFIG_FILE="${CONFIG_FILE:-/etc/gh-backup.conf}"
# shellcheck disable=SC1090
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

: "${BACKUP_DIR:=$HOME/github-backup}"   # where everything is stored
: "${GITHUB_TOKEN:=}"                    # token, or put it in GITHUB_TOKEN_FILE
: "${GITHUB_TOKEN_FILE:=}"
: "${GITHUB_API:=https://api.github.com}"
: "${AFFILIATION:=owner}"                # owner | owner,collaborator,organization_member
: "${INCLUDE_FORKS:=true}"
: "${EXCLUDE_REGEX:=}"                   # e.g. '^myuser/(junk|tmp-.*)$'
: "${CUTOFF_DAYS:=365}"                  # newer than this -> full clone
: "${JOBS:=8}"                           # repos processed in parallel
: "${MAX_ATTEMPTS:=4}"                   # attempts per repo before giving up
: "${API_MAX_ATTEMPTS:=8}"               # attempts per API page
: "${LOG_KEEP_DAYS:=30}"

REPOS_DIR="$BACKUP_DIR/repos"
STATE_DIR="$BACKUP_DIR/state"
RUN_DIR="$STATE_DIR/run"                 # state of the current / last run
LOG_DIR="$BACKUP_DIR/logs"
LOCK_FILE="$STATE_DIR/lock"

# Workers re-run this script, so they re-read the config themselves.
export GIT_TERMINAL_PROMPT=0

# ----------------------------------------------------------------- utils ----
log() {   # log LEVEL message...
  local level=$1; shift
  local line
  printf -v line '%(%Y-%m-%d %H:%M:%S)T [%s] %s' -1 "$level" "$*"
  printf '%s\n' "$line" >&2
  [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$line" >> "$LOG_FILE"
  return 0
}
die() { log ERROR "$@"; exit 1; }

# git with the token supplied through a one-off credential helper, so the
# token never lands in a URL, a .git/config, or the process list.
git_auth() {
  git -c credential.helper= \
      -c 'credential.helper=!f() { echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f' \
      -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=600 \
      -c core.askPass=true \
      "$@"
}

# ---------------------------------------------------------- GitHub API -----
# api_get URL OUT_BODY OUT_HEADERS -- retries, waits out rate limits.
api_get() {
  local url=$1 body=$2 headers=$3 attempt=0 status wait reset remaining now
  while (( ++attempt <= API_MAX_ATTEMPTS )); do
    status=$(curl -sS -o "$body" -D "$headers" -w '%{http_code}' \
               --connect-timeout 20 --max-time 120 \
               -H "Authorization: Bearer $GITHUB_TOKEN" \
               -H "Accept: application/vnd.github+json" \
               -H "X-GitHub-Api-Version: 2022-11-28" \
               "$url" 2>>"${LOG_FILE:-/dev/null}") || status=000

    case "$status" in
      200) return 0 ;;
      401) die "GitHub API says 401 Unauthorized: check your token." ;;
      403|429)
        remaining=$(hdr "$headers" x-ratelimit-remaining)
        reset=$(hdr "$headers" x-ratelimit-reset)
        wait=$(hdr "$headers" retry-after)
        now=$(date +%s)
        if [[ "$remaining" == "0" && -n "$reset" ]]; then
          wait=$(( reset - now + 5 ))
          log WARN "API rate limit reached, sleeping ${wait}s until reset."
        elif [[ -n "$wait" ]]; then
          log WARN "API asked us to slow down, sleeping ${wait}s."
        elif [[ "$status" == 403 ]]; then
          die "GitHub API 403 Forbidden for $url: $(head -c 300 "$body")"
        else
          wait=60
        fi
        (( wait > 0 )) && sleep "$wait"
        (( attempt-- ))          # rate-limit waits don't count as failures
        ;;
      *)
        wait=$(( 2 ** attempt ))
        log WARN "API request failed (HTTP $status), retry $attempt/$API_MAX_ATTEMPTS in ${wait}s."
        sleep "$wait"
        ;;
    esac
  done
  die "Giving up on $url after $API_MAX_ATTEMPTS attempts."
}

hdr() {   # hdr FILE name -> header value (case-insensitive), empty if absent
  grep -i "^$2:" "$1" | tail -n1 | cut -d: -f2- | tr -d ' \r' || true
}

# Writes TSV lines:  full_name  clone_url  mode(full|shallow)  default_branch  pushed_at
list_repos() {
  local out=$1 tmp body headers url page=0
  tmp=$(mktemp -d)
  body="$tmp/body" headers="$tmp/headers"
  url="$GITHUB_API/user/repos?per_page=100&affiliation=$AFFILIATION&sort=full_name"
  : > "$out"
  while [[ -n "$url" ]]; do
    (( ++page ))
    api_get "$url" "$body" "$headers"
    jq -r --argjson days "$CUTOFF_DAYS" --arg forks "$INCLUDE_FORKS" --arg exclude "$EXCLUDE_REGEX" '
        (now - $days * 86400) as $cutoff
        | .[]
        | select($forks == "true" or (.fork | not))
        | select($exclude == "" or (.full_name | test($exclude) | not))
        | [ .full_name,
            .clone_url,
            (if (.pushed_at != null and (.pushed_at | fromdateiso8601) >= $cutoff)
               then "full" else "shallow" end),
            (.default_branch // ""),
            (.pushed_at // "never") ]
        | @tsv' "$body" >> "$out"
    # follow the Link: <...>; rel="next" header
    url=$(hdr "$headers" link | tr ',' '\n' | sed -nE 's/.*<([^>]+)>;rel="next".*/\1/p')
  done
  rm -rf "$tmp"
  log INFO "Listed $(wc -l < "$out") repos over $page API page(s)."
}

# ---------------------------------------------------------------- worker ----
# Backs up one repo. Called in parallel through xargs as: $0 __worker "<tsv line>"
backup_one() {
  local full_name clone_url mode default_branch pushed_at
  IFS=$'\t' read -r full_name clone_url mode default_branch pushed_at <<< "$1"

  local dest="$REPOS_DIR/$full_name.git"
  local partial="$dest.partial"
  local out; out=$(mktemp)
  local attempt=0 ok=0 action args

  while (( ++attempt <= MAX_ATTEMPTS )); do
    if [[ -d "$dest" ]]; then
      if [[ -f "$dest/shallow" && "$mode" == full ]]; then
        action="unshallow" args=(--unshallow)
        git -C "$dest" config --replace-all remote.origin.fetch '+refs/tags/*:refs/tags/*' 'refs/tags/'
      elif [[ -f "$dest/shallow" ]]; then
        action="update (shallow)" args=(--depth 1)
      else
        action="update (full)" args=()
      fi
      git_auth -C "$dest" fetch --prune "${args[@]}" origin > "$out" 2>&1 && ok=1
    else
      # New backup: clone into *.partial, then rename. A directory without
      # the .partial suffix is therefore always a complete clone.
      # Refspecs are set after cloning: a bare clone has none, and passing
      # them to clone duplicates its built-in ones. Full backups then track
      # all branches and tags, shallow ones branches only.
      action="clone ($mode)" args=()
      [[ "$mode" == shallow ]] && args=(--depth 1 --no-single-branch)
      rm -rf "$partial"
      mkdir -p "$(dirname "$dest")"
      git_auth clone --bare --quiet "${args[@]}" "$clone_url" "$partial" > "$out" 2>&1 \
        && git -C "$partial" config remote.origin.fetch '+refs/heads/*:refs/heads/*' \
        && { [[ "$mode" == shallow ]] || git -C "$partial" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'; } \
        && mv "$partial" "$dest" && ok=1
    fi

    (( ok )) && break
    log WARN "$full_name: $action failed (attempt $attempt/$MAX_ATTEMPTS): $(tail -n 3 "$out" | tr '\n' ' ')"
    (( attempt < MAX_ATTEMPTS )) && sleep $(( 15 * 2 ** (attempt - 1) ))
  done

  if (( ok )); then
    # keep HEAD pointing at the current default branch
    if [[ -n "$default_branch" && "$(<"$dest/HEAD")" != "ref: refs/heads/$default_branch" ]] \
       && git -C "$dest" show-ref --verify --quiet "refs/heads/$default_branch"; then
      git -C "$dest" symbolic-ref HEAD "refs/heads/$default_branch"
    fi
    printf '%s\n' "$full_name" >> "$RUN_DIR/done.txt"
    log INFO "$full_name: $action OK (last push $pushed_at)"
  else
    printf '%s\n' "$full_name" >> "$RUN_DIR/failed.txt"
    { echo "---- $full_name ----"; cat "$out"; } >> "$LOG_FILE"
    log ERROR "$full_name: giving up after $MAX_ATTEMPTS attempts, will retry on next run."
  fi
  rm -f "$out"
  return 0   # never stop the other workers
}

# ------------------------------------------------------------------ main ----
usage() { sed -n '2,/^set -E/{/^#/s/^# \{0,1\}//p}' "$0"; }

main() {
  local dry_run=0 fresh=0
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      --fresh)   fresh=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $arg" >&2; usage; exit 2 ;;
    esac
  done

  for cmd in git curl jq flock; do
    command -v "$cmd" >/dev/null || die "Missing dependency: $cmd (apt install $cmd)"
  done

  if [[ -z "$GITHUB_TOKEN" && -n "$GITHUB_TOKEN_FILE" ]]; then
    [[ -r "$GITHUB_TOKEN_FILE" ]] || die "Cannot read GITHUB_TOKEN_FILE=$GITHUB_TOKEN_FILE"
    GITHUB_TOKEN=$(tr -d ' \r\n' < "$GITHUB_TOKEN_FILE")
  fi
  [[ -n "$GITHUB_TOKEN" ]] || die "Set GITHUB_TOKEN or GITHUB_TOKEN_FILE (see README)."
  export GITHUB_TOKEN

  mkdir -p "$REPOS_DIR" "$STATE_DIR" "$LOG_DIR"

  # Only one instance at a time (cron overlap, manual run during cron, ...).
  exec 9> "$LOCK_FILE"
  flock -n 9 || { echo "Another gh-backup is already running." >&2; exit 0; }

  LOG_FILE="$LOG_DIR/backup-$(date +%Y%m%d-%H%M%S).log"
  export LOG_FILE
  ln -sfn "$(basename "$LOG_FILE")" "$LOG_DIR/latest.log"
  find "$LOG_DIR" -name 'backup-*.log' -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true

  if (( dry_run )); then
    local plan; plan=$(mktemp)
    list_repos "$plan"
    awk -F'\t' '{ printf "%-8s %-50s last push %s\n", $3, $1, $5; n[$3]++ }
                 END { printf "\n%d full, %d shallow\n", n["full"], n["shallow"] }' "$plan"
    rm -f "$plan"
    exit 0
  fi

  # Resume an unfinished run, or start a new one.
  if (( !fresh )) && [[ -f "$RUN_DIR/repos.tsv" && ! -f "$RUN_DIR/complete" ]]; then
    log INFO "Resuming unfinished run started $(cat "$RUN_DIR/started")."
    rm -f "$RUN_DIR/failed.txt"   # failed repos get another chance
  else
    rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
    date '+%Y-%m-%d %H:%M:%S' > "$RUN_DIR/started"
    log INFO "Starting new run: listing repositories..."
    list_repos "$RUN_DIR/repos.tsv.tmp"
    mv "$RUN_DIR/repos.tsv.tmp" "$RUN_DIR/repos.tsv"   # atomic: list is complete or absent
  fi
  touch "$RUN_DIR/done.txt"

  # Crash recovery: remove clones interrupted mid-way and git lock files left
  # by killed fetches. Safe because the flock above means nothing else runs.
  find "$REPOS_DIR" -mindepth 2 -maxdepth 2 -type d -name '*.git.partial' -exec rm -rf {} +
  find "$REPOS_DIR" -type f -name '*.lock' -delete

  # Work left = all repos minus the ones already done in this run.
  local todo="$RUN_DIR/todo.tsv" total left
  awk -F'\t' 'FILENAME == ARGV[1] { done[$1]=1; next } !($1 in done)' "$RUN_DIR/done.txt" "$RUN_DIR/repos.tsv" > "$todo"
  total=$(wc -l < "$RUN_DIR/repos.tsv")
  left=$(wc -l < "$todo")
  log INFO "$total repos in this run, $(( total - left )) already done, $left to go (jobs=$JOBS, cutoff=${CUTOFF_DAYS}d)."

  xargs -r -d '\n' -n 1 -P "$JOBS" bash "$0" __worker < "$todo"

  date '+%Y-%m-%d %H:%M:%S' > "$RUN_DIR/complete"
  local failed=0
  if [[ -s "$RUN_DIR/failed.txt" ]]; then
    sort -u "$RUN_DIR/failed.txt" > "$STATE_DIR/last-failures.txt"
    failed=$(wc -l < "$STATE_DIR/last-failures.txt")
    log ERROR "Run finished with $failed failed repo(s): see $STATE_DIR/last-failures.txt and $LOG_FILE"
    exit 1
  fi
  rm -f "$STATE_DIR/last-failures.txt"
  date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/last-success"
  log INFO "Run finished: all $total repos backed up."
}

if [[ "${1:-}" == "__worker" ]]; then
  backup_one "$2"
else
  main "$@"
fi
