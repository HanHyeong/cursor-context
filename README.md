# cursor-context

**Cursor-grade automatic project context awareness for Claude Code** — zero-touch, real-time, and honest about what it knows.

> 한국어 문서: [README.ko.md](README.ko.md) · Status: **Beta** · License: MIT
>
> [![CI](https://github.com/HanHyeong/cursor-context/actions/workflows/ci.yml/badge.svg)](https://github.com/HanHyeong/cursor-context/actions/workflows/ci.yml)
> — shellcheck + [bats](tests/) on an ubuntu/macOS matrix

Cursor IDE understands your project without being told, thanks to background
indexing, `.cursorrules`, and automatic context injection. This toolkit
recreates that experience in Claude Code using hooks and skills — so Claude
already knows your stack, structure, commands, and what your branch is working
on *before* you type your first prompt.

| Cursor feature | This toolkit's counterpart |
|---|---|
| Background codebase index (internal artifact) | `.cursor-context/project-context.md` — auto-generated doc, injected every session |
| Merkle-tree change detection | Content fingerprints compared against the **live working tree** |
| Index refresh on save | 3-tier auto-refresh: on noticed discrepancy / on structural change / 20-commit backstop |
| `.cursorrules` (user-authored rules) | `CLAUDE.md` — **user-owned, never touched by the toolkit** |
| Per-query semantic code search | Delegated to Claude Code's native agentic search (Grep/Glob) |

**Division of labor:** Cursor's magic has two layers — (a) project-level
knowledge and (b) per-query embedding retrieval. This toolkit fully recreates
**(a)**. Layer (b) is intentionally left to Claude Code's own live search,
which is already strong and always current. Toolkit knowledge + Claude's
search ≈ the Cursor experience.

---

## Quick start

```bash
git clone https://github.com/HanHyeong/cursor-context.git
cd cursor-context
./install.sh /path/to/your/project
```

That's it. Restart Claude Code in your project — everything else is automatic.

## What happens after install

1. **Every session start** — a hook injects a compact snapshot into context:
   - Detected stack (Node/Python/Go/Rust/Java/…), package manager, frameworks, npm scripts
   - Directory tree (depth 2, tracked files)
   - Git state: branch, recent commits, uncommitted changes
   - **Branch intent**: `diff --stat` of your branch vs the default branch — the
     strongest signal for interpreting terse prompts like "continue" or "finish this"
   - The generated project doc (if present) plus a freshness verdict
2. **At install time** — `install.sh` immediately runs a headless Claude
   session that generates `.cursor-context/project-context.md` (commands
   verified by running them, architecture, conventions, gotchas — under
   200 lines). Installing is the opt-in, so indexing starts right away,
   like Cursor indexing a project the moment you open it. Takes 1–3 minutes
   and uses API tokens; skip with `--no-onboard`. Be aware what "verified
   by running them" means: the session may execute the project's own
   test/lint/typecheck/build commands to confirm they work. It is
   instructed to run **side-effect-free commands only** — deploy, publish,
   migration, or anything state-changing is never executed, only checked
   for existence — but if you don't want anything running at install time,
   use `--no-onboard`. If the `claude` CLI is
   unavailable or the run fails, generation falls back to happening
   silently after your first real task (also after sessions where you asked
   about the project itself — the exploration already happened, so the
   knowledge is kept instead of thrown away).
3. **On every prompt** — a hook re-fingerprints structural files
   (manifests, lockfiles, CI, build config, directory layout) against the live
   working tree. If nothing changed it prints **nothing** (zero token cost).
   If something changed — even uncommitted edits, rollbacks, rebases, or
   branch switches — Claude is told exactly what differs, not to trust the
   affected doc sections, and to silently refresh the doc after finishing
   your request.

## Detailed usage

### Requirements

- `bash`, `git` (you already have these if you use Claude Code)
- `sha256sum` (Linux) or `shasum` (macOS) — one of them ships with your OS
- `python3` — optional, only used to auto-merge hook registration into an
  existing `settings.json`

### Installation details

`install.sh <target>` copies six hook scripts and three skills into the
target's `.claude/` directory, registers four hooks (SessionStart,
UserPromptSubmit, Stop, PostToolUse), and adds one `permissions.allow` rule —
`Bash(.claude/hooks/*)` — so the skills can run the gate scripts (e.g.
`context-benchmark.sh`) through the Bash tool without a permission prompt.
Without that rule, sessions that never granted the permission silently skip
evolution, signals are never consumed, and the Stop gate re-fires every new
session. Machine-generated data lives in
`.cursor-context/` at the project root — deliberately outside `.claude/`,
because Claude Code protects writes under `.claude/` and keeping data there
would require an approval for every automatic update, breaking zero-touch. It is **non-destructive
and idempotent**:

- An existing `settings.json` is never overwritten. Hook entries are
  **appended** to its `hooks` arrays and the permission rule to
  `permissions.allow` via python3 (all your keys, hooks, and allow entries are
  preserved and keep running; JSON semantics preserved, though indentation may
  be reformatted; the original is backed up first). If python3 is missing or
  the JSON is malformed, your file is left untouched and a
  `settings.hooks-example.json` is provided for manual merging.
- Same-named hooks/skills that differ from ours are backed up to
  `.claude/backup/install-<timestamp>/` — deliberately *outside*
  `.claude/skills/` so backups are never picked up as live skills.
- Re-running the installer changes nothing when contents are identical
  (no duplicate hook entries, no backup clutter).

Manual install: copy `.claude/` into your project root,
`chmod +x .claude/hooks/*.sh`, and merge the `hooks` block and the
`permissions.allow` rule of `settings.json` into yours (append to the
arrays — additive, existing hooks keep working).

### Plugin install (alternative)

Claude Code plugins are supported natively via the [`plugin/`](plugin/)
directory — no `install.sh`, no writes under your project's `.claude/`:

```
/plugin marketplace add HanHyeong/cursor-context   # or: point at a local checkout
/plugin install cursor-context
```

The plugin ships the same hook scripts and skills as `install.sh`, just
addressed by `${CLAUDE_PLUGIN_ROOT}` instead of
`${CLAUDE_PROJECT_DIR}/.claude`. Machine-generated data still lands in
`.cursor-context/` at your project root either way — a plugin install is not
project-scoped storage, so this keeps the two distributions interchangeable.
Both installation methods are maintained side by side for now; `install.sh`
will be marked deprecated only after the plugin path has had a release or two
to prove out.

### The generated document

`.cursor-context/project-context.md` is a machine artifact, like Cursor's index:

- Header markers carry the generation commit and a content fingerprint —
  stripped out before injection so Claude never sees hash noise
- Injection is capped at 250 lines, and truncation is **announced**, never silent
- By default it stays uncommitted (auto-added to `.gitignore`). **For teams,
  commit it instead**: remove the `.gitignore` line — one person's generation
  then serves everyone, and refreshes are shared too
- You may edit it by hand, but durable instructions belong in `CLAUDE.md`;
  hand edits can be overwritten by the next auto-refresh

### Configuration

`install.sh` writes `.cursor-context/config` (KEY=VALUE, `#` comments) with a
guessed `LANG` based on your system locale at install time. Delete the file,
or any line in it, to fall back to the built-in defaults — nothing breaks if
it's missing.

| Key | Default | Meaning |
|---|---|---|
| `LANG` | `en` | `ko` or `en` — language of hook-injected text and installer output |
| `FEEDBACK_THRESHOLD` | `5` | feedback entries before the evolve gate fires |
| `METRICS_THRESHOLD` | `300` | metric lines before the evolve gate fires |
| `COMMIT_BACKSTOP` | `20` | commits since doc generation before a refresh is requested |
| `DOC_LINE_BUDGET` | `200` | target line budget `context-benchmark.sh` enforces (WARN at +50, FAIL beyond that) |
| `DOC_MIN_LINES` | `10` | minimum non-empty body lines — below this the benchmark FAILs, so a rewrite that guts the doc can never be adopted |

`PASS`/`WARN`/`FAIL` and the `Result: PASS=x WARN=y FAIL=z` summary line stay
in that exact form regardless of language — `context-evolve`'s acceptance
criterion parses those literal tokens.

### Manual commands (optional — automation covers these)

- `/project-onboard` — force a full regeneration of the project doc
  (deep parallel exploration; use after major restructuring)
- `/context-refresh` — force an incremental update (diff-driven; only
  affected sections are rewritten)

### Freshness model (why you can trust what's injected)

Staleness is judged by **content, not commit counts**. The doc stores sha256
fingerprints of structural files plus a directory-layout hash; hooks recompute
them against the working tree at session start and on every prompt. Practical
consequences, all covered by [`tests/fingerprint.bats`](tests/fingerprint.bats)
and [`tests/hooks.bats`](tests/hooks.bats), which run in CI on every push:

- Uncommitted manifest edits are caught immediately
- Rebases, squash merges, hard resets, branch switches — all detected;
  rolling back to the documented state makes the fingerprint match again,
  so no wasted refresh
- Scratch files and notes do **not** trigger false "structure changed" alarms
  (only directories and structural files are fingerprinted)
- `.cursor-context/` itself (the toolkit's own data layer — doc, metrics,
  evolve backups) is excluded from the structure hash, so toolkit activity
  never triggers its own refresh alarm — including in team mode, where the
  directory is committed and evolve backups would otherwise show up as new
  untracked directories
- If verification is impossible (no hash tool, missing marker), the toolkit
  says so — it never claims "verified" when it isn't
- Priority rules are injected alongside everything: **live code beats the
  doc, and your `CLAUDE.md` beats both**

### Self-evaluation and evolution

The toolkit doesn't just stay fresh — it learns from how it gets used, via a
measure → reflect → mutate → select loop:

- **Measure (deterministic, zero tokens)** — a `PostToolUse` hook logs which
  commands Claude runs and which files/patterns it explores to
  `.cursor-context/metrics.jsonl` (fields truncated, auto-rotated at 2,000 lines,
  local-only). Pure code: the LLM cannot bias its own measurements.
  Privacy note: logged commands are plaintext. Credential-shaped values
  (`token=`, `password=`, `api-key=`, `Bearer …`) are redacted best-effort
  before writing, but that is a safety net, not a guarantee — don't pass raw
  secrets as CLI arguments. The file is gitignored and never leaves your
  machine. Self-observation is excluded: calls whose target path is inside
  `.cursor-context/`, and Bash commands that invoke the toolkit's own
  scripts, are not logged — the toolkit measuring its own activity would
  pollute the very signals it collects.
- **Reflect (near-zero cost)** — every session carries a standing rule: if the
  doc was wrong or missing something that required real exploration, append
  one JSON line to `.cursor-context/context-feedback.jsonl` after finishing the task.
- **Evolve (gated, deterministically enforced)** — once enough signal
  accumulates (5 feedback entries or 300 metric lines), a `Stop` hook
  (`evolve-gate.sh`) blocks the turn from ending until `/context-evolve`
  runs after your request — injected "do it later" instructions proved
  only probabilistic in testing, so enforcement lives in the harness, not
  in model compliance. Analysis starts from a deterministic digest
  (`metrics-collector.sh --digest`: hit counts plus distinct-session
  tallies per command/path), not the raw log — cross-session
  recurrence is the evidence that matters, and pure-code counting is exact.
  Evolution fixes what was wrong, adds what multiple sessions had to
  re-explore, and checks `evolve-log` for recurrence: an area a past
  evolution claimed to fix showing up again gets re-prioritized and
  flagged. Deletion is deliberately conservative — only claims proven
  wrong/stale or content duplicating CLAUDE.md. Absence of usage signal is
  **not** a deletion reason: metrics measure gaps, not usage, so a section
  that works produces no exploration — silence can mean success (the
  200-line budget still forces selection, not growth). The gate blocks at
  most once per threshold crossing when an evolution is **adopted**
  (adoption consumes the signal files, so the condition clears itself); a
  rejected rewrite keeps the signal files as evidence, and a **second
  consecutive rejection consumes them** (the evidence survives in the evolve
  backup) so retries are bounded instead of repeating forever. After a
  rejection — as when a session skips evolution (plan mode, read-only) — a per-session sentinel
  (`.cursor-context/.gate-fired-<session_id>`) still caps it at once **per
  session** so it doesn't re-fire on every subsequent turn — a fresh
  session gets one fresh block. The gate never blocks read-only sessions'
  work — it simply lets them end if writing is inappropriate.
- **Select (deterministic gate)** — before a new doc is adopted,
  `context-benchmark.sh` lints it: line budget, a minimum-content floor
  (`DOC_MIN_LINES` — a mutation that guts the doc can never be adopted),
  marker/fingerprint validity, every mentioned `npm run`/`make` command must
  actually exist, mentioned paths should exist. **FAIL = the old doc is
  restored from backup.** Honest scope note: the gate verifies form and the
  factual claims that can be checked against the repo — it cannot measure
  semantic usefulness. That judgment stays with the model doing the rewrite;
  the gate's job is bounding it (no regressions on verifiable properties, no
  degenerate outcomes), not scoring prose quality. The gate and the metrics
  collector are permanently excluded from evolution — a system that can
  rewrite its own scorer degenerates.

Code-layer improvement ideas discovered during evolution are only ever
*proposed* (appended to `.cursor-context/evolve-proposals.md`) — applying them is a
human decision. Evolution history lives in `.cursor-context/evolve-log.jsonl`.

### Uninstall

```bash
./install.sh /path/to/your/project --uninstall
```

This removes the toolkit's hooks and skills, and strips only this toolkit's
four hook entries and its `Bash(.claude/hooks/*)` permission rule out of
`.claude/settings.json` — any other hooks or allow entries you've
registered are left alone. Nothing is deleted outright:
everything removed is moved to `.claude/backup/uninstall-<timestamp>/` first,
so an uninstall is always reversible. `.cursor-context/` (the generated doc
and metrics data) is kept by default; add `--purge-data` to remove that too.

If `python3` is unavailable, hook entries can't be auto-removed from
`settings.json` — the command tells you which lines to delete by hand.

Manual removal (equivalent, if you'd rather not use the script):

```bash
rm .claude/hooks/session-context.sh .claude/hooks/prompt-freshness.sh \
   .claude/hooks/context-fingerprint.sh .claude/hooks/metrics-collector.sh \
   .claude/hooks/context-benchmark.sh .claude/hooks/evolve-gate.sh .claude/hooks/lib-config.sh
rm -rf .claude/skills/project-onboard .claude/skills/context-refresh .claude/skills/context-evolve
rm -rf .cursor-context
# then remove the four hook entries (session-context.sh / prompt-freshness.sh /
# metrics-collector.sh / evolve-gate.sh) from the hooks arrays in .claude/settings.json
```

### Troubleshooting

- **No snapshot appears in a new session** — check that the hook entries
  exist in `.claude/settings.json` (if the installer printed a merge warning,
  merge `settings.hooks-example.json` manually), that the scripts are
  executable, and that you started a *new* session (the SessionStart hook
  intentionally skips resume; freshness is still covered per-prompt).
- **"Fingerprint verification unavailable"** — no `sha256sum`/`shasum` on
  PATH, or the doc predates fingerprints. Harmless: the toolkit degrades to
  honest "can't verify" mode; the next doc refresh re-stamps the markers.
- **Doc looks wrong** — just say so; Claude fixes the affected part and
  re-stamps (micro-update rule). Or run `/project-onboard` to rebuild.
- **Too chatty / want it off temporarily** — remove the two hook entries from
  `settings.json`; files can stay in place.

## Platform support

| Platform | Status |
|---|---|
| Linux | ✅ Supported — verified end-to-end in live Claude Code sessions, and by CI |
| macOS | ✅ Supported — `shasum` fallback verified by CI on a macOS runner (`tests/fingerprint.bats`, `tests/hooks.bats`) |
| Windows (WSL) | ✅ Supported — identical to Linux |
| Windows (native) | ⚠️ Designed-compatible, not yet device-tested |

Native Windows: Claude Code requires Git for Windows, which ships every tool
this toolkit needs (bash, git, sha256sum, awk). Hook commands use a `bash -c`
wrapper so variable expansion works even when hooks are spawned via cmd. Run
`install.sh` from Git Bash. Reports welcome.

## Overhead (measured)

| Metric | Small project (4 files) | Large project (5,004 files) |
|---|---|---|
| Session-start hook | 146 ms | 183 ms |
| Per-prompt hook | 26 ms | 42 ms |
| PostToolUse hook (metrics) | ~14 ms/call | same order |
| Session token cost | ~600–800 tokens + doc (≤250 lines) | same order |
| Per-prompt token cost | **0 when nothing changed** | **0** |

Scaling is dominated by `git ls-files`, so even 50k-file monorepos stay well
under a second. The metrics hook's ~14 ms is dominated by `python3` process
startup, not I/O — at the 2,000-line rotation cap, reading the whole log adds
well under 1 ms. The full-log rotation check now runs on ~1% of calls
(probabilistic) instead of every call, which mainly reduces total I/O
operations over a long session rather than single-call latency at this scale;
rotation can lag by up to ~100 calls before it fires, never unbounded growth.

## Testing

```bash
shellcheck .claude/hooks/*.sh install.sh   # zero warnings, enforced in CI
bats tests/*.bats
```

- [`tests/fingerprint.bats`](tests/fingerprint.bats) — fingerprint generation
  and comparison: manifest edits/rollbacks, scratch-file invariance, CRLF
  marker normalization
- [`tests/install.bats`](tests/install.bats) — installer idempotency,
  settings.json merge/backup, python3-unavailable fallback, type-mismatch
  backup handling
- [`tests/hooks.bats`](tests/hooks.bats) — session snapshot structure,
  freshness-hook silence when unchanged, evolve-gate threshold + per-session
  sentinel behavior, metrics logging/rotation
- [`tests/benchmark.bats`](tests/benchmark.bats) — line-budget verdicts,
  FAIL on nonexistent npm/make targets, WARN (not FAIL) on nonexistent paths
- [`tests/MANUAL.md`](tests/MANUAL.md) — a checklist for what CI structurally
  cannot cover (the headless-onboarding E2E needs live API auth; hook
  injection behavior can only be observed in a real Claude Code session)

CI (`.github/workflows/ci.yml`) runs shellcheck and the full bats suite on an
ubuntu-latest/macos-latest matrix on every push and PR, and verifies that
`plugin/` is a byte-identical mirror of `.claude/` (real file copies, no
symlinks — symlinks break on native-Windows checkouts).

## Safety guarantees

- `CLAUDE.md` is treated as strictly user-owned: read, never written
- Auto-generated/refreshed files are left **uncommitted** for review
- All hooks exit 0 on every path — they can never block your prompt or
  other hooks
- Install is non-destructive (see above) and reversible

## License

[MIT](LICENSE)
