param($Task, $TriggerMetadata)

# One cost-ingest task from the 'cost-tasks' queue (Modules/CostIngest.psm1, Invoke-CostTask):
#   recent   one subscription's nightly window
#   history  one month of history for the subscriptions that lack it
#   followup the analysis steps after the first full history
# host.json runs these one at a time (queues.batchSize 1): Cost Management's quota is per tenant,
# so parallel queries only buy more throttling. A throttled task puts itself back on the queue
# with a delay rather than sleeping here.

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$mgmtToken    = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
if ($Task -is [string]) { $Task = $Task | ConvertFrom-Json }
Invoke-CostTask -Task $Task -StorageToken $storageToken -MgmtToken $mgmtToken
