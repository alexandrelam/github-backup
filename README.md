# gh-backup

Back up all your GitHub repositories to an Ubuntu server, safely and resumably.

- **Active repos** (pushed to in the last 365 days): full backup with every branch, every tag and the full history.
- **Older repos**: shallow backup (`--depth 1`, every branch), which is much smaller.
- **Re-runs** only fetch what changed. If an old repo becomes active again, it is upgraded to full history automatically. A full backup is never made shallow again.
- **Crash-safe**: if the script is killed, the server reboots or the network drops, just run it again. It resumes the unfinished run, skips repos already done and deletes half-finished clones.

## Why bash

Almost all of the work is done by `git` itself, so the script is mostly glue: list repos from the API, decide on full or shallow, run `git`, record progress. Bash with `curl` and `jq` does that with no build step and no runtime to install, and you can read and change it on the server. Parallelism comes from `xargs -P`, and `flock` prevents overlapping runs. A Go binary would be worth it only for much more logic than this.

## Requirements

| Requirement | Version | Notes |
|---|---|---|
| Linux server | Ubuntu 20.04 or newer | Any distro with GNU coreutils/findutils works |
| `bash` | 4.4+ | Preinstalled on Ubuntu |
| `git` | 2.20+ | `sudo apt install git` |
| `curl` | 7.x+ | `sudo apt install curl` |
| `jq` | 1.6+ | `sudo apt install jq` |
| `flock`, GNU `xargs`/`find` | | From `util-linux` and `findutils`, preinstalled on Ubuntu |
| GitHub token | | Fine-grained with *Contents: read-only* on all repos, or classic with `repo` scope (see [Token](#token)) |
| Network | | Outbound HTTPS to `api.github.com` and `github.com` |
| Disk space | | Roughly the total size of your repos; shallow backups of old repos take much less |

Check everything at once:

```bash
bash --version | head -1; git --version; curl --version | head -1; jq --version; flock --version
```

The script also checks for `git`, `curl`, `jq` and `flock` when it starts, and stops with a clear message if one is missing.

## Setup

```bash
# 1. Dependencies
sudo apt install git curl jq util-linux   # util-linux provides flock

# 2. Install the script
sudo install -m 755 gh-backup.sh /usr/local/bin/gh-backup

# 3. Token (see below), readable only by you
mkdir -p ~/.config/gh-backup
echo 'ghp_xxxxxxxxxxxx' > ~/.config/gh-backup/token
chmod 600 ~/.config/gh-backup/token

# 4. Config
sudo tee /etc/gh-backup.conf >/dev/null <<'EOF'
BACKUP_DIR=/srv/github-backup
GITHUB_TOKEN_FILE=/home/YOUR_USER/.config/gh-backup/token
EOF

# 5. Check what it will do, then run it
gh-backup --dry-run
gh-backup
```

### Token

Either token type works:

- **Fine-grained token** (recommended): Settings → Developer settings → Fine-grained tokens. Set *Repository access* to *All repositories*. Under *Repository permissions*, set *Contents* to *Read-only* (*Metadata* read-only is added automatically).
- **Classic token**: the `repo` scope.

The token is passed to git through a temporary credential helper. It is never written to a git config or put in a URL.

## Configuration

Set these in `/etc/gh-backup.conf` (or another file pointed to by `CONFIG_FILE`) or as environment variables.

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_DIR` | `~/github-backup` | Where backups, state and logs go |
| `GITHUB_TOKEN` / `GITHUB_TOKEN_FILE` | | The token itself, or a file that contains it |
| `CUTOFF_DAYS` | `365` | A repo pushed to within this many days gets a full backup |
| `AFFILIATION` | `owner` | Which repos to include. Use `owner,collaborator,organization_member` to add org and shared repos |
| `INCLUDE_FORKS` | `true` | Set to `false` to skip forks |
| `EXCLUDE_REGEX` | | Skip repos whose `owner/name` matches, e.g. `^me/(junk\|tmp-.*)$` |
| `JOBS` | `8` | Repos processed in parallel |
| `MAX_ATTEMPTS` | `4` | Attempts per repo (backoff 15s, 30s, 60s) before it is marked failed |
| `LOG_KEEP_DAYS` | `30` | Old logs are deleted after this many days |

"Updated" means the repo's last **push** (`pushed_at`), not stars or description edits.

## Cron

Run every night at 03:00:

```cron
0 3 * * * /usr/local/bin/gh-backup >/dev/null 2>&1
```

Add it with `crontab -e` as the user that owns the token and backup folder. The output goes to the log files, so cron needs nothing. If a run is still going when the next one starts, the second one exits straight away.

A systemd timer works just as well. Exit code `0` means every repo was backed up, and `1` means at least one failed. Point your monitoring at the exit code or at `state/last-success`.

## Layout

```
/srv/github-backup/
├── repos/<owner>/<name>.git    bare repositories, one per GitHub repo
├── logs/backup-*.log           one log per run, plus latest.log
└── state/
    ├── run/                    progress of the current run (used to resume)
    ├── last-success            time of the last fully successful run
    └── last-failures.txt       repos that failed in the last run, if any
```

## How resuming works

1. A new run first lists every repo into `state/run/repos.tsv`. The list is written to a temp file and renamed, so it is either complete or absent.
2. Each repo that finishes is added to `state/run/done.txt`.
3. New clones go into `<name>.git.partial` and are renamed only once complete. A `.git` folder is therefore always a full, usable clone.
4. On start, if `state/run` has no `complete` marker, the script resumes. It removes leftover `.partial` folders and stale git lock files, then works only on repos that are not in `done.txt`.
5. When the run ends, failed repos are listed in `state/last-failures.txt` and are tried again next time.

Use `gh-backup --fresh` to drop an unfinished run and start over with a new repo list.

## Rate limits and retries

- **Listing repos** uses one API call per 100 repos. If GitHub reports the rate limit is exhausted, the script sleeps until the reset time. It also honours `Retry-After`, and retries 5xx and network errors with backoff.
- **Clones and fetches** don't count against the REST rate limit. They are retried per repo, and one bad repo never stops the others.

## Restoring

Backups are bare repositories. To get a working copy:

```bash
git clone /srv/github-backup/repos/me/project.git
```

To push a repo back to GitHub (or anywhere): `git -C project.git push --mirror <new-url>`.
