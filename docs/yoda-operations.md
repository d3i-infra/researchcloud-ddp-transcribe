# Yoda (nluu10p) — empirical operations notes

Everything below was established by live testing on 2026-07-06 against
`fsw.data.uu.nl` / zone `nluu10p` (Yoda, iRODS 4.3.x) with GoCommands v0.12.2,
from both a home connection and a SURF Research Cloud workspace. It is the
evidence base behind the `yoda` role's current shape and the open follow-ups.
Companion to `storage-backends.md` (the design rationale); this page is what
the server actually does.

## Authentication — verified behavior

- **`gocmd init` MUST get `-c <dir>` to run headlessly.** Without `-c`, init
  runs its interactive questionnaire and reads the password from stdin even
  when `IRODS_USER_PASSWORD` is set — under Ansible/cron that submits an
  **empty password** (a failed PAM attempt on the server). With `-c` there are
  no prompts and the env-var password is used. Verified both ways against a
  fake host; this was the root defect in the role's original auth task.
- **`IRODS_USER_PASSWORD` works** (with `-c`): validated end-to-end on the SRC
  workspace — first-attempt success, non-interactive.
- **`--ttl 720` is accepted** by this server (30-day PAM token), despite the
  iRODS default cap of 336 h. Verified 2026-07-06 20:46.
- **The token lands at `irods_authentication_file`** (default `~/.irods/.irodsA`)
  — `-c` does NOT relocate it. Any script that checks `<config-dir>/.irodsA`
  to detect auth success reports false failures. Judge auth by **exit code or
  a `gocmd ls` probe, never file existence.** (Upstream issue drafted in
  `d3i/PENDING_ISSUES.md`.) The role's template now pins
  `irods_authentication_file` explicitly.
- **A bad/absent token + no TTY makes `gocmd ls` submit an empty password** —
  a wasted server-side PAM failure. The role therefore stat-gates its probe:
  no token file → skip probe, go straight to init. (Existence gates the probe
  only; validity is still judged by exit code.)
- **WebDAV shares the credential** and is the fastest independent auth test —
  no gocmd, no config, no iRODS protocol:
  `curl -s -o /dev/null -w '%{http_code}\n' -u '<user>' 'https://fsw.data.uu.nl/'`
  (200 = DAP valid; the server answers WebDAV on the same host.)

## Data-access passwords (DAPs) — observed policy

Mechanism unconfirmed (question pending with FSW tech support), but observed
repeatedly:

- After a burst of failed login attempts, previously working DAPs appear to
  become **permanently invalid** — rejected on both iRODS and WebDAV — while a
  **freshly generated DAP works immediately**.
- Operational rules that follow:
  1. **Mint a fresh DAP immediately before provisioning.**
  2. **Never retry a failing DAP in a loop** — regenerate instead. The role's
     failure message says this.
  3. Automation retries are for *transient* failures (modest count, long
     delay): the role uses 3 attempts / 60 s.
- One unexplained anomaly on record: 2026-07-06 19:40, the server dropped the
  connection mid-PAM-flow (client saw EOF mid-handshake instead of a clean
  rejection). Full go-irodsclient trace archived; reported to FSW. A clean
  rejection (wrong/empty password) by contrast returns a fast
  "Authentication failed" after a ~2 s PAM delay — the two failure shapes are
  distinguishable with `gocmd -d`.

## Performance envelope — measured 2026-07-06

Treat these as the **normal baseline**, not an incident (confirmed by the
operator: minute-plus portal loads are typical for this instance).

| Operation | Measured |
|---|---|
| Portal page load (TTFB), iRODS-heavy pages | 60–90 s routinely (Notifications worst) |
| Collection create (iRODS protocol) | ~3 s each |
| Small-file transfer, `gocmd sync --thread_num 15` | **~1.5 files/s** (631 files ≈ 7 min) |
| Large single file (`gocmd put`, parallel streams) | bandwidth-bound; round trip verified from SRC |
| 30 transfer threads | **saturates the server** — portal became unusable for all users; no server-side throttle observed |

Consequences:

- **File-per-file transfer does not scale.** 130k files ≈ 24 h; the 1M-video
  campaign (~2M files, see ADR 0004 sharding) ≈ **2+ weeks of continuous
  transfer**. The transcript sink needs a different shape (see follow-ups:
  tar-mode / admin bulk-ingest).
- **`--bulk_upload` does NOT work on Yoda.** It stages tarballs in a
  `.gocmd_staging` collection for server-side extraction; the staging-path
  safety check rejects research group collections, and users have no personal
  home collection on `nluu10p` to point `--irods_temp` at. (Even if staged,
  server-side extraction likely needs rules Yoda's policy layer blocks.)
  `storage-backends.md`'s original scale plan relied on this; it is corrected.
- **Client restraint is the only load protection.** Keep `--thread_num` ≤ 15;
  ~10 is a good default. Watch for transfer errors and back off.
- **Sync restarts get expensive as the remote tree grows** — the diff walk
  re-lists remote collections at ~3 s/op. Decide thread counts early; run long
  syncs in `tmux`.

## Transfer recipes

- **`gocmd sync SRC DEST` is dual-mode:** if DEST exists it creates
  `DEST/basename(SRC)`; if DEST does *not* exist, DEST is created and receives
  SRC's *contents*. To land contents under a differently-named collection that
  may already exist, the deterministic pattern is a hardlink staging copy with
  the target name (instant, no disk):
  `cp -al transcripts isabelle-transcripts && gocmd sync isabelle-transcripts i:<parent>`.
- **Hidden files/dirs are synced too.** A `.work/` scratch tree inside the
  transcripts dir went to Yoda before being caught. Stage with a glob
  (`cp -al src/* staged/` skips dotfiles) until `yoda-sync.sh` excludes hidden
  entries itself (follow-up filed).
- **`cp` is iRODS→iRODS.** Local↔remote is `put`/`get` (with `i:` prefixes on
  the iRODS side, matching `yoda-sync.sh`). `sync` is checksummed and
  idempotent — safe to interrupt and re-run.
- **Tarball pattern** for many small files when the recipient can accept an
  archive: `tar czf`, single `gocmd put`, recipient extracts locally after
  portal download. Minutes instead of hours; loses per-file portal
  browsability.
- The SRC↔Yoda network path is fully verified: control port 1247 and the
  20000–20199 data range both pass SURF's egress (put/get round trip,
  2026-07-06).

## Server version context

FSW is on **Yoda 2.0.4** (confirmed 2026-07-06), whose own release notes list
known issues directly relevant to what we measured:

- **Deadlock in `msiDataObjRepl`/`msiDataObjCopy` from Python rules**
  (irods_rule_engine_plugin_python#54) — **a documented known issue on the
  deployed version.** Yoda's replication/revision policies fire these on
  every data-object write; a deadlocked call is an agent stuck forever
  holding its connection slot. This is the best available explanation for the
  drained-agent-pool symptoms above (60–90 s portal TTFB, collapse under 30
  parallel threads, ~3 s per-op latency, possibly the 19:40 mid-auth drop) —
  and it means every bulk small-file upload (each write firing policy rules)
  both suffers from and feeds the problem. Raised with FSW support.
- **Naming rules (2.0.4 + upcoming 2.1 bugs):** collections with a single
  quote in the name don't work (irods/irods#5727); renaming collections with
  multi-byte characters mangles subcollection paths (irods/irods#6239); on
  2.1, "copy to research" fails on spaces/single quotes (YDA-7000/7001) and
  `irm` fails on single quotes (irods/irods#9019). **Rule: ASCII-only, no
  spaces, no quotes, in anything we create on Yoda.** Costs nothing
  (transcript files are digit-named); avoids all four bugs.
- Also on 2.0.4: KeyValPair deallocation can yield bad AVUs
  (irods/irods#8265) — metadata-side, not in our transfer path, but relevant
  if metadata annotation is ever automated.
- Arriving with 2.1: inactive-group notification bug (YDA-7082); the
  Notifications page is already the slowest page on 2.0.4 — re-check after
  any upgrade.

## Diagnosis playbook (short)

1. Auth failing? First: `curl -u <user> https://fsw.data.uu.nl/` (one attempt).
   401 with a known-good DAP → credential/server side; 200 → problem is in the
   gocmd/config layer.
2. Add `-d` to the failing gocmd command: a short "Authentication failed" =
   clean PAM rejection (wrong password / dead DAP); a giant EOF/unmarshal stack
   = the server dropped the connection (report it).
3. Do NOT verify auth by looking for `.irodsA` (see above). `gocmd ls` exit
   code is the truth.
4. After any failure burst: stop, regenerate the DAP, single fresh attempt.
