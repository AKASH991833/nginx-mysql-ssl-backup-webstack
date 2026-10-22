# INTERVIEW.md - how to explain this project (wsk)

The 60-second pitch, the architecture, the design choices a hiring manager will ask about,
and questions with strong answers. Everything here matches the code and the test suite.

## The 60-second pitch

"wsk builds a complete production-style web stack with one command per site: hardened nginx
with TLS and security headers, a MariaDB database with a least-privilege user per site, and -
the part I care most about - backups that are *proven* restorable: every backup can be restored
into a scratch database and its row counts compared automatically. Add GFS retention with hard
links, an off-site rsync copy, a certificate-expiry watchdog, log rotation plus attack-probe
analysis, and an end-to-end health check with monitoring-style exit codes. CI proves it on a
clean Ubuntu VM as root, on Rocky Linux 9, and the docker-compose lab is built, attacked and
restored on every push."

## Architecture

```
wsk (one entry point)
 |- install        apt/dnf package install (nginx, mariadb, certbot, rsync, logrotate)
 |- init-site      webroot + cert + nginx vhost + DB + least-priv user + 600 creds file
 |                  the generated vhost is kept only if nginx -t passes
 |- backup         mariadb-dump --single-transaction + files + vhost + SHA256 + manifest
 |- verify         restore the dump into a scratch DB, diff row counts per table
 |- restore-test   scheduled verification: media+DB proof, full extraction, drift, RPO age
 |- dr-drill       rebuild every site from a backup in an isolated root, serve it, measure RTO
 |- restore        reverse of backup, requires --yes
 |- certs          expiry watchdog (exit 1 = renew soon, 2 = critical), renew
 |- logs/logrotate top IPs, status codes, scanner probes; rotation policy
 |- health         nginx -t, DB, 301, 200, headers, TLS days, backup age, last verify
tests/             starts a REAL nginx + REAL MariaDB as an ordinary user (66 checks)
examples/          docker-compose lab (built, probed, backed up and restored in CI)
```

## Design choices (and why)

1. **Verify means restore.** Most backup scripts only *write*. `wsk verify` restores the dump
   into a scratch database and compares per-table row counts recorded at backup time. A corrupt
   gzip or a truncated dump fails loudly. The suite proves corruption is detected.
2. **`--single-transaction` dumps.** A consistent InnoDB snapshot without table locks, so the
   site keeps serving during the backup. Routines, triggers and events are included.
3. **Least-privilege DB user per site.** `shop_example_com_app` can touch only its own database -
   no `GRANT ALL ON *.*`. One hacked site cannot read another site's data. The test asserts the
   app user cannot even *see* the system databases.
4. **GFS retention with hard links.** 7 daily / 4 weekly / 6 monthly. Weekly and monthly are
   `cp -al` promotions: full history at near-zero extra disk. The test checks the link count.
5. **nginx -t as a gate.** A broken generated vhost never reaches the running server: init-site
   tests and removes it if invalid.
6. **HSTS only with real certificates.** With a self-signed lab cert, HSTS would lock browsers
   out of the lab. The header set adapts to the certificate type.
7. **Every path relocatable via `WSK_*` env.** That is what lets the test-suite run a real nginx
   and a real MariaDB as a normal user on ports 18080/18443 - no root, no Docker, no systemd -
   and exactly how CI runs the same suite on Ubuntu and Rocky 9.
8. **Exit codes as a contract.** health: 0 ok / 1 warn / 2 crit; certs: 0 ok / 1 renew-soon /
   2 critical. Cron, Nagios, Zabbix or Uptime Kuma can consume them directly.

## Interview Q&A

**1. Why is "backup verified by restore" such a big deal?**
Because write-only backup scripts fail silently: full disks, corrupted dumps, wrong permissions -
you find out during the disaster. verify restores the dump into a scratch DB and compares row
counts per table, so a broken backup pages you the same night, not on restore day.

**2. How do you take a consistent MySQL backup without downtime?**
`mariadb-dump --single-transaction`: a repeatable-read InnoDB snapshot, no table locks, the site
keeps writing. Routines, triggers and events are dumped too. (For MyISAM tables you'd need
locks - the stack assumes InnoDB, the MariaDB default.)

**3. Explain your retention design.**
Grandfather-father-son: 7 daily, 4 weekly (Sundays), 6 monthly (1st). Promotions are hard links
(`cp -al`), so keeping 17 "copies" costs barely more than one. Deletion happens only after the
next promotion exists. The test forces promotions and asserts the inode link count is >= 2.

**4. How does init-site make a database safely?**
It creates the database, then a user named after the site with privileges on *that one
database only* (no `*.*`, no DROP), with a random 24-char password stored in a `0600` option
file - never printed, never in git. The test proves the app user can't see other databases.

**5. Walk me through the TLS setup and its security choices.**
Two server blocks: port 80 only 301-redirects (keeping the ACME challenge path open for Let's
Encrypt), 443 serves the site. TLS 1.2/1.3 only - the test negotiates TLS 1.1 and expects
failure. `server_tokens off` hides the version. Security headers include CSP, nosniff,
X-Frame-Options, Referrer/Permissions-Policy; HSTS only with a real cert, not a self-signed one.

**6. How does the health check work?**
It chains the answers that matter: `nginx -t` valid, DB answers, HTTP redirects 301, HTTPS
returns 200, headers present, version hidden, certificate days left, backup volume free space,
newest backup < 26h old, last restore-test status. Exit 0/1/2 maps to ok/warning/critical so it
drops straight into cron or a monitoring system.

**7. What does your log analysis catch?**
Top IPs by request count, status-code histogram, top 404 paths, and a scanner report: which IPs
probe for `wp-login.php`, `.env`, `phpmyadmin`, `.git`. That is the list you feed fail2ban or a
WAF rule set.

**8. How is it tested?**
`tests/run.sh` starts a real nginx and a real MariaDB as a normal user and checks 34 behaviours:
vhost generation, 301, 200, headers, hidden version, `.env` 403, TLS 1.1 refused, DB isolation,
backup contents and privacy mode, real restore with matching row counts, corruption detection,
restore after DROP TABLE + deleted files, GFS retention and hard links, rsync off-site identity,
cert expiry exit codes and renewal, log analysis, logrotate accepted by `logrotate -d`, health
failing when nginx is down. The `real-server` CI job repeats the flow as root on a clean Ubuntu
VM, the `rocky` job runs the same suite on Rocky 9, and `compose-lab` builds the container lab,
probes it, and restores a dump on every push.

**9. What are the honest limits?**
Real Let's Encrypt issuance shells out to certbot and is not exercised (needs a public domain).
The host tool is Ubuntu-verified as root; the Rocky path shares the code and passes the full
unprivileged suite. It is a single-server design - multi-node needs orchestration on top.

**10. What would you build next?**
Point-in-time recovery with binlog shipping, encrypted backups (age/gpg) before the rsync copy,
a restore rehearsal timer (weekly automatic verify already exists via `wsk timers`), Prometheus
metrics endpoint, and a WordPress/Laravel preset for init-site.

**11. How is restore-test different from verify?**
verify proves one backup *can* be restored, when you run it by hand. restore-test is the same
proof packaged for automation: it re-runs verify, extracts every files archive completely,
reports drift between the backup and the live webroot, and enforces an RPO - it fails when the
newest backup is older than the limit (default 26 h). It writes versioned JSON + text reports
and a status file, runs nightly from the guarded cron schedule, and a failed run shows up in
`wsk health` and `wsk timers --status`.

**12. Walk me through your disaster-recovery drill.**
`wsk dr-drill` pretends the server is gone without touching it: it recovers every site from
the latest backup into an isolated root - scratch databases with row-count proof, files from
the archives, the saved vhosts rewritten to drill ports - then boots a private nginx and probes
it like a visitor: 301 redirect, HTTPS 200, and the served page is byte-compared with the
restored files. It prints the measured RTO and the backup age, and `--max-rto` makes an overrun
fail the drill. Certificates are the documented gap: they are not in the backup (they can be
reissued), so the drill reuses the live ones and says so. Apache sites get DB + file recovery
but no DR web serving yet - also reported, not hidden.

## Scheduled jobs (v1.3.0)
**Why wrap cron jobs?** Cron does not care that the last run is still going. `flock -n` skips the overlap, the kernel releases it if the job dies, and a timeout kills a hung dump. The status file lets `wsk health` fail loudly when a job last failed.

**Why validate before installing?** A broken file in `/etc/cron.d` is ignored silently. Validation catches bad fields, missing binaries and unescaped `%` first.

**Limits:** no LVM snapshot DB backup here, and RAID checks are fixture-tested in this repo.

## Honest test status
See the README "Honest test report" - it is kept in sync with CI and names exactly what ran where.


## Enterprise v2: questions you should be able to answer

- Why is a PASS not CIS certification? Mapping coverage is partial, and version, effective configuration, Match contexts and manual controls matter.
- What is idempotence? A second Ansible converge returns changed=0, verified by CI, not merely exit 0.
- Why sign package metadata? It protects the index and package hashes. Our learning key rotates, so trust must be re-bootstrapped; individual RPM headers remain unsigned.
- What does a Grafana panel prove? Only the samples from its data source. Missing host data and a container-visible filesystem are limits, not healthy verdicts.
- Is rollback the same as incident recovery? No. Our SUID demo proves rollback can restore the unsafe state. Eradication is a separate step.
- Did this run in a real company? No. Describe it honestly as a tested portfolio lab.
