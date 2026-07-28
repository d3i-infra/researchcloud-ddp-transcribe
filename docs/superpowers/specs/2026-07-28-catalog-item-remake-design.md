# Catalog item remake: tiered storage + portal delta + 3M-run launch

*Spec from the 2026-07-28 brainstorming session. Companion plan to follow
(superpowers:writing-plans). Supersedes the from-scratch framing of
`docs/catalog-item.md` Steps A–H — the item exists; this is a new version push.*

## Goal

Re-version the existing **DDP Transcribe** catalog item (owner CO: D3I data
donation; component status: Development, Tag `main`) so it properly integrates
the three storage backends, then launch the **3M+ video campaign machine from
the remade item** as its Tier-5 validation. Urgent: the campaign machine is the
deliverable; the remake is its vehicle.

A parallel first-class output is the **snag list** (§8): every known way the
deploy can fail, with symptom → cause → fix, kept current as we execute.

## Decisions (settled in brainstorming)

| # | Decision | Choice |
|---|---|---|
| D1 | Sequencing | Remade item first; 3M machine launched from it (= Tier-5 validation) |
| D2 | 3M-run storage | Yoda is inbox origin + final sink; SRC volume is an interim fast tier |
| D3 | Hybrid wiring | `storage_backend: yoda` + non-blank `storage_path` ⇒ **tiered mode** (§3); working tree (hot path) **always boot disk** |
| D4 | Inspector | **Separate catalog item, never this one.** This item stays SSH-only; interop via the Yoda data-plane contract (§5) |
| D5 | Sync knobs | `YODA_EXTRACT` / `YODA_THREADS` / `YODA_BUN_TIMEOUT` stay script-level env, not SRC params |
| D6 | Owner CO | D3I data donation (already fixed — item exists) |
| D7 | Portal delta | Audited from the live item (§4); component **edited in place**, never recreated |
| D8 | Run topology | One 2×A10 workspace (flavour confirmed offered); 1×A10 fallback |
| D9 | Hop-2 cadence | Operator-driven (manual), ~daily; no systemd/cron in the component |
| D10 | Doc drift | Portal wins: `model_small` default `true`, `model_small`/`compute_lang_probs` Interactive |
| D11 | `download_workers` | Flip to Interactive at the item (default 3) — set per-launch; likely campaign bottleneck |

## 1. What the remake is (and is not)

The playbook already carries the full three-backend surface (`storage_backend`,
`yoda_*`, internals). The remake is:

1. **One playbook change** — tiered mode (§3) + preflight asserts + docs.
2. **One portal component edit** — declare the missing yoda surface (§4).
3. **Item wiring** for the new params + pre-launch CO setup.
4. **Doc rewrite** — `catalog-item.md` becomes a *current-state record + delta
   procedure + launch runbook*, not a from-scratch wizard walkthrough.

Not in scope: research-drive backend wiring (stays a hard-fail stub), inspector
implementation (own item, own spec), transcript pruning/retention, any systemd.

## 2. Storage architecture: three tiers

```
HOT (boot disk)                INTERIM (SRC volume)              DURABLE (Yoda)
~/ddp-work/{inbox,transcripts} <storage_path>/{inbox,transcripts, yoda_collection/{inbox,
~/ddp-state/state.sqlite        state-snapshot.sqlite}            transcripts-tars/, transcripts/,
                                                                  state-snapshot.sqlite}

── hop 1: fast, AUTOMATIC, end of every batch ──►
   sync-to-storage.sh — rsync transcripts + sqlite .backup snapshot → volume
   (today's mount-backend branch, verbatim; no gocmd in the hot path)

                               ── hop 2: slow, OPERATOR-DRIVEN (~daily) ──►
                                  push-to-yoda.sh — shard-tar build + gocmd push
                                  + server-side extract, sourced from the VOLUME
                                  (yoda-sync.sh unchanged; env points at
                                   <storage_path>/transcripts + snapshot)

◄── restore: fast, volume → boot ──  ◄── seed once / refresh: yoda → volume ──
   restore-from-storage.sh              pull-from-yoda.sh (inbox + resume state)
```

Inbox flows downhill only: Yoda → volume (slow, once / on refresh) → boot
(fast, every re-provision). New donor DDPs on Yoda are picked up by re-running
the pull. Losing the volume costs only the delta since the last hop-2 push;
re-attempts are idempotent (ADR 0008). State DB never leaves the boot disk;
only its `.backup` snapshots travel.

## 3. Playbook change: tiered mode

Activated when `storage_backend == 'yoda'` **and** `storage_path` is non-blank.
Plain yoda (blank `storage_path`) and `src-volume` behavior are unchanged.

- **`sync-to-storage.sh`** (hop 1): in tiered mode, generate the existing
  mount-backend branch (rsync + `.backup` snapshot to `storage_path`) instead
  of the gocmd branch. Existing flock serialization unchanged (both GPUs call
  it at batch end).
- **`push-to-yoda.sh`** (hop 2, new generated script): takes the sync lock
  **only** to capture a stable copy of `state-snapshot.sqlite` from the volume,
  then builds/pushes shard tars lock-free — safe because transcript artifacts
  are write-once and tar staging already excludes hidden entries (which also
  covers rsync in-flight temp files). A slow push never blocks a batch-end
  sync. Delegates to `yoda-sync.sh push` with
  `YODA_TRANSCRIPTS_LOCAL=<storage_path>/transcripts` and
  `YODA_STATE_SNAPSHOT=<stable snapshot copy>`.
- **`pull-from-yoda.sh`** (new generated script): `yoda-sync.sh` pulls of
  `inbox/` (and resume state on a fresh volume) **landing on the volume**, not
  boot. Used for the one-time seed and for inbox refreshes.
- **`restore-from-storage.sh`**: in tiered mode restores from the **volume**
  (existing mount-backend branch); if the volume is empty/fresh, the operator
  runs `pull-from-yoda.sh` first, then restore. The script fails loudly with
  that guidance rather than silently starting a fresh batch.
- **`preflight`**: in tiered mode assert `storage_path` exists and is a real
  mount (no silent boot-disk fallback); assert `yoda_data_access_password`
  arrived non-empty whenever backend is yoda, with a `fail_msg` naming the
  launching CO's Secrets tab (snag S1).
- Generated-file headers, `| bool` coercion, fully-qualified modules, flock
  pattern — all per existing conventions.

## 4. Portal delta (audited 2026-07-28 from the live item)

**Already correct, no action:** boot disk 100 GB; flavours 16C-64GB / A10-1GPU
/ **A10-2GPU (exists)**; `timeout=7200`, `co_passwordless_sudo=true`
overwrites; allowed COs incl. "perceptions of crime policing - UU"; firewall
22/80/443 in (80/443 immutable, nothing listens — expected, leave alone).

**Component edit (Development version, edit in place)** — six new
declarations, all Overwritable ✓:

| Parameter | Source type | Default | Description (short) |
|---|---|---|---|
| `storage_backend` | Fixed | `src-volume` | `src-volume` \| `yoda` \| `research-drive` (reserved) |
| `yoda_collection` | Fixed | *(blank)* | iRODS collection base path, e.g. `/nluu10p/home/research-foo` |
| `yoda_user` | Fixed | *(blank)* | Yoda username, e.g. `user@uu.nl` |
| `yoda_host` | Fixed | `fsw.data.uu.nl` | iRODS host (UU default) |
| `yoda_zone` | Fixed | `nluu10p` | iRODS zone (UU default) |
| `yoda_data_access_password` | **Co-Secret** | *(secret)* | Yoda DAP; resolved from the **launching** CO's Secrets tab |

**Existing-param updates:** `storage_path` description becomes backend-aware —
mount backends: durable sink; yoda: optional interim fast tier, blank ⇒ direct
to Yoda. `download_workers` becomes Interactive at the item (D11).

**Item wiring (new params):** `storage_backend`, `yoda_collection`,
`yoda_user` → Make interactive with loud placeholder defaults; `yoda_host`,
`yoda_zone` → Keep. Co-Secret needs no wiring, but the secret must exist on the
launching CO (§6 step 3).

**Doc reconciliation (D10):** doc matches portal for `model_small` (true,
Interactive) and `compute_lang_probs` (Interactive).

## 5. Inspector data-plane contract (interop only)

The inspector is a separate catalog item on its own workspace; an SRC volume
attaches to one workspace only, so **Yoda is the shared data plane**:

- This item guarantees under `yoda_collection`: `inbox/` (donor DDP JSONs),
  `transcripts/` (server-side-extracted sharded tree `NN/<id>.txt|.json` —
  exactly the inspector's `transcripts_dir` layout), `transcripts-tars/`,
  `state-snapshot.sqlite`. No hidden files.
- **Freshness:** the Yoda tree lags the pipeline by the hop-2 cadence
  (~daily). The inspector's "not transcribed yet" state covers the gap.
- **Access:** anonymous read ticket (`gocmd mkticket -t read`; verified
  2026-07-13) — read-only, no DAP, no CO membership on the inspector side.
  Hygiene: set expiry via `modticket`; `rmticket` revokes; `lsticket` audits.
- This contract gets a named section in `docs/storage-backends.md` that the
  inspector's spec cites. Nothing else here
  changes for the inspector.

## 6. Execution sequence (critical path to the 3M machine)

1. **Playbook PR** — §3 changes + doc rewrite (Danielle merges; Tag=`main`
   means the next provision picks it up automatically).
2. **Portal component edit** — §4 declarations + description updates + item
   wiring (incl. `download_workers` → Interactive).
3. **Pre-launch CO setup** on "perceptions of crime policing - UU": create the
   `yoda_data_access_password` Co-Secret from a **freshly generated DAP**
   (generate immediately before provisioning; never reuse a failed one);
   create the SRC volume in that CO — check growability, else oversize
   (transcripts + inbox + snapshots).
4. **Flavour availability check** — confirm A10-2GPU schedules that day
   (2026-07-13 outage precedent); fallback 1×A10.
5. **Launch = Tier-5 validation** — 2×A10, `storage_backend=yoda`,
   collection/user/`storage_path`/`download_workers` interactive values,
   volume attached at the second-to-last wizard step.
6. **Validation checklist** before the campaign (§7).
7. **Campaign start**; then promote component Development → Live and fill the
   item record + validation log in `catalog-item.md`.

## 7. Validation checklist (on the launched machine)

- Deployment log green, **zero manual SSH fixes**.
- `ddp-transcribe --help`; `ldd $(which ddp-transcribe) | grep libcudart`.
- Both `~/run-pipeline-gpu0.sh` and `-gpu1.sh` exist; `~/push-to-yoda.sh`,
  `~/pull-from-yoda.sh`, `~/sync-to-storage.sh`, `~/restore-from-storage.sh`,
  `~/ddp-state/` present.
- Tiered round-trip smoke: `pull-from-yoda.sh` seeds volume → restore hydrates
  boot → process a handful of videos → hop 1 lands transcripts + snapshot on
  the volume → hop 2 lands shard tar + extracted tree on Yoda (verify in the
  portal).
- Both GPUs processing concurrently — **first real R11 claim-contention
  test**: watch for stale `processing` rows / double-claims in the state DB.
- Pause/resume the workspace; layout and tokens survive.
- Record: cold provision wallclock, boot-disk high-water `df -h`, per-video
  rates, hop-1/hop-2 wallclocks.

## 8. Snag list (deploy-time debugging playbook)

| # | Snag | Symptom → cause → fix |
|---|---|---|
| S1 | Co-Secret missing on launching CO | gocmd init fails/empty password at provision → secret created on wrong CO (it resolves from the **launching** CO) → create it on the campaign CO's Secrets tab; preflight assert names this |
| S2 | DAP burned by failed attempts | auth keeps failing with the "right" password → failed-attempt bursts permanently invalidate a DAP → regenerate fresh; never retry a failed one |
| S3 | `$` in the DAP | auth fails only via automation → interpolation layer eats `$` → regenerate until no `$` (or verify it survives to gocmd) |
| S4 | **PAM token expiry mid-campaign** | hop-2 pushes start failing ~day 30 → `yoda_auth_ttl_hours: 720` < 35–70-day campaign and the DAP is (deliberately) not on disk → documented renewal: fresh DAP + re-run `gocmd init` on the box; calendar ~day 28 |
| S5 | A10 capacity/provider outage | launch/resume fails (seen 2026-07-13) → provider-side → check same-day schedulability first; 1×A10 fallback doubles wallclock but unblocks |
| S6 | CUDA floats with NVIDIA latest | whisper-rs build breaks on a future release → SRC CUDA component installs NVIDIA current → force our pinned 13.2 toolkit (install even when nvcc present) |
| S7 | Component recreated instead of edited | params vanish from the item → new component ≠ referenced development version → always **edit** the existing component |
| S8 | Undeclared param silently absent | value set at item has no effect → SRC only passes declared params → declare at the component first (that's this remake) |
| S9 | Placeholder default left unedited | preflight fails loudly on `<username-fill-me-in>`-style paths → by design; fill the interactive fields |
| S10 | Volume/`storage_path` mismatch | tiered preflight assert fails → path must be exactly `/home/<pipeline_user>/data/<volume-name>` (`volume_mount_no_name=false`) → fix the interactive value |
| S11 | Undersized volume mid-campaign | volume fills ~week N → transcripts accumulate, no pruning → size generously at creation; check growability beforehand |
| S12 | R11 two-GPU claim contention | stale `processing` rows / double-claims → first real concurrent test → validation step watches the state DB; pipeline-repo issue if seen |
| S13 | First hop-2 push at scale | `bun -x` timeout / server saturation → huge first delta → `YODA_BUN_TIMEOUT` generous (≥1200 s), `YODA_THREADS ≤ 15` (30 saturated the server 2026-07-06) |
| S14 | Boot-disk watermark | `ENOSPC` late in campaign → ~3M transcripts ≈ 30–40 GB + models + toolkit on 100 GB → fine but monitor `df -h`; escalate to pruning design only if real |
| S15 | 80/443 open, nothing listens | scanner/reviewer alarm → immutable item rules, no service bound → expected; do not "fix" |
| S16 | `download_workers` pacing | GPUs idle, inbox starving / TikTok rate-limits → downloader is the campaign bottleneck → set per-launch (now Interactive), tune from observed throughput |

## 9. Open items carried, not blocking

- Two pending FSW questions (revision minting on `bun -x -f`; server behavior
  on client disconnect) — may flip `YODA_EXTRACT` default later; env-only.
- `pipeline_git_ref` stays `v0.2.0-rc1`; promote to `v0.2.0` + bump the item
  overwrite after the campaign machine validates.
- Tier-1 ansible-lint venv (Python 3.14) still broken; lint via Tier-2.
- Leftover untracked `test-yoda.yaml` in the repo root — delete or promote
  before the playbook PR.
