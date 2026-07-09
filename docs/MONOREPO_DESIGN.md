# Monorepo support — design review (not implemented)

Status: design review only, per `IMPROVEMENT_PLAN.md` 3-4. This document
captures the design direction so it can be split into its own implementation
plan later. Nothing described here has been built; the toolkit today assumes
a single repo root and that assumption is unchanged by this document.

## Problem

Fingerprinting and the generated doc are both scoped to the repository root.
In a large monorepo (many independently-versioned packages under one repo),
that has two failure modes:

- **Budget starvation.** `DOC_LINE_BUDGET` (default 200) has to describe every
  package's stack, commands, and conventions in one document. Past a handful
  of packages, either the budget is blown or each package gets only a
  sentence — not enough to be useful the way a single-package doc is today.
- **False-positive staleness.** The root directory-layout fingerprint changes
  when *any* package changes. A change to `packages/analytics` invalidates the
  fingerprint for a session working only in `packages/web`, triggering
  refreshes and freshness warnings that have nothing to do with the code the
  session is actually touching.

## Proposed direction

Two-tier docs, matching how the plan describes it:

- **Root doc** (`.cursor-context/project-context.md`, unchanged path) —
  monorepo-wide: workspace tool (npm/yarn/pnpm workspaces, Turborepo, Nx,
  Lerna...), package list, shared tooling/CI, cross-package conventions.
  Always injected at session start, same as today.
- **Per-package docs** (`<pkg>/.cursor-context/project-context.md`) — same
  format as today's single-repo doc, scoped to that package: its own stack,
  commands, structure, gotchas. Same 200-line budget applies per package,
  since each is independently sized like a standalone project.

### Package-doc selection at session start

Injecting every package doc defeats the purpose (budget blowout again), so
`session-context.sh` needs a selection heuristic instead of "inject
everything." Candidate signal, reusing data the hook already computes:

1. The **branch-intent diff** (`diff --stat` vs. default branch) already
   computed for the root snapshot — the packages it touches are the packages
   most likely relevant to "continue" / "finish this" style prompts.
2. Recent commits' changed paths, as a fallback when the branch diff is empty
   (freshly branched, or working on `main` directly).
3. If neither yields a package (e.g., a brand-new checkout with no diff yet),
   inject nothing extra and let the per-prompt fingerprint hook or an explicit
   `/project-onboard <path>` fill in the gap on demand — consistent with the
   toolkit's existing "silent until relevant" bias.

This keeps injection bounded regardless of package count: root doc + at most
a small number of touched-package docs, never the whole workspace.

### Fingerprint generator scoping

`context-fingerprint.sh` currently fingerprints the whole working tree. It
would need a scope argument, e.g. `context-fingerprint.sh --scope packages/web`,
so:

- The root doc's fingerprint covers workspace-level files only (root
  manifests, workspace config, CI) — not every package's internals, or any
  single package's change invalidates the root doc too, reintroducing the
  false-positive problem this design is meant to fix.
- Each package doc's fingerprint covers that package's own directory only
  (manifest, lockfile if package-scoped, source layout under that path).

This is an additive change to the existing script (a new optional flag with
today's whole-tree behavior as the default when omitted), not a rewrite —
today's single-repo fingerprinting is a special case of "scope = repo root."

### Config and detection

- A monorepo needs to be detected (workspace field in root `package.json`,
  `pnpm-workspace.yaml`, `lerna.json`, `nx.json`, `turbo.json`, Cargo/Go
  workspace equivalents) before any of the above kicks in — single-repo
  projects must see zero behavior change.
- Likely a new config key, e.g. `MONOREPO_PACKAGES` (glob list) or
  auto-derived from the detected workspace tool, plus reuse of the existing
  `DOC_LINE_BUDGET` per package rather than a new budget key.

## Non-goals for this document

- No code changes. `context-fingerprint.sh`, `session-context.sh`,
  `context-benchmark.sh`, and the skills are untouched by this review.
- No decision yet on exact selection-heuristic thresholds (how many packages
  to inject, how "recent" a commit counts) — that belongs in the follow-up
  implementation plan, backed by testing against a real monorepo fixture.
- No decision on whether `context-evolve`'s measure/reflect/evolve loop runs
  per-package or stays root-only; per-package evolution likely wants its own
  metrics/feedback files scoped under `<pkg>/.cursor-context/`, mirroring the
  doc split, but this needs its own design pass.

## Suggested next step

Split this into its own plan once there's a concrete monorepo fixture to test
against (real package count, workspace tool, and directory depth matter more
than they do for the single-repo case). The riskiest part is the selection
heuristic in `session-context.sh` — that's the piece most likely to need
iteration against real usage rather than getting right on the first design.
