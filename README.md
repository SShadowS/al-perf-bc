# al-perf-bc

[![Business Central](https://img.shields.io/badge/Business_Central-27.0+-0078D4?logo=dynamics365)](https://learn.microsoft.com/en-us/dynamics365/business-central/)
[![AL](https://img.shields.io/badge/AL-Extension-blue)](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-dev-overview)
[![Runtime](https://img.shields.io/badge/runtime-15.0-green)](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-choosing-runtime)

> Business Central extension that adds AI-powered performance analysis directly into the Performance Profiler page.

One-click analysis — record a profile, hit **Analyze with AL Perf**, get results inline.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [Requirements](#requirements)
- [Related](#related)
- [License](#license)

## How It Works

This extension adds two actions to the **Performance Profiler** page:

| Action | Description |
|--------|-------------|
| **Analyze with AL Perf** | Sends the recorded profile to the [AL Perf Analyzer](https://github.com/SShadowS/al-perf) service, returns hotspots, anti-pattern detection, and AI-powered insights rendered as HTML directly in the page. |
| **View in Browser** | Opens the full AL Perf Analyzer web app at [alperf.sshadows.dk](https://alperf.sshadows.dk). |

The extension:

1. Reads the profile data from BC's `Sampling Performance Profiler` codeunit
2. Builds a multipart/form-data request with the `.alcpuprofile` payload
3. POSTs it to the analyzer service (`/api/analyze?format=html`)
4. Renders the HTML response in a `WebPageViewer` control below the profiler

No data is stored server-side — the profile is analyzed and discarded.

## Installation

### From `.app` file

1. Download the latest `.app` from [Releases](https://github.com/SShadowS/al-perf-bc/releases)
2. Upload via **Extension Management** in Business Central
3. The action appears automatically on the **Performance Profiler** page

### From source

```bash
git clone https://github.com/SShadowS/al-perf-bc.git
```

Open in VS Code with the [AL Language extension](https://marketplace.visualstudio.com/items?itemName=ms-dynamics-smb.al), configure `launch.json` for your BC environment, and publish.

## Usage

1. Open **Performance Profiler** in Business Central
2. Record a profiling session as usual
3. Stop the recording
4. Click **Analyze with AL Perf** in the action bar
5. Wait ~10-30 seconds (AI explanation adds time)
6. Results appear inline below the profiler data

## Configuration

The extension connects to the analyzer service at `https://alperf.sshadows.dk` by default. This is set in `src/AlPerfAnalyzer.Codeunit.al` via the `ApiBaseUrl` label.

To point at a self-hosted instance (e.g. via [Docker](https://github.com/SShadowS/al-perf#docker)):

```al
ApiBaseUrl: Label 'https://your-host.example.com', Locked = true;
```

## Requirements

- Business Central **27.0+** (platform and application)
- AL runtime **15.0**
- Target: **Cloud** (SaaS compatible)
- Network access to the analyzer service endpoint

## Object Range

| Type | ID | Name |
|------|----|------|
| Codeunit | 70500 | Al Perf Analyzer |
| Page Extension | 70500 | Perf Profiler AL Perf Ext |

## Related

- [al-perf](https://github.com/SShadowS/al-perf) — The analyzer CLI, MCP server, web app, and library
- [alperf.sshadows.dk](https://alperf.sshadows.dk) — Hosted web app

## POC Continuous Monitoring (auto-ship)

Open `AL Perf Ship Setup Card` page → set Tenant Code, Server URL Base, and the Bearer Secret (write-only). Click Register Tenant. Toggle Enabled.

Wire a Job Queue Entry to Codeunit 70503 `AL Perf Auto Ship` to run every 5 min.

Decrypt + view: `AL Perf Ship Log List` page → Open Profile. Failed rows can be retried
individually from that page (**Retry Now**), or wait for the automatic sweep described
below.

See [docs/superpowers/specs/2026-04-13-poc-scope.md](https://github.com/SShadowS/al-perf/blob/master/docs/superpowers/specs/2026-04-13-poc-scope.md) in the al-perf repo for scope, limits, and roadmap.

### Fleet Scheduling & Canary Health

The self-profiling canary (`AL Perf Canary` codeunit, `Canary` group on the setup card)
is designed to run unattended across a fleet of tenants on a shared Job Queue cadence
(e.g. hourly). Two things harden that for fleet-scale, unattended operation:

**Scheduling jitter.** BC Job Queues fire clock-aligned — a fleet scheduled "every hour
on the hour" all wakes up in the same few seconds, and all canaries would hit the al-perf
ingest endpoint in one burst. `"Canary Jitter (max minutes)"` (setup card, Canary group,
default 10, 0 disables it, capped at 55) makes the scheduled (Job Queue) canary run sleep
a random duration up to that many minutes before it starts profiling, spreading the fleet
out instead of bursting. It only applies to the Job Queue path — **Run Canary Now** always
runs immediately.

Pick jitter for **off-peak** windows: schedule the canary Job Queue entry outside your
tenants' business hours where possible, and use jitter to smooth out whatever burst
remains rather than as a substitute for off-peak scheduling.

> **Job Queue timeout headroom.** A scheduled canary run can burn up to the full jitter
> window in `Sleep()` *before* it captures anything — with the default 10 min that's
> usually negligible, but if jitter is turned up toward its 55-minute cap, budget for it.
> The Job Queue entry's execution timeout needs headroom for **jitter + workload run time
> + ship time**, not just the workload and ship. If the timeout doesn't budget for the
> sleep, a long jitter roll can get the run killed by the Job Queue watchdog before it
> ever starts profiling.

**Retry semantics.** Every ship attempt (first try, automatic retry, or manual **Retry
Now**) goes through the same transport (`AL Perf Auto Ship.ShipProfile`) and increments
`Attempts` on the `AL Perf Ship Log` row. Each `ShipPending` run (i.e. each Job Queue
tick of `AL Perf Auto Ship`) first sweeps all `Failed` rows with `Attempts < 5` and
re-ships them, *then* processes newly-pending profiles as before — so a backlog of
failures catches up over the next few scheduled runs instead of only being retried while
it's still inside the current run's lookback window.

There is no timer-based backoff inside AL — the Job Queue's own run cadence *is* the
backoff. A 5-minute cadence retries a failure roughly every 5 minutes (bounded by the
5-attempt cap); a coarser cadence backs off further for free. If a row's source
`Performance Profiles` record is gone by retry time — deleted (e.g. profiler data
retention cleanup) or, for canary rows, never persisted at all since a canary ships an
in-memory profile that only exists for the duration of its own session — there is nothing
left to re-ship. That row is marked permanently failed with a distinct error message and
`Attempts` is pinned at the cap so the sweep stops re-examining it, rather than retrying
(and re-failing) it forever. **Retry Now** re-ships a single `Failed` row on demand and is
not subject to the cap.

**Telemetry breadcrumbs.** `AL Perf Canary` and `AL Perf Auto Ship` emit
`Session.LogMessage` events so fleet operators can see canary health in their own App
Insights, without token or server URL credentials ever appearing in the dimensions:

| Event ID | Meaning | Fired from |
|----------|---------|------------|
| `ALP0001` | Scheduled canary run started (Job Queue path only; `Run Canary Now` is silent) | `AL Perf Canary` |
| `ALP0002` | Profile shipped successfully | `AL Perf Auto Ship` |
| `ALP0003` | Ship attempt failed — dimensions include `Attempts`, the attempt number for that row | `AL Perf Auto Ship` |

All three carry `ActivityId` and `ActivityDescription`; `ALP0002`/`ALP0003` also carry
`HttpStatus` when the server responded. Verbosity `Normal`, `DataClassification::SystemMetadata`,
`TelemetryScope::ExtensionPublisher`.

Example KQL to chart canary health across a fleet in Application Insights (adjust the
`aadTenantId` dimension name to whatever your workspace surfaces):

```kql
traces
| where customDimensions.eventId in ("ALP0001", "ALP0002", "ALP0003")
| extend
    tenant = tostring(customDimensions.aadTenantId),
    activityId = tostring(customDimensions.ActivityId),
    attempts = toint(customDimensions.Attempts),
    httpStatus = toint(customDimensions.HttpStatus)
| summarize
    Started = countif(customDimensions.eventId == "ALP0001"),
    Shipped = countif(customDimensions.eventId == "ALP0002"),
    Failed  = countif(customDimensions.eventId == "ALP0003"),
    MaxAttempts = max(attempts)
    by tenant, bin(timestamp, 1h)
| extend FailureRate = round(100.0 * Failed / iif(Shipped + Failed == 0, 1, Shipped + Failed), 1)
| order by timestamp desc, FailureRate desc
```

## License

MIT
