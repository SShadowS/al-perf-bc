# Canary Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the cu1924 canary + auto-ship path toward the umbrella spec's "default SaaS mode" posture: fleet-safe scheduling (jitter — BC Job Queues fire clock-aligned, a fleet ships in top-of-the-hour bursts), durable retry of failed ships, and operator visibility via telemetry breadcrumbs.

**Scope exclusions (user decisions, NOT this plan):** app split (Cloud vs OnPrem companion), PTE/AppSource distribution, ID-range/HttpClient-allowlist onboarding. The plan hardens what exists in this app.

**Architecture:** Three additive changes to existing objects: a configurable random start-delay in the canary Job Queue path; a retry sweep in `ShipPending` that re-ships FAILED ship-log entries with an attempt cap; `Session.LogMessage` breadcrumbs (custom event ids) at canary start/ship success/ship failure so fleet operators see canary health in their own App Insights.

**Tech Stack:** AL (BC 26+), existing objects: `AlPerfCanary.Codeunit.al`, `AlPerfAutoShip.Codeunit.al` (`ShipPending`/`ShipOne`/`ShipProfile`), `AlPerfShipLog.Table.al` (Status enum, Error Message, HTTP Status), `AlPerfShipSetup.Table.al` (Canary group exists; "Canary Workload Codeunit ID" field 90 already present).

## Global Constraints

- Match the app's existing AL style exactly (object/field naming, XML doc comments, TryFunction error discipline — read the neighboring code first).
- Every commit message ends with:
  `Claude-Session: https://claude.ai/code/session_016iRfkowCE7Zb2FcN52rnPp`
- **Verification bar:** no automated AL test infra exists in this repo. Each task verifies by (a) `alc` compile if a compiler + symbols are available on the machine (check `ls .alpackages` / VS Code AL extension cache; report which), else (b) a line-by-line self-review against AL syntax + a compile-blocking checklist in the report. State plainly which bar was met.
- Additive only: no field renumbering, no breaking changes to existing procedures' signatures (extend via new optional parameters ONLY if AL overloading forces it — prefer new procedures).
- New setup fields continue the existing numbering (next free: 110+) and get sensible defaults so existing installs upgrade without configuration.
- Telemetry breadcrumbs: `Session.LogMessage` with custom event ids `ALP0001` (canary run start), `ALP0002` (ship success), `ALP0003` (ship failure) — Verbosity::Normal, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher; dimensions carry activity id, http status, attempt count — NEVER the bearer token or server URL credentials.

## Design Decisions (locked)

- **D1 — Jitter:** new setup field `"Canary Jitter (max minutes)"; Integer` (field 110, default 10, 0 = disabled). At canary Job Queue entry (the `OnRun`/`TableNo = "Job Queue Entry"` path ONLY — `RunNow()` stays immediate), sleep `Random(JitterMinutes * 60) * 1000` ms via `Sleep()` before capturing. Job Queue sessions are background — a bounded sleep is the standard fleet-desynchronization trick; cap the field at 55 (validation) so hourly schedules can't overlap themselves.
- **D2 — Retry sweep:** ship-log rows whose Status is the failure value gain re-shipping: new field `"Attempts"; Integer` on the ship log (next free number), incremented per try. `ShipPending` first sweeps FAILED rows with `Attempts < 5` and re-ships them (existing `ShipProfile` path; profile blob must still be available — if the Performance Profiles record is gone, mark the row permanently failed with a distinct error text), THEN processes new pending profiles as today. No exponential backoff timer inside AL — the Job Queue cadence IS the backoff (document it); the attempt cap prevents eternal churn.
- **D3 — Breadcrumbs** as in Global Constraints; failure breadcrumb fires in the same error path that writes "Last Error"/ship-log failure — one breadcrumb per attempt, dimensions include attempt number.
- **D4 — Docs:** README/setup-card tooltips updated for the two new fields; a short "fleet scheduling guidance" doc section (off-peak, jitter rationale, retry semantics, what the ALP000x events mean and a KQL snippet to chart canary health).

---

### Task 1: Jitter + telemetry breadcrumbs

**Files:**
- Modify: `src/AlPerfShipSetup.Table.al` (field 110 + validation ≤55), `src/AlPerfShipSetupCard.Page.al` (canary group control + tooltip)
- Modify: `src/AlPerfCanary.Codeunit.al` (jitter in the Job Queue path; ALP0001 breadcrumb with activity/description dimensions)
- Modify: `src/AlPerfAutoShip.Codeunit.al` (ALP0002/ALP0003 at ship outcome sites)

- [ ] Implement per D1/D3 (read the existing canary OnRun structure first; jitter BEFORE the in-progress-recording guard? NO — after the guard, before Start, so a guarded early-exit never sleeps pointlessly).
- [ ] Verify per the verification bar; state which. Commit — `feat(canary): scheduling jitter and telemetry breadcrumbs`

### Task 2: Failed-ship retry sweep + docs

**Files:**
- Modify: `src/AlPerfShipLog.Table.al` (Attempts field), `src/AlPerfShipLogList.Page.al` (Attempts column; existing manual retry action — check for one, add "Retry Now" action if absent, resetting nothing but invoking the same re-ship path)
- Modify: `src/AlPerfAutoShip.Codeunit.al` (retry sweep in ShipPending per D2; Attempts increment inside ShipOne/ShipProfile so manual + sweep + first tries all count)
- Modify: `README.md` or the existing docs file (D4 section incl. ALP000x KQL snippet)

- [ ] Implement per D2/D4. Key edge: profile blob unavailable on retry → permanent failure with distinct message, no attempt burn-loop.
- [ ] Verify per the bar. Commit — `feat(ship): failed-ship retry sweep with attempt cap`

---

## Self-Review Notes
- Spec §canary hardening coverage: jitter ✅ (D1, spec names the clock-alignment burst), retry ✅ (D2, Job-Queue-cadence backoff documented), operator visibility ✅ (D3 breadcrumbs — an ISV sees canary health in the same App Insights al-perf pulls from). Distribution decisions explicitly excluded.
- Both tasks additive; existing installs upgrade with defaults (jitter 10, attempts 0).
- Breadcrumb dimensions audited for secrets (token/URL excluded by constraint).
