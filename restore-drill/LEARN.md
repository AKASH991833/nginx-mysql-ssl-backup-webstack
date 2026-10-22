# Restore tests and disaster-recovery drills: study from zero

A backup you have never restored is a hope, not a backup. This guide explains the two
commands that turn hope into evidence: `wsk restore-test` (scheduled proof) and
`wsk dr-drill` (a full rehearsal). Both are safe to run on a live server.

## 1. The two numbers every admin is asked about: RPO and RTO

- **RPO - recovery point objective**: how much data may we lose? If backups run nightly at
  02:30 and the disk dies at 14:00, you lose up to ~11.5 hours of data. Your RPO is the
  maximum loss you accept. `restore-test --max-age` enforces it: if the newest backup is
  older than the limit (default 26 h), the test fails - because a restorable but ancient
  backup still misses the objective.
- **RTO - recovery time objective**: how long may the service stay down? `dr-drill` measures
  a real recovery and prints the seconds. `--max-rto 600` turns "we think we can recover in
  ten minutes" into a check that fails when reality says otherwise.

Write both numbers down before you need them. A drill report with measured values beats a
guess in an incident call.

## 2. What restore-test actually checks (and what it does not)

`wsk restore-test` is the automated form of "prove last night's backup restores":

1. **Media + database proof** - the same checks as `wsk verify`: SHA256 sums, gzip integrity,
   the SQL dump restored into a scratch database, and every table's row count compared with
   the counts recorded at backup time.
2. **Complete extraction** - every files archive is unpacked and the entry count is compared
   with the archive listing, so a truncated archive cannot pass.
3. **Drift report** - the restored webroot is compared with the live one. Differences are a
   warning, not a failure: the site may simply have changed since the backup. Sudden large
   drift on a site nobody deployed to is worth a look - it can be an early defacement signal.
4. **RPO freshness** - fails when the newest backup is older than `--max-age`.

Reports land in `/etc/wsk/reports/restore-test-<epoch>.txt` and `.json` (14 kept). The JSON
is for monitoring: one object with the backup path, age, durations, failures and result.
`last_restore_test` records OK/FAIL, and the nightly guarded cron job (`wsk timers`) means a
failed restore-test is flagged by `wsk health` and `wsk timers --status`.

It does **not** prove the application boots - that is what the drill is for.

## 3. What dr-drill actually does

`wsk dr-drill` rehearses "the server is gone" without touching the live site:

1. Takes the latest backup and rebuilds every site into an **isolated root**
   (`/var/lib/wsk/dr-drill/<timestamp>`): the SQL dump into a **scratch database**
   (`wsk_dr_*`, dropped afterwards), the files from the archives, the saved vhosts rewritten
   to the drill ports (19080/19443 by default).
2. Boots a **private nginx** from the recovered configuration and probes it like a visitor:
   HTTP -> 301, HTTPS -> 200, and the served page is **byte-compared** with the restored
   files. A restore that "worked" but serves wrong content fails here.
3. Prints the measured **RTO** (seconds from drill start to recovered and verified) and the
   backup age, writes the same JSON + text reports, then cleans everything up unless
   `--keep`.

What to watch in the report: any `FAIL` line, the RTO trend across drills, and the backup
age. Run it after every restore-relevant change and on a calendar (monthly or quarterly) -
a recovery process that is never rehearsed decays.

## 4. Known limits (honest)

- **TLS certificates are not in the backup.** The drill reuses the live certificate paths.
  On a truly lost server you reissue: `wsk init-site` with `--letsencrypt`, or restore your
  own `/etc/letsencrypt` backup. This is a design choice, documented, not hidden.
- **Apache sites** get database + file recovery in the drill but no recovered web serving
  check yet; the drill says so per site instead of silently passing.
- The drill rebuilds on the **same machine**. A real DR plan also restores onto *different*
  hardware (the off-site `rsync` copy exists for that); the commands are the same.

## 5. Practice

```bash
sudo ./wsk restore-test                 # prove the latest backup, enforce 26 h freshness
sudo ./wsk dr-drill                     # full rehearsal, prints measured RTO
sudo ./wsk dr-drill --keep              # keep the recovered root to look around
cat /etc/wsk/reports/dr-drill-*.json    # machine-readable result for monitoring
```

Change one thing and rerun: delete a row and watch drift appear; point `--max-age 60` at a
day-old backup and watch the RPO check fail. In an interview, call this a hands-on lab on a
disposable VM - not production incident experience.
