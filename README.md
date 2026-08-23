# baseline-drift-reporter

![ci](https://github.com/revisualize/baseline-drift-reporter/actions/workflows/ci.yml/badge.svg)

A nightly snapshot-and-diff of the things that quietly change under a running system: installed packages, enabled services, listening sockets, mounts, and the hashes of configuration files you name. Drift is reported. Intentional change is blessed into a new baseline with one command.

It observes. It never reverts.

## Usage

```sh
# One time, when the system is in a state you trust:
baseline_drift_reporter.sh --accept-baseline

# Nightly, from cron:
baseline_drift_reporter.sh

# What is the current baseline, and when was it taken?
baseline_drift_reporter.sh --show-baseline
```

## What it captures

Five sections, each a sorted plain-text file so `diff` output stays human-readable:

| Section | Source |
|---------|--------|
| `packages` | `dpkg-query` on the Debian family, `rpm` on the RHEL and SUSE families |
| `services` | Enabled and running systemd units |
| `listening_sockets` | TCP and UDP listeners with owning process, from `ss` |
| `mounts` | Filesystems, sources, and options, from `findmnt` |
| `config_hashes` | SHA-256 of an explicit watchlist of files |

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | No drift, or baseline accepted |
| 1 | Drift detected and reported |
| 2 | Configuration, dependency, or capture error |

## Configuration

Every setting is an environment variable, so the same script works unmodified across hosts.

| Variable | Default |
|----------|---------|
| `DRIFT_STATE_ROOT` | `/var/lib/baseline_drift_reporter` |
| `DRIFT_LOG_FILE` | `/var/log/baseline_drift_reporter.log` |
| `DRIFT_RECIPIENTS` | `alerts@example.net` |
| `DRIFT_WATCHED_FILES` | Colon-separated list of files to hash |
| `DRIFT_MAIL_COMMAND` | `mail` |

## Design notes

**A section that cannot be captured is an error, never "no drift."** This is the whole point of the tool and the easiest thing to get wrong. Piping a package query through `sort` with stderr discarded yields an empty file on a host with no `dpkg-query`, which then matches an equally empty baseline and reports clean forever. Every capture is checked, and an empty result is refused rather than recorded.

**Capture is staged, then promoted.** A snapshot is built in a staging directory and moved into place only after every section succeeds, so a partial capture can never become a baseline.

**Accepting a baseline archives the outgoing one.** The accept step is the single place where unwanted drift can be laundered into the record. The previous baseline is copied to `baseline_archive/` first, and the move is logged, so re-blessing is reversible and journalled.

**Drift is reported, never reverted.** Auto-remediation from a script with an incomplete model of intent is how one incident becomes two. The human decides whether drift is a problem or undocumented progress.

**A failed alert path is not silence.** If the mail command is missing or fails, the drift report goes to stderr and the log rather than disappearing. Drift that could not be mailed has still occurred.

**The watchlist is explicit.** Hashing all of `/etc` produces reports full of files nobody cares about. An explicit list means every line of drift is a file someone decided matters. A watched file that is absent is recorded as `MISSING`, because "this file did not exist on the 7th" is the kind of fact that settles arguments later.

## Known limitations

- Accepting a baseline blesses whatever is currently true, including drift you did not intend. The archive makes that recoverable; it does not make it impossible.
- Files you forget to add to the watchlist drift silently. Reviewing the watchlist is part of adopting the tool.
- No structured history or querying. Sorted text and unified diff are the entire data model, deliberately. When that stops being enough, the correct move is real configuration management, not adding a database to a shell script.

## Requirements

Bash 4.2 or newer, GNU coreutils, `diff`, `sha256sum`, `findmnt`, `systemctl`, `ss`, and one of `dpkg-query` or `rpm`.

## Tests

```sh
bats test/
```

System tools are stubbed in the suite, so it runs identically in a container with no systemd, which is also where the silent-capture failure would otherwise go unnoticed.

## License

See [LICENSE](LICENSE). This code is published for viewing as a sample of the author's work. All rights reserved.
