# cursor-context

**Cursor-grade automatic project context awareness for Claude Code** — zero-touch, real-time, and honest about what it knows.

> 한국어 문서: [README.ko.md](README.ko.md) · Status: **Beta** · License: MIT

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
2. **After your first real task** — Claude silently generates
   `.cursor-context/project-context.md` (commands verified by running them,
   architecture, conventions, gotchas — under 200 lines). No approval asked;
   the file is left uncommitted for you to review. Skipped for read-only or
   unrelated sessions.
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

`install.sh <target>` copies five hook scripts and three skills into the
target's `.claude/` directory and registers the hooks. It is **non-destructive
and idempotent**:

- An existing `settings.json` is never overwritten. Hook entries are
  **appended** to its `hooks` arrays via python3 (all your keys and hooks are
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
`chmod +x .claude/hooks/*.sh`, and merge the `hooks` block of
`settings.json` into yours (append to the arrays — additive, existing hooks
keep working).

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

### Manual commands (optional — automation covers these)

- `/project-onboard` — force a full regeneration of the project doc
  (deep parallel exploration; use after major restructuring)
- `/context-refresh` — force an incremental update (diff-driven; only
  affected sections are rewritten)

### Freshness model (why you can trust what's injected)

Staleness is judged by **content, not commit counts**. The doc stores sha256
fingerprints of structural files plus a directory-layout hash; hooks recompute
them against the working tree at session start and on every prompt. Practical
consequences, all verified by tests:

- Uncommitted manifest edits are caught immediately
- Rebases, squash merges, hard resets, branch switches — all detected;
  rolling back to the documented state makes the fingerprint match again,
  so no wasted refresh
- Scratch files and notes do **not** trigger false "structure changed" alarms
  (only directories and structural files are fingerprinted)
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
- **Reflect (near-zero cost)** — every session carries a standing rule: if the
  doc was wrong or missing something that required real exploration, append
  one JSON line to `.cursor-context/context-feedback.jsonl` after finishing the task.
- **Evolve (gated)** — once enough signal accumulates (5 feedback entries or
  300 metric lines), Claude runs `/context-evolve` after your request:
  fix what was wrong, add what was repeatedly explored, **delete sections no
  session ever used** (the 200-line budget forces selection, not growth).
- **Select (deterministic gate)** — before a new doc is adopted,
  `context-benchmark.sh` lints it: line budget, marker/fingerprint validity,
  every mentioned `npm run`/`make` command must actually exist, mentioned
  paths should exist. **FAIL = the old doc is restored from backup.** The
  gate and the metrics collector are permanently excluded from evolution —
  a system that can rewrite its own scorer degenerates.

Code-layer improvement ideas discovered during evolution are only ever
*proposed* (appended to `.cursor-context/evolve-proposals.md`) — applying them is a
human decision. Evolution history lives in `.cursor-context/evolve-log.jsonl`.

### Uninstall

```bash
rm .claude/hooks/session-context.sh .claude/hooks/prompt-freshness.sh \
   .claude/hooks/context-fingerprint.sh .claude/hooks/metrics-collector.sh \
   .claude/hooks/context-benchmark.sh
rm -rf .claude/skills/project-onboard .claude/skills/context-refresh .claude/skills/context-evolve
rm -rf .cursor-context
# then remove the three hook entries (session-context.sh / prompt-freshness.sh /
# metrics-collector.sh) from the hooks arrays in .claude/settings.json
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
| Linux | ✅ Supported — verified end-to-end in live Claude Code sessions |
| macOS | ✅ Supported — `shasum` fallback (code path verified) |
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
| Session token cost | ~600–800 tokens + doc (≤250 lines) | same order |
| Per-prompt token cost | **0 when nothing changed** | **0** |

Scaling is dominated by `git ls-files`, so even 50k-file monorepos stay well
under a second.

## Safety guarantees

- `CLAUDE.md` is treated as strictly user-owned: read, never written
- Auto-generated/refreshed files are left **uncommitted** for review
- All hooks exit 0 on every path — they can never block your prompt or
  other hooks
- Install is non-destructive (see above) and reversible

## License

[MIT](LICENSE)
