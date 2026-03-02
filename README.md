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

## License

MIT
