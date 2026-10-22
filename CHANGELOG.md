# Changelog

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
