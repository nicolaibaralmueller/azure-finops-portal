# Tools

Operational helpers — run manually by an operator, not part of the deployed app.

| Script | Purpose |
|---|---|
| `Invoke-SpikeDetection.ps1` | Run the ingest + analysis timers on demand (e.g. for a first run, or to re-detect after changing thresholds). Calls the Functions admin endpoint; runs the real pipeline against real Cost Management data. Runs the timers **one at a time, in pipeline order**, waiting for each to be reported finished in Application Insights (fixed pauses when it can't be read), because later timers read what earlier ones write and the worker's memory is shared with the portal. `-NoWait` restores fire-and-forget. |
| `Get-StorageAccountCost.ps1` | Last month's actual cost of every storage account in every subscription under a management group (nested groups included), per subscription with totals. Read-only (Cost Management Reader); `-CostColumn Cost` for MCA billing. Needs `Az.Accounts` and `Az.ResourceGraph`. |

> **No tool here fabricates data, and none should be added.** Everything the portal
> displays is derived from the tenant's own Cost Management, Resource Graph, Advisor and
> Azure Monitor responses. A seeding script that plants synthetic rows in `CostSnapshots`
> puts invented figures in the same tables — and behind the same UI — as billed ones, with
> nothing downstream able to tell them apart: detection would flag the planted spike, the
> model would explain it from the planted evidence, and the grounding check would pass it, because the numbers really
> are in the payload. To exercise detection without waiting for a real spike, lower the
> thresholds (`weekMinDeltaUsd` / `monthMinDeltaUsd` via `SavePortalConfig`) or test the
> deterministic engines offline against in-memory rows that never reach Azure.
