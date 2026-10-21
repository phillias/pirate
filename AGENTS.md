# Pirate Suite — Agent Notes

This directory is the live compose stack (see `README.md` for the tool
tables and architecture). This file consolidates agent-facing context:
the stack-management essentials and the byparr / Cloudflare-bypass
research, so any agent working here starts with the full picture.

The full ops runbook lives in the `pirate` skill
(`~/.agents/skills/pirate/SKILL.md`). Cross-stack patterns (BWS secret
overlay, Godoxy, socket-proxy, restic): the `docker` skill. Prowlarr
SQLite corruption: the `prowlarr-db-recovery` skill. This file is only
the summary; those skills are authoritative.

## 1. The CF-challenge lane (current byparr topology)

- Prowlarr and Jackett call a FlareSolverr v1 `/v1` HTTP API on port 8191.
- Three byparr instances run in the compose: `byparr` (bare),
  `warpbyparr` (behind the Cloudflare-Warp SOCKS5 proxy), and
  `protonbyparr` (behind the gluetun Proton VPN gateway). Profiles:
  `all` + `proxy`.
- Proxy bases (`proton`, `warp`) must be healthy before their `*byparr`
  variants start (`depends_on: service_healthy`). The variants reach their
  proxy through the `PROXY_SERVER` env var over the shared `pirate_default`
  network (`http://warp:1080` / `http://proton:8888`) — they are NOT attached
  via `network_mode: service:<base>`.
- Internal port is 8191; the upstream README's 8193 is drift.

## 2. Stack management essentials

- Compose profiles: `all`, `stremio`, `arrs`, `proxy`, `books`.
- Secrets: all stack secrets live in the phillias BWS project (keyed
  `PIRATE_<ENVVAR>`, bare prefix — no per-server suffix). `setup.sh`
  fetches them at render time, overlays onto any `.env` values (vault
  wins), then renders all config files via `envsubst` from
  `templates/`. The old locket/bws-init path (`shelfmark-init`) is
  removed. Warp registration state lives in the gitignored `./warp`
  bind mount.
- Startup order: run `./setup.sh` first (renders all configs from BWS);
  then selfhost MariaDB before grimmory (cross-stack, see §7);
  `proton`/`warp` before their chain variants.
- Backups: `db-backup.sh` (SQLite hot copy), `restic-backup.sh` (03:00
  cron; app dirs + volume exports; retention 7d/4w/12m), and
  `restore.sh -a <app> -t <window>` (dry-run with `-n` first).
- Never: in-place SQLite repair on prowlarr (restore instead), `cp` on a
  live SQLite DB, starting variants before proxy bases, DATABASE_PASSWORD
  in `compose.yaml` instead of `.env`, HikariCP tuning via env on
  grimmory, the non-DB `/api/v1/healthcheck` as a grimmory healthcheck
  (use `/actuator/health` — it aggregates the `db` indicator and returns
  503 when MariaDB is down), committing secret values to the repo
  (secrets belong in BWS phillias project with PIRATE_ prefix).

## 3. Byparr research log

### Current engine (verified 2026-08-02)

- byparr = ThePhaseless/Byparr, a FlareSolverr-fork FastAPI service.
- The browser layer is engine-agnostic: all engine code lives in
  `src/utils.py get_browser()` (~57 LoC), and the project has swapped
  engines twice (camoufox → cloverlabs-camoufox → invisible_playwright).
- Current engine: invisible_playwright (feder-cr) — C++-patched Firefox,
  wrapper MIT, binary MPL-2.0, public patches at
  feder-cr/firefox_antidetect_patch. NOT camoufox since commit 4800ef7f
  (2026-07-04).

### Decision 2026-08-02: keep byparr; no browser forks

Six alternatives were evaluated (shim, engine swap, Camoufox fork,
FlareSolverr fork, reinventing stealth patches, headless Chromium).
Verdict: keep byparr. The real pain was operational (500s, unhealthy
container), not the engine, and any self-maintained patch fork is a
permanent rebase treadmill.

### Hard constraints learned

- CloakBrowser (CloakHQ): patched Chromium; wrapper MIT but the compiled
  binary is proprietary (no fork/reinvent path, maintainers declined to
  open the patches). No `/v1` API (CDP-only on :9222); latest builds
  Pro-gated. It can only be rented, not owned.
- Chrome moves to a 2-week release cycle (from 2026-09-08), so
  self-maintained Chromium stealth patches are a permanent treadmill.
- The open C++-patched stealth lane is Firefox (camoufox,
  invisible_playwright) — both carry public patches.
- No light stealth headless Chromium exists: the old light headless was
  detectable and removed (Chrome 112+); new headless is full weight. RAM
  is controlled with concurrency caps and idle timeouts, not headless
  mode.

### Chromium stealth landscape, ranked (2026-08-02)

1. Patchright — Apache-2.0, active; best self-owned Chromium option.
2. SeleniumBase UC mode — MIT, active; needs headed Chromium + xvfb on
   Linux (headless is detectable).
3. undetected-chromedriver — GPL-3.0, alive; what FlareSolverr uses;
   fragile browser-version matching.
4. rebrowser-patches — MIT but stale since May 2025; avoid.

### External alternatives surveyed (2026-09)

- trawl (germondai/trawl): camoufox-based, FlareSolverr-`/v1`-compatible,
  4-tier escalation (plain HTTP → cached browser session → fresh
  challenge solve → residential proxy) plus a challenge-aware MITM
  forward proxy.
- Solvearr (nabil-ak/Solvearr): TLS-fingerprint tampering with no
  browser; lighter, but the no-browser lane is unproven against managed
  challenges.

### Operational lessons (from this stack's incidents)

- byparr 500s in Prowlarr (`http://byparr:8191/v1`) were operational,
  not engine-related: classify each 500 (crash vs CF-timeout vs
  fingerprint-reject vs cookie-replay vs indexer-down) before touching
  engines.
- The bare `byparr` container ran unhealthy for two weeks because
  compose had no healthcheck — build healthchecks in from day one.
- The Prowlarr#2561 cookie-replay bug is engine-independent: fix via the
  byparr-proxy body-passthrough pattern (guyg2232, ~70 LoC) or Prowlarr
  PR #2600.
- Engine-swap LoE, if ever needed: 1.5–2.5 person-days —
  `src/utils.py get_browser()`, `pyproject.toml` + `uv.lock`, and the
  Dockerfile install steps. Gotchas: `humanize=True` semantics differ
  between engines; `networkidle` timing differs Xvfb-Firefox vs
  headless-Chromium; playwright-captcha `wait_checkbox_attempts=1` was
  tuned on the old engine.

## 4. Moli assessment (2026-09-09): not a bypass engine

lexmount/moli is a Rust headless browser with its own kernel (libcurl
transport, V8, Servo/Stylo CSS, html5ever) — explicitly not a Chromium
wrapper, and it does not pursue Chrome parity. That disqualifies it for
the challenge-bypass core:

- Anti-bot passing is a fingerprint game. Moli's TLS handshake (libcurl)
  and DOM surface match no real browser, and it ships no stealth
  patches, so a managed challenge rejects it on sight.
- Its own crawl benchmark counts challenge pages as failures (53.6%
  success across 192 URLs); Cloudflare pass-through is out of scope by
  design.
- It exposes CDP/WebDriver and a `serve` mode, but no FlareSolverr
  `/v1` API. `moli-web-bot-auth` (signed bot identity) only helps where
  sites honor Web Bot Auth — irrelevant to Cloudflare managed
  challenges.

Where moli could still fit a future design:

- A cheap tier-1/tier-2 fetch lane for unprotected indexers: 73 MiB RSS,
  1.43 s median, ~15% of Chrome's CPU — non-challenge scraping only.
- An architecture reference for on-demand rendering and bounded memory
  in a long-running browser service.

## 5. Design implications for a future byparr-type tool

- Speak FlareSolverr `/v1` for drop-in Prowlarr/Jackett compatibility.
- The challenge tier must be a real browser with public anti-detect
  patches: the Firefox lane (invisible_playwright/camoufox) or the
  Chromium lane (Patchright). Never a custom or lightweight engine
  (moli, raw libcurl stacks) in that tier.
- Keep the engine behind one ~60-LoC seam (byparr's `get_browser()`
  shape) so engines stay swappable.
- Design operations in from day one: a real healthcheck, per-failure
  logs/HAR, and a failure taxonomy (crash / CF-timeout /
  fingerprint-reject / replay / upstream-down).
- Solve cookie portability at the transport layer (trawl's MITM-proxy
  pattern) rather than hoping cookies replay through the caller's own
  HTTP client (the Prowlarr#2561 class of bugs).
- Tiering beats brute force: plain HTTP → reused browser session →
  fresh challenge solve → optional residential proxy.

## 6. Durable memory pointers

Full bodies via `mem show <id>` (axi-memory):

- `d-2026-08-02-keep-byparr-invisible-playwright-as-pira` — keep-byparr
  decision (six alternatives evaluated)
- `f-2026-08-02-pirate-stack-byparr-500s-unhealthy-bare-` — 500s and
  unhealthy-container incident
- `h-2026-08-02-chromium-stealth-landscape-2026-options-` — stealth
  options ranked
- `h-2026-08-02-swap-byparr-engine-to-cloakbrowser-invis` — engine-swap
  recipe and gotchas
- `c-2026-08-02-cloakbrowser-patches-are-proprietary-can` — CloakBrowser
  proprietary constraint
- `f-2026-08-26-aiostreams-builtin-prowlarr-indexers-for` — AIOStreams
  preset `indexers` format regression

## 7. grimmory database dependency

grimmory ships no database of its own — it uses the MariaDB provided by
the host. `DATABASE_URL` reaches it via `extra_hosts:
host.docker.internal:host-gateway` (see `compose.yaml`). The host database
must be reachable before grimmory starts; until it is, grimmory
crash-loops. Its healthcheck (`/actuator/health`) reflects database
state.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
