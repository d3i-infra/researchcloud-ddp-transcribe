# DDP Transcribe — catalog item record, remake delta, and launch runbook

The **DDP Transcribe** catalog item already exists and is live in the SURF
Research Cloud (SRC) portal. This doc is:

1. **Item record** — the audited current state of the portal item (§1).
2. **Delta** — the portal edits this remake pushes, to add the Yoda tiered-storage
   surface (§2).
3. **Pre-launch CO setup** the launching CO must do before provisioning (§3).
4. **Launch runbook** for the 3M-video campaign machine, which doubles as this
   remake's Tier-5 validation (§4).
5. **Snag list** — every known way the deploy can fail, kept current (§5).
6. **Validation log** — filled in at launch (§6).

General portal mechanics (wizard navigation, component vs. item concepts) live
in the SURF-distilled `surf_research_cloud/runbooks/create-catalog-item.md`;
this page only carries ddp-transcribe-specific values and decisions.

## 1. Item record (current, audited 2026-07-28)

- **Owner CO:** D3I data donation (permanent, matches the existing "Next for
  data donation" item).
- **Component:** `ddp-transcribe` — status **Development**, Tag `main`
  (`d3i-infra/researchcloud-ddp-transcribe`, `deploy-ddp-transcribe.yaml`).
- **Boot disk:** 100 GB.
- **Flavours offered:** `16 Core - 64 GB RAM`, `A10 - 1 GPU`, `A10 - 2 GPU`.
- **Allowed COs:** D3I data donation, develop-data-donation-pipelines-uu,
  perceptions of crime policing - UU.
- **Firewall:** inbound TCP 22/80/443; 80/443 are **immutable** and nothing
  listens on them — expected, not a bug, leave alone (S15).
- **Overwrites in force:** `timeout=7200`, `co_passwordless_sudo=true`.
- **Support:** Danielle McCool, D.M.McCool@uu.nl.
- **Documentation URL:** `https://github.com/d3i-infra/researchcloud-ddp-transcribe`
- **Components (in order):** SRC-OS, SRC-CO, SRC-External plugin, CUDA,
  ddp-transcribe (Development).

### Currently declared component parameters

Ten parameters declared on the component today, all Source type `Fixed`
(Overwritable ✓) unless noted. Portal is authoritative over any prior doc
draft — in particular `model_small`'s default is `true`, not `false`.

| Parameter | Action at item | Default | Notes |
|---|---|---|---|
| `compute_lang_probs` | Interactive | `false` | per-language probability pass, ~1.5–2× slower |
| `download_workers` | Keep | `3` | parallel video-download workers |
| `force_cpu_build` | Keep | `false` | debug aid; bypasses GPU-without-driver hard-fail |
| `model_large_v3_turbo` | Interactive | `true` | ~573 MB, recommended production model |
| `model_small` | Interactive | **`true`** | ~466 MB multilingual fallback — portal is authoritative here, not `false` |
| `model_tiny_en` | Interactive | `false` | ~75 MB, English-only, smoke-test speed |
| `pipeline_git_ref` | Keep | `v0.2.0-rc1` | pipeline repo tag (two version pins — see §2) |
| `pipeline_user` | Interactive | placeholder `<username-fill-me-in>` | workspace account owning the run layout |
| `run_smoke_test` | Keep | `false` | init+ingest against a bundled fixture at provision |
| `storage_path` | Interactive | placeholder `/home/<username>/data/<volume-name>` | mount point of the attached storage volume |

## 2. The delta to push (this remake)

The playbook already carries the full three-backend surface
(`storage_backend`, `yoda_*`, tiered-mode internals — see
`docs/superpowers/specs/2026-07-28-catalog-item-remake-design.md` §2–3). The
portal component does not yet declare the Yoda parameters — undeclared params
have no effect (S8) — so this is a **component edit** (never a recreate — S7)
on the existing Development version.

> **Two version pins, don't confuse them:** the component's **Tag** (Step 1 of
> the "Add component" wizard) pins the *component repo* (`main`); the
> `pipeline_git_ref` parameter pins the *pipeline repo*
> (`v0.2.0-rc1`). A provisioning-only fix changes the component (re-clone
> `main`, re-run); a pipeline release changes `pipeline_git_ref` (rebuild).
> This distinction matters most when editing the component (below): don't
> confuse re-tagging the component repo with bumping the pipeline ref.

> **Co-Secret `$`-interpolation quirk (S3):** a literal `$` in the Yoda data-access
> password can be eaten by a shell/compose interpolation layer before it reaches
> `gocmd`. If auth only fails via automation (not when pasted by hand), regenerate
> the DAP until it contains no `$`, or verify independently that `$` survives to
> `gocmd` in this environment. Relevant here because the `yoda_data_access_password`
> Co-Secret is one of the six declarations this component edit adds (below).

> **Edit, never recreate (S7).** Recreating the component orphans the item's
> reference to the old development version and every declared param vanishes
> from the item. Always **edit** `ddp-transcribe` in place.

> **Undeclared params silently do nothing (S8).** SRC only passes params
> explicitly declared on the component to the playbook. A param set at the
> item with no matching component declaration has zero effect — no error,
> just silence. This is exactly the bug this remake fixes for the yoda surface.

### New component declarations (six)

The five Fixed params are **Overwritable ✓** (needed for the item's
Make-interactive/Overwrite wiring). `yoda_data_access_password` is
**Overwritable ✗ (unchecked)** — the Co-Secret must only ever resolve from
the launching CO's Secrets tab; overwritable would permit an item-level
literal or an interactive password prompt, both wrong for a secret.

Copied verbatim from spec §4:

| Parameter | Source type | Default | Description (short) |
|---|---|---|---|
| `storage_backend` | Fixed | `src-volume` | `src-volume` \| `yoda` \| `research-drive` (reserved) |
| `yoda_collection` | Fixed | *(blank)* | iRODS collection base path, e.g. `/nluu10p/home/research-foo` |
| `yoda_user` | Fixed | *(blank)* | Yoda username, e.g. `user@uu.nl` |
| `yoda_host` | Fixed | `fsw.data.uu.nl` | iRODS host (UU default) |
| `yoda_zone` | Fixed | `nluu10p` | iRODS zone (UU default) |
| `yoda_data_access_password` | **Co-Secret** | `{"key": "yoda_data_access_password", "sensitive": 1}` | Yoda DAP; resolved from the **launching** CO's Secrets tab |

> **Co-Secret declaration format:** the Default value field of a Co-Secret
> parameter takes a JSON object, not a bare key name:
> `{"key": "<secret name on the CO Secrets tab>", "sensitive": 1}`.
> `sensitive: 1` (the default) keeps the value out of provisioning logs — do
> not set 0 for a password. The `key` string must exactly match the secret's
> name on the **launching** CO's Secrets tab or the lookup silently resolves
> nothing (preflight then fails with the S1 message).

### Existing-param updates

- **`storage_path` is now an optional override** — preflight **auto-detects**
  the attached volume: SRC mounts volumes at `/home/<user>/data/<volume-name>`,
  so when exactly one mount exists there it is adopted automatically (resolved
  into the `storage_root` fact all consumers use; SRC extra-vars outrank
  `set_fact`, hence the separate fact name). An unedited `<...>` placeholder
  counts as unset; multiple volumes fail loudly asking for an explicit path.
  Mount backends still require a volume (detected or explicit); on `yoda` a
  resolved volume activates **tiered mode**, no volume means direct-to-Yoda.
  Suggested description: *"Mount path of the attached storage volume. Usually
  leave as-is: with exactly one volume attached the workspace finds it
  automatically. Set explicitly only with multiple volumes. Yoda backend:
  attaching a volume enables tiered mode; no volume = direct-to-Yoda."*
- **`download_workers`** flips from Keep to **Interactive** at the item (D11)
  — likely the campaign bottleneck (S16), so it needs to be tunable per-launch
  rather than fixed at `3`.

### Item wiring (new params)

- `storage_backend`, `yoda_collection`, `yoda_user` → **Make interactive**
  with loud, non-existent placeholder defaults (so an unedited field fails
  preflight loudly — S9 — rather than silently doing the wrong thing).
- `yoda_host`, `yoda_zone` → **Keep** (UU defaults are correct).
- `yoda_data_access_password` (Co-Secret) needs no item wiring, but the secret
  itself must exist on the **launching** CO before provisioning (§3).

### Doc reconciliation (D10)

This doc now matches the portal for `model_small` (default `true`,
Interactive) and `compute_lang_probs` (Interactive) — the previous draft of
this doc had both wrong.

## 3. Pre-launch CO setup

Do this on the CO the workspace will actually be **launched** in — for the 3M
campaign, "perceptions of crime policing - UU". The Co-Secret resolves from
the launching CO, not the owner CO, and not any other CO the item is shared
with (S1).

1. **Generate a fresh Yoda data-access password (DAP)** — Yoda web portal →
   Data Transfer. Generate it **immediately before** provisioning; never reuse
   a DAP that has already failed once (S2 — failed-attempt bursts permanently
   invalidate a DAP). Check the generated string for a literal `$` (S3 above);
   regenerate if present, or confirm separately that it will survive to
   `gocmd`.
2. **Create the `yoda_data_access_password` Co-Secret** on that CO's Secrets
   tab with the fresh DAP. The secret's name must be exactly
   `yoda_data_access_password` — it must match the `key` in the component's
   Co-Secret declaration JSON (see §2).
3. **Create the SRC volume** in the same CO: SRC portal → CREATE NEW →
   storage card → SURF HPC Cloud volume → same CO as the workspace → name it
   (e.g. `ddp-transcribe-<study>`).
   - **Size generously and check growability first** (S11): the volume holds
     accumulating transcripts + inbox + state snapshots with no pruning across
     a 35–70-day campaign; budget ~2× the transcript tree — hop 2 stages shard
     tars (`transcripts-tars/`) on the volume alongside the extracted files
     (S11). If the volume type isn't growable in place, oversize at creation
     rather than planning a mid-campaign resize.
4. **Note the DAP renewal calendar date** (~day 28 of the campaign): the Yoda
   PAM token TTL (`yoda_auth_ttl_hours: 720`, i.e. 30 days) is shorter than the
   campaign, and the DAP is deliberately never written to disk, so renewal is
   a documented manual step, not automatic (S4).

## 4. Launch runbook (3M campaign = Tier-5 validation)

The 3M-video campaign machine is the deliverable; this remade item is its
vehicle, and launching it is simultaneously this remake's Tier-5 validation.
Steps 4–7 below are spec §6 verbatim; the checklist in the middle is spec §7.

**4. Flavour availability check** — confirm A10-2GPU schedules that day before
committing to the launch window (2026-07-13 saw a provider-side outage on this
flavour); fallback is 1×A10 (doubles wallclock, unblocks if 2×A10 is
unavailable).

**5. Launch = Tier-5 validation** — 2×A10, `storage_backend=yoda`, interactive
values for `yoda_collection` / `yoda_user` / `download_workers`; leave
`storage_path` at its placeholder (the single attached volume is
auto-detected); volume attached at the second-to-last wizard step
("Attach the storage volume").

**6. Validation checklist** (run on the launched machine before the campaign
starts):

- Deployment log green, **zero manual SSH fixes**.
- `ddp-transcribe --help`; `ldd $(which ddp-transcribe) | grep libcudart`.
- Both `~/run-pipeline-gpu0.sh` and `-gpu1.sh` exist; `~/push-to-yoda.sh`,
  `~/pull-from-yoda.sh`, `~/sync-to-storage.sh`, `~/restore-from-storage.sh`,
  `~/ddp-state/` all present.
- **Tiered round-trip smoke:** `pull-from-yoda.sh` seeds the volume → `restore-from-storage.sh`
  hydrates boot → process a handful of videos → hop 1 (`sync-to-storage.sh`,
  automatic at batch end) lands transcripts + snapshot on the volume → hop 2
  (`push-to-yoda.sh`, operator-run) lands the shard tar + server-side
  extracted tree on Yoda (verify in the portal / via `gocmd`).
- Both GPUs processing concurrently — **first real R11 claim-contention
  test**: watch the shared state DB for stale `processing` rows or
  double-claims (S12).
- Pause/resume the workspace; confirm the run layout and tokens survive.
- **Record:** cold provision wallclock, boot-disk high-water `df -h`,
  per-video rates, hop-1/hop-2 wallclocks — into §6 below.

**7. Campaign start**, then promote the component **Development → Live** and
fill in the item record + validation log in this doc.

> **Launch gate:** the 3M campaign run waits on a pending update to
> `daniellemccool/ddp-transcribe` (the pipeline repo). Once its tag is cut,
> the item's `pipeline_git_ref` overwrite gets updated to it — until then, the
> launch uses `v0.2.0-rc1` as declared above.

## 5. Snag list (deploy-time debugging playbook)

This doc is the long-term home for this table — keep it current as new snags
surface.

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
| S9 | Placeholder default left unedited | `pipeline_user` / `yoda_collection` / `yoda_user` placeholders fail loudly at preflight → by design; fill those interactive fields. Exception: `storage_path`'s placeholder is the happy path — it means "auto-detect the attached volume" |
| S10 | Volume path mismatch / ambiguity | preflight fails (path not found, or multiple volumes listed) → auto-detection adopts the single mount under `~/data`; several mounts or a typo'd explicit `storage_path` fail loudly → leave `storage_path` at the placeholder with exactly one volume attached, or set it to the exact mount |
| S11 | Undersized volume mid-campaign | volume fills ~week N → transcripts accumulate, no pruning → size generously at creation; check growability beforehand |
| S12 | R11 two-GPU claim contention | stale `processing` rows / double-claims → first real concurrent test → validation step watches the state DB; pipeline-repo issue if seen |
| S13 | First hop-2 push at scale | `bun -x` timeout / server saturation → huge first delta → `YODA_BUN_TIMEOUT` generous (≥1200 s), `YODA_THREADS ≤ 15` (30 saturated the server 2026-07-06) |
| S14 | Boot-disk watermark | `ENOSPC` late in campaign → ~3M transcripts ≈ 30–40 GB + models + toolkit on 100 GB → fine but monitor `df -h`; escalate to pruning design only if real |
| S15 | 80/443 open, nothing listens | scanner/reviewer alarm → immutable item rules, no service bound → expected; do not "fix" |
| S16 | `download_workers` pacing | GPUs idle, inbox starving / TikTok rate-limits → downloader is the campaign bottleneck → set per-launch (now Interactive), tune from observed throughput |
| S17 | Component log fully censored on yoda launches | provisioning failure shows only "censored / no_log" → SRC-External's wrapper `no_log`s its whole result because the Co-Secret is on its command line — every preflight fail_msg is invisible → debug input-side: check the launching CO's secret, the interactive values, then replay preflight locally (`scripts/test-preflight-autodetect.sh` pattern); confirmed live 2026-07-28 |

## 6. Validation log

**Launch 1 — 2026-07-28, workspace `2c665b20` — FAILED at preflight (17 s).**
Root causes: `storage_backend` was not wired Interactive at the item (launch
ran `src-volume` despite yoda values filled), and `~/data` is a symlink to a
shared mount root, which the then-current auto-detection missed (fixed same
day, PR #7). Output was fully censored (S17). SRC auto-destroyed the failed
workspace.

**Launch 2 — 2026-07-28, workspace `474557fc` (`uutiktok`) — GREEN, campaign
machine.**

- **Workspace name:** UU Tiktok DDP Transcription Run (`uutiktok`)
- **CO:** perceptions of crime policing - UU; volume `transcription-pipeline-run` (250 GB)
- **Flavour:** A10 - 2 GPU (`gpu-a10-22core-176gb-50gb-3tb`; 48 gpu-hrs/day
  confirms 2 GPUs; each instance sees 1 device via `CUDA_VISIBLE_DEVICES`)
- **Cold provision wallclock:** ~14 min (17:48 launch → ~18:02 layout on volume);
  zero manual fixes
- **Auto-detect:** adopted `/data/transcription-pipeline-run` (`/dev/vdc1`, xfs)
  through the symlinked `~/data` root; correctly rejected the stray `datasets`
  dir (not in mount table). Tiered mode active (all six generated scripts).
- **Ingest:** 2,982,461 unique videos from 141/142 donor files, 4,847,392
  history rows, 2,386,212 duplicates collapsed, 16 invalid URLs — 29 min.
- **Per-video rates:** transcription 0.3–0.7 s/video/GPU (large-v3-turbo,
  flash-attn); observed campaign throughput ~1.05 videos/s on 2 GPUs
  (download-paced) → ≈33 days for the full queue. Failure rate first 2k batch:
  ~13% (breakdown not yet taxonomized).
- **Hop 1:** seconds; auto at batch end — NOTE: uncapped runners never hit a
  batch end; ritual is `sync-to-storage.sh && push-to-yoda.sh` (FOLLOWUPS).
- **Hop 2:** minutes at 13k scale; **`YODA_EXTRACT=0` required** — server-side
  extraction is `MSI_OPERATION_NOT_ALLOWED` on this collection (FOLLOWUPS, FSW).
- **R11 observations:** concurrent 13+10-video runs — zero stale claims, no
  double-claims, flock serialized both batch-end syncs. ONE anomaly: the
  `claimed=13` run's DB updates were apparently lost (its videos reverted to
  pending; transcripts existed) and were idempotently re-done by a later sweep
  (ADR 0008). Watch-item: `pending` must only decrease; a bump = recurrence.
  Filed against the pipeline repo.
- **Pipeline:** started on `v0.2.0-rc1`; upgraded in place to `v0.3.0`
  2026-07-29 (item's `pipeline_git_ref` overwrite updated to match).
