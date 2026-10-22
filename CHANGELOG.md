## 2.1.0

- `wsk restore-test [BACKUP|latest] [--json] [--max-age S]`: automated restore verification for cron. Re-runs the full media + database proof of `wsk verify`, extracts every files archive completely, reports drift between the backup and the live webroot, and fails when the newest backup is older than the RPO limit (default 26 h, `WSK_RESTORE_TEST_MAX_AGE`). Writes versioned JSON + text reports to `/etc/wsk/reports/` (14 kept) and a `last_restore_test` status file.
- `wsk dr-drill [--keep] [--json] [--max-rto S]`: a real disaster-recovery drill. Every site is recovered from the latest backup into an isolated root - scratch databases with row-count proof, files from the archives, the saved vhosts rewritten to drill ports - then a private nginx is booted and probed over HTTP/HTTPS like a visitor, including a byte comparison of the served page against the restored files. Measures RTO and backup age; the live site, database and nginx are never touched. `--max-rto S` turns the drill into an RTO gate.
- A nightly guarded `restore-test` cron job joins the schedule (`wsk timers`), so restore verification runs unattended and `wsk health` / `wsk timers --status` flag a failed run.
- restore-drill/LEARN.md study guide: RPO/RTO, why untested backups are hopes, how to read the drill report.
- 17 new integration checks (66 total): restore-test pass/corruption/staleness, drill recovery over HTTPS, cleanup and reporting. CI also runs both commands as root on a clean Ubuntu VM.

## 2.0.0

- Native architecture-independent DEB/RPM packages with actual install/version/remove matrix CI.
- Signed metadata package repository publication, ephemeral 30-day keys, tested APT/DNF repository installs. RPM headers unsigned; trust bootstrap and key rotation documented.
- Shared enterprise hub: versioned conservative CIS crosswalk (all checks accounted for, only verified references mapped), selected Ansible hardening role, idempotence checks, Prometheus exporter/rules, Grafana Compose dashboard, and safe incident reconstruction.
- Beginner LEARN.md guides. No invented experience, certification or production attack claims. Existing real-vs-fixture storage limits remain.

# Changelog

## [1.3.0] - 2026-10-22
### Added
- `wsk guard JOB SECONDS subcommand`: flock (no overlapping backups), hard timeout, log and status file. The generated cron lines all use it.
- `wsk timers --check [FILE]` (schedule fields, user, absolute executable path, unescaped `%`), `--remove`, `--status`. `--apply` validates the file before it goes live and keeps a `.bak`.
- `wsk health` now reports data/backup/web filesystem fullness (with an LVM `lvextend -r` hint when on LVM), software RAID degraded/inactive, and failed scheduled jobs.
### Not done (honest)
- No LVM-snapshot-consistent database backup in this repo; the toolkit's `sysops lvm backup` covers LVM. Real LVM/RAID drills live in the other two repos; here RAID/fs checks are fixture-tested.

## [1.2.0] - 2026-10-22
### Added
- Debian CI matrix: the full real-nginx + real-MariaDB integration suite on Debian 12
  (bookworm) and Debian 13 (trixie) with apt packages.
- Apache support: `wsk init-site --server apache` provisions a hardened Apache vhost
  (TLS 1.2/1.3, security headers, version hidden, dotfile/dot-directory and .sql/.bak
  blocking, ACME challenge path) gated on configtest; backup captures the Apache vhost;
  health checks whichever server each site uses. New `apache` CI matrix runs a dedicated
  scenario suite on Debian 12, Debian 13, Rocky 9 and Ubuntu 24.04. Rate limiting remains
  nginx-only (documented).
- Broken-config drill in both suites: a hand-broken vhost makes `wsk health` exit 2; it
  passes again after repair.

## [1.1.0] - 2026-10-22
### Added
- The docker-compose lab is now complete (vhost, site, cert generator, backup sidecar script)
  and exercised end-to-end on every push by the new `compose-lab` CI job: HTTP 301, HTTPS 200,
  security headers, hidden version, dotfile 403, plus a real backup restored into a scratch
  database with row-count verification.
- Rocky Linux 9 CI job running the full real-nginx + real-MariaDB integration suite
  (mariadbd path and root-in-container handling added to tests/env.sh).
- INTERVIEW.md: 60-second pitch, architecture, design choices, 10 interview Q&A.
- Demo GIF in the README (rendered from real CI output).
- Release badges, quick-start polish in the README.

## [1.0.0] - 2026-10-22
- Initial public release: one-command sites (nginx vhost gated by nginx -t, TLS 1.2/1.3,
  security headers, rate limiting), least-privilege DB users, backups proven by real restore,
  GFS retention with hard links, off-site rsync, cert watchdog, log rotation + scanner report,
  end-to-end health check. CI: unprivileged real-stack suite + real-root Ubuntu job.
