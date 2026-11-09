param($Timer)

# Hourly, and once on start-up so a fresh deployment starts loading cost data straight away.
# Decides what the queue-based cost ingest should do next (Modules/CostIngest.psm1):
#   - from 02:00 UTC, today's nightly run: one 'recent' task per subscription;
#   - once that run is done, the next month of the one-time history;
#   - recovery of a run whose tasks went missing, and re-totalling after a scope change.
# Idempotent — every decision is read from state, so runOnStartup on a restart only finds
# nothing to do. The work itself happens in ProcessCostTask-Queue.

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$mgmtToken    = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
$result = Invoke-CostIngestPlanner -StorageToken $storageToken -MgmtToken $mgmtToken
Write-Host "Cost ingest planner: $result"
