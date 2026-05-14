# Request: Access to Scheduled Profiler Data in Cloud Scope

## Context

I am building an AL extension ([AL Perf Analyzer](https://alperf.sshadows.dk)) that adds AI-powered performance analysis actions to the Business Central profiler pages. Single-profile analysis already works in SaaS (the `Performance Profiler` page 1911 is Cloud-scoped), but **batch analysis of scheduled profiles is blocked** because the data is not accessible to Cloud-scoped extensions.

I need access to the data in these tables from Cloud extensions so that SaaS customers can analyze multiple scheduled profiles as a batch. How this data is exposed (changing table scope, adding a Cloud-scoped API, a new codeunit, etc.) is entirely up to you — I just need a way to get to it.

## Data I Need Access To

### From Table 1924 `Performance Profiles`

| Field | Why |
|-------|-----|
| `Profile` (Blob) | The actual profiling data to analyze |
| `Activity ID` | Identifies the profiled activity |
| `Client Type` | Categorize by client type (Web, Background, WebService) |
| `Activity Description` | Human-readable description of what was profiled |
| `Starting Date-Time` | When the profiling started |
| `Activity Duration` | Total activity duration |
| `Duration` | AL execution duration |
| `Sql Call Duration` | SQL time spent |
| `Sql Statement Number` | Number of SQL statements |
| `Http Call Duration` | HTTP time spent |
| `Http Call Number` | Number of HTTP calls |
| `User Name` (FlowField) | Who triggered the activity |
| `Client Session ID` | Session identifier |
| `Schedule ID` | Link to the schedule that triggered this profile |

**Priority: Essential** — this is the core data for batch analysis.

### From Table 1932 `Performance Profile Scheduler`

| Field | Why |
|-------|-----|
| `Description` | Display the schedule name alongside profile results |

**Priority: Nice-to-have** — only used for display enrichment.

### Page Extensibility

I also need the ability to extend these pages (to add analysis actions):

| Object ID | Name | Priority |
|-----------|------|----------|
| 1931 | `Performance Profile List` | Essential |
| 1933 | `Perf. Profiler Schedules List` | Essential |

### Table Extensibility (Nice-to-have)

Being able to extend tables 1924 and 1932 with `tableextension` would be a bonus — it would allow me to store analysis results back on the records and improve the UI (e.g., showing analysis status or scores directly in the list). This is not essential for the core functionality, just a nice-to-have.

## Summary

- I need access to the **data** in tables 1924 and 1932 from Cloud-scoped extensions
- I need **extensibility** on pages 1931 and 1933
- Table extensibility on 1924/1932 would be a bonus for richer UI integration
- How this is exposed is up to Microsoft — changing scope, adding an API, a facade codeunit, or any other mechanism works for me
- **Impact**: Would enable SaaS extensions to provide batch performance analysis of scheduled profiler results
