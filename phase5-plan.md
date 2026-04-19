# Phase 5 — Deployment

Rough outline. Task-level breakdown will be filled in when Phase 5 starts.

**Goal**: Server runs in production with TLS, secrets, rate limits, and monitoring. iOS app is in TestFlight, then the App Store.

## Deliverables

### 1. Server deployment
- `Dockerfile` for the FastAPI app (multi-stage, slim base).
- Platform: Fly.io / Railway / Render (pick at phase start based on ops preference).
- Automatic TLS (all platforms provide this).
- Secrets via platform secret manager: `ASSEMBLYAI_API_KEY`, `ANTHROPIC_API_KEY`. Never in git, never in logs.
- Deploy from GitHub main via platform's CD.
- Health check endpoint wired to platform's uptime monitoring.

### 2. Rate limiting & abuse prevention
- Per-IP rate limit on `/token` (e.g. 10 req/min) — prevents a leaked server from becoming a free AssemblyAI bridge for strangers.
- Per-IP rate limit on `/correct` (e.g. 120 req/min) — aligns with realistic dictation cadence.
- Max-session-duration cap passed to AssemblyAI's `/v3/token` (`max_session_duration_seconds`) to hard-limit runaway sessions server-side.
- Optional: a simple shared secret the iOS app sends on every request (bundled in the app but offers a weak speed bump vs anonymous abuse).

### 3. Observability in prod
- Log shipping: structured JSON → Axiom / Logtail / similar.
- Error tracking: Sentry (or platform-native equivalent) on the server.
- Dashboards: requests/min, error rate, p50/p95/p99 latency on `/correct`, daily $ spend on AssemblyAI + Anthropic.
- Alerting: spend > threshold, error rate > threshold, p99 latency spike.

### 4. iOS release prep
- App icon + splash screen.
- Build config: separate simulator dev (`127.0.0.1:8000`), device dev (LAN IP or tunnel), and prod (`voxscribe-api.fly.dev` or whichever) server URLs.
- Remove localhost ATS exception in release builds.
- Privacy manifest (required by App Store for audio-capturing apps): declare `NSMicrophoneUsageDescription`, data collection disclosures (we collect: audio streamed to AssemblyAI, transcripts sent to our server for correction).
- Privacy policy (required by App Store): hosted page explaining data flow.
- TestFlight build for internal testing.
- App Store submission: screenshots, description, support URL.

### 5. Billing hygiene & safety rails
- iOS: auto-disconnect after 30 min of no speech (prevents accidental forever-sessions).
- iOS: show a running session timer so user knows they're live.
- Server: enforce per-IP daily quota (soft cap, returns 429 past the limit).
- Dev alert if per-user spend > $X/day (early warning on abuse).

## Guiding principles (Phase 5 specifics)

- **Ship the simplest thing that's safe.** No user accounts, no user DB, no auth for v1 release. A rate-limited anonymous API + a local-storage iOS app is a complete product.
- **Observability from day one of prod.** Logs, metrics, alerts exist before the first external user, not after the first incident.
- **Secrets are never in the repo or binary.** Every platform supports secret injection; use it.
- **Defense in depth on cost.** Client-side limits + server-side limits + AssemblyAI-side session caps. One of them will fail; the others must hold.

## Success criteria

- Server deployed, TLS working, health check green.
- End-to-end production session from a TestFlight build succeeds: partials <150 ms, corrections land, Terminate sent on Stop.
- A contrived attack on `/token` (rapid polling from one IP) is rate-limited and logged.
- Cost dashboard shows real numbers after a week of dogfooding.
- App Store submission accepted (or rejection feedback addressed).

## Out of scope

- User accounts, multi-device sync, subscriptions — none required for v1 public release.
- Server horizontal scaling — single instance is fine at launch; we'll scale when load demands.
- Translations / localization (English-only ship).

## Open questions / risks

- **Leaked server being used by random apps**: the strongest mitigation is app-level auth, which we're deferring. Accept the risk for launch; revisit if abuse materializes.
- **App Store review of audio apps**: privacy-disclosure requirements are strict. Build the privacy page early and get the manifest right on the first submission.
- **Choosing a host**: Fly.io is WebSocket-friendly (relevant if we ever proxy audio), Railway is simplest, Render is middle-ground. Decide when Phase 5 starts based on current state and any Phase 4 learnings.
- **Free tier costs**: a single abusive user could burn a day's budget in an hour. The daily quota + TestFlight soft-launch mitigate this.
