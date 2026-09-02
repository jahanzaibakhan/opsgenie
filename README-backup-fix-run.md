# Cloudways Backup Diagnose and Run Script

`backup-fix-run.sh` diagnoses Cloudways duplicity backup issues, prioritizes failed backups, validates storage capacity, and starts selected backups in a GNU `screen` session.

## Run

Connect to the target server through SSH, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/backup-fix-run.sh | bash
```

The script is interactive and requires a controlling terminal plus `sudo` access. It needs GNU `screen` to run backups in the background.

## What it does

1. Creates a dated run log in `/var/cw/systeam/backup-log/`, for example:

   ```text
   backup-log-02-Sep-2026-10-55AM.log
   ```

2. Detects active `duplicity` or `duplicity_backup.sh` processes, displays their PIDs, sends them `TERM`, waits five seconds, and uses `KILL` only if they remain active.
3. Closes an existing `screen` session named `back` before starting a new one.
4. Clears duplicity cache files, checks resources, and reads:

   ```text
   /etc/ansible/facts.d/backup.fact
   ```

5. Uses `frequency` and `last_backup_<app>` values to identify overdue backups. Timestamps are expected in this Cloudways format:

   ```text
   DD/MM/YYYY HH:MM UTC
   ```

6. Processes apps with non-zero `error_code_<app>` values first. An errored app is marked `REMOVED` and skipped only when both paths are absent:

   ```text
   /home/master/applications/<app>
   /var/lib/mysql/<app>
   ```

7. Processes overdue apps after failed apps, avoiding expensive app-size scans across every app before urgent failures are handled.
8. Requires 120% of the database size as available capacity before an app backup starts. It checks the actual mounts for the database, application, temporary directory, and duplicity cache, supporting servers with separate Block Storage volumes.
9. Rechecks free capacity immediately before each backup starts.
10. Starts backups in `screen` session `back`.

## View a running backup

```bash
screen -r back
```

Detach without stopping the backup:

```text
Ctrl+A, then D
```

List sessions:

```bash
screen -ls
```

## Log contents

The dated log includes:

- Script start time and log path
- `/etc/ansible/facts.d/backup.fact` contents
- `df -h` output and mount-capacity checks
- Failed, removed, and overdue app status, file size, DB size, and backup eligibility
- Final diagnostic summary
- Complete backup actions/output from the `screen` session
- Final app status and latest backup time

## Operational impact

The script does not make backups faster; the backup duration still depends on application size, database size, disk I/O, and network speed.

It reduces operator time by automating the repetitive incident workflow: reading backup facts, checking the latest backup schedule, measuring failed app/DB data, validating the correct filesystem capacity, clearing cache files, managing `screen`, and collecting a team-shareable log.

| Activity | Manual process | With this script |
| --- | --- | --- |
| First diagnostic pass | Typically 10–30 minutes of SSH checks and note-taking | Usually 1–3 minutes of review before confirmation |
| Priority of failed apps | Manual identification and ordering | Failed apps run before overdue apps automatically |
| Disk/Block Storage validation | Check mounts and compare database size manually | Automatic 120% DB-size check on relevant mounts |
| Backup monitoring | Create/find screen sessions and collect output manually | Standard `screen -r back` session and dated log |

The time figures are operational estimates, not guarantees. The largest practical saving is on servers with many applications: initial file-size checks run only for failed apps, while overdue apps are checked after those urgent backups have been handled.

## Important safety behavior

- Starting the script intentionally stops an existing duplicity backup process and the `back` screen session. Do not run it if an in-progress backup must be preserved.
- Apps with missing or invalid backup timestamps are reported for review rather than silently treated as current.
- An app is skipped when the required filesystem capacity is insufficient; free space on a different disk does not satisfy the requirement.
