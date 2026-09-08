# bensheldon/good_job context
> refreshed 2026-09-08 | upstream default: main @ 2d8ebb19120296a823c41a43b2945a09df719a7b

## Identity & policies
- upstream: bensheldon/good_job, default branch `main`, primary language Ruby (Rails gem), English-first (yes — all docs/README in English).
- CLA/DCO: none (CONTRIBUTING.md has no CLA/DCO/signup requirement).
- AI-assisted PR policy: unstated (no AI disclosure requirement found).
- signed commits required: no.
- PR template: none (no `.github/PULL_REQUEST_TEMPLATE.md` or repo-root template) — use pipeline fallback body.
- external tracker: github (Prioritized Project Backlog at github.com/bensheldon/good_job/projects/1).

## Conventions (verified from merged PRs)
- branch naming: kebab-case descriptive, no strong `type/` prefix (e.g. `probe-handler-raise`, `config-valid`, `fix-adapter-class-pool-memoization`). Use `<kebab-description>`.
- commit style: imperative, conventional-ish (e.g. "Add ...", "Fix ...", "Deprecate ...").
- test command: `bundle exec rspec` (spec/ suite); lint: `bundle exec rubocop`.
- CI: GitHub Actions matrix (Ruby + PG). Outside PRs merge regularly (13 external merges in 60d).

## Maintainer picture
- Primary maintainer: bensheldon (Ben Sheldon). Active, responsive; merges external PRs frequently.
- Areas in flight: cluster mode (#1801/#1803), fiber execution (#1811), dashboard query optimization (#1800), queue-scoped index (#1810).

## Issue-area health
- Active, well-maintained. No contested/redesign signals in docs area.

## Gap ledger (dedupe — READ FIRST, never re-pick)
- `2026-08-05` test-coverage (Configuration#max_threads) — pr-opened-green — fork PR #1.
- `2026-08-26` test-coverage (Configuration#max_threads) — pr-opened — fork PR #2 (audit-gate updated).

## Mined gaps (discovered, not yet attempted)
- `2026-09-08` trivial/minor-fix pass (typos, dead links, stale commands, wrong doc lines) — pr-opened — fork PR #4 (8 verified doc fixes in README.md + KUDOS.md across 2 commits: execeution→execution, probe_server_app→probe_app, enequeued→enqueued, stray `]` in mermaid labels, Performance→Pauses page, dead KUDOS Twitter link, TOC anchor case, duplicated 'can no longer can' word; 2 files). Fork CI: Lint + Tests for Development and Demo + rails_head + JRuby green; older-Rails matrix (6.1/7.0/7.1) red due to pre-existing environmental `unknown keyword: quirks_mode` (json gem 2.8.0) — unrelated to docs-only diff.
