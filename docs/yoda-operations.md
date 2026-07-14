# Yoda (nluu10p) — empirical operations notes

Everything below was established by live testing on 2026-07-06 and 2026-07-13
against `fsw.data.uu.nl` / zone `nluu10p` (Yoda, iRODS 4.3.x) with GoCommands
v0.12.2, from both a home connection and a SURF Research Cloud workspace. It
is the evidence base behind the `yoda` role's current shape and the open
follow-ups.
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

## Performance envelope — measured 2026-07-06 and 2026-07-13

Treat these as the **normal baseline**, not an incident (confirmed by the
operator: minute-plus portal loads are typical for this instance).

| Operation | Measured |
|---|---|
| Portal page load (TTFB), iRODS-heavy pages | 60–90 s routinely (Notifications worst) |
| Collection create (iRODS protocol) | ~3 s each |
| Small-file transfer, `gocmd sync --thread_num 15` | **~1.5 files/s** (631 files ≈ 7 min) |
| Large single file (`gocmd put`, parallel streams) | bandwidth-bound; round trip verified from SRC |
| 30 transfer threads | **saturates the server** — portal became unusable for all users; no server-side throttle observed |
| Server-side tar extraction (`gocmd bun -x`) | **~13–14 files/s**, steady 300 → 2,000 files (23.6 s / 2 m 22 s); `-f` re-extract of an unchanged/1-changed 300-file shard ~5.6–5.8 s |
| Large single object (`gocmd put`, 1 GB) | 12.0 s ≈ 85 MB/s, bandwidth-bound at default threads |
| Shard-tar milestone push+extract (`yoda-sync.sh push`, 450 files / 3 shards + state, first delivery) | 54 s (measured 2026-07-14, dev machine) |
| Shard-tar no-op push (checksum skip, 0 extractions) | 7.2 s (measured 2026-07-14) |
| Shard-tar single-shard delta (1 tar re-upload + 1 `bun -x`) | 10.8 s (measured 2026-07-14) |
| Shard-tar restore (`pull-resume`: state + 3 tars + local extract) | 6.8 s, tree byte-identical (measured 2026-07-14) |
| Same 452 files via `push-transcripts-plain` (per-file) | **6 m 18 s** (~1.2 files/s — the baseline, live; 7× slower than tar delivery even at toy scale) |

Consequences:

- **File-per-file transfer does not scale.** 130k files ≈ 24 h at the raw
  rate (a live ~100k sync indeed did not complete in 24 h — same baseline
  plus sync-restart re-listing and collection-create overhead as the remote
  tree grows); the 1M-video campaign (~2M files, ADR 0004 sharding) ≈
  **2+ weeks of continuous transfer**. SOLVED 2026-07-13 by shard-tar
  delivery + server-side extraction (see Transfer recipes and the bun -x
  section below).
- **`--bulk_upload` does NOT work on Yoda — but its failure is CLIENT-side.**
  It stages tarballs in a `.gocmd_staging` collection for server-side
  extraction; gocommands' staging-path safety check rejects research group
  collections, and `nluu10p` users have no personal home collection to
  point `--irods_temp` at. The 2026-07-06 guess that the server's policy
  layer would also block extraction was WRONG — `gocmd bun -x` works (see
  the 2026-07-13 section below). `storage-backends.md`'s original scale
  plan relied on bulk_upload; it is corrected.
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
  transcripts dir went to Yoda before being caught. Resolved 2026-07-13 for
  the default shard-tar path (`--exclude='.*'` at tar time); the plain
  per-file path (`push-transcripts-plain`) still syncs dotfiles — stage with
  a glob there if that matters.
- **`cp` is iRODS→iRODS.** Local↔remote is `put`/`get` (with `i:` prefixes on
  the iRODS side, matching `yoda-sync.sh`). `sync` is checksummed and
  idempotent — safe to interrupt and re-run.
- **Shard-tar delivery (the default).** `yoda-sync.sh push-transcripts`
  builds one byte-reproducible PLAIN archive per shard —
  `tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0
  --format=gnu --exclude='.*' -C <transcripts> NN` (no compression: `-D tar`
  is the verified server-side extraction format and transfer is
  bandwidth-bound anyway) — into a staging dir whose basename MUST be
  `transcripts-tars` (basename-append rule), then one
  `gocmd sync --thread_num 10`, then `gocmd bun -x -f -D tar
  --timeout 1200` per *changed* shard into `<collection>/transcripts`
  (changed set via a local md5 manifest). Unchanged shards are byte-
  identical, so the sync checksum-skips them and no extraction fires.
  Restore: `pull-resume` fetches the TARS and extracts locally — never the
  per-file projection. Legacy plain `transcripts/` collections still
  restore via the old sync path.
- The SRC↔Yoda network path is fully verified: control port 1247 and the
  20000–20199 data range both pass SURF's egress (put/get round trip,
  2026-07-06).

## Server-side extraction (`gocmd bun -x`) — verified 2026-07-13

The 2026-07-06 hypothesis that server-side extraction is policy-blocked was
wrong: what failed was `bput`'s client-side staging guardrail. The server's
native extraction works on stock gocmd:

```
gocmd put shard.tar i:<collection>/transcripts-tars/   # one network op
gocmd bun -x -f -D tar --timeout 1200 \
  i:<collection>/transcripts-tars/shard-NN.tar i:<collection>/transcripts
```

- Measured: put 310 KB/300-file tar 5.1 s; extract 300 files 23.6 s, 2,000
  files 2 m 22 s (**steady ~13–14 files/s**, no amortization — per-file
  policy cost moved server-side, client `user` time ~0.04 s); `-f`
  re-extract of a mostly-unchanged 300-file shard ~5.6–5.8 s.
- **`-f` is required for re-delivery**: bare re-extract fails fast with
  `SYS_COPY_ALREADY_IN_RESC` (-46000). Updated content propagates; new
  files materialize.
- **Raise `--timeout`**: gocmd's default 300 s is too short for a
  ~10k-file campaign shard (~12 min at ~14 files/s); `yoda-sync.sh` uses
  1200 s (`YODA_BUN_TIMEOUT`).
- Campaign arithmetic: ~2M files ≈ ~40 h total server-side extraction,
  amortized per changed shard across milestones (vs 2+ weeks client-side).
- Open questions (FSW thread): revision-store cost of `-f` overwrites;
  server behavior on client timeout mid-extraction.

## Researcher hand-off via anonymous read tickets — verified 2026-07-13

gocmd v0.12.2 has full ticket support (`mkticket`/`lsticket`/`modticket`/
`rmticket`, `-T` on `ls`/`get`), and the iRODS `anonymous` user is enabled
on fsw.data.uu.nl. Three-way control verified: anonymous env (12-line
credential-free config, `irods_authentication_scheme: native`) + no ticket
→ "not found" (existence not leaked); + read ticket → full `ls` and
byte-correct `get`. Flow: mint a read ticket on the collection, hand over
ticket string + anon config + a gocmd binary — no UU account, no DAP, no
CO membership. HYGIENE: defaults are permissive (`USES LIMIT 0`,
`EXPIRY TIME none`) — always `modticket` an expiry on real hand-offs;
`rmticket` revokes; `lsticket` audits.

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
5. iCommands are pre-installed on SURF's SRC Ubuntu image — an independent
   client for cross-checking gocmd behavior (`ils -A` for ACLs, `iquest`
   for metadata queries). Same DAP credential. Ticket hand-off is verified
   via gocmd's `mkticket`/`lsticket`/`modticket`/`rmticket`; iCommands'
   `iticket` should be equivalent but was not exercised.
