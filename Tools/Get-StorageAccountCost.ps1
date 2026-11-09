#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph
<#
.SYNOPSIS
    Retrieves last month's actual cost for all storage accounts in every subscription
    under a management group (including nested management groups).

.DESCRIPTION
    1. Uses Azure Resource Graph to list all subscriptions under the management group.
    2. Queries the Cost Management Query API per subscription (read-only), filtered to
       ResourceType microsoft.storage/storageaccounts and grouped by ResourceId.
    3. Prints a console table grouped per subscription, then per storage account,
       followed by subscription totals and a grand total.

    Read-only. Requires Cost Management Reader (or Reader) on the subscriptions.

.PARAMETER ManagementGroupId
    The management group ID (name, not display name).

.PARAMETER CostColumn
    Cost column to aggregate. 'PreTaxCost' for EA/PAYG. Use 'Cost' if the query fails on MCA.

.PARAMETER MaxRetries
    Max retries per request when Cost Management throttles (HTTP 429/503).

.EXAMPLE
    .\Get-StorageAccountCost.ps1 -ManagementGroupId 'mg-platform'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManagementGroupId,

    [ValidateSet('PreTaxCost', 'Cost')]
    [string]$CostColumn = 'PreTaxCost',

    [int]$MaxRetries = 5
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2023-11-01'

#region Context
$context = Get-AzContext
if (-not $context) {
    Connect-AzAccount | Out-Null
    $context = Get-AzContext
}
$armUrl = $context.Environment.ResourceManagerUrl.TrimEnd('/')

$periodStart = (Get-Date -Day 1).Date.AddMonths(-1)
$periodEnd   = (Get-Date -Day 1).Date.AddDays(-1)
Write-Host ("Period: {0:yyyy-MM-dd} to {1:yyyy-MM-dd} (Custom, ActualCost)" -f $periodStart, $periodEnd) -ForegroundColor Cyan
#endregion

#region Functions
function Get-ColumnIndex {
    param(
        [Parameter(Mandatory)][string[]]$Columns,
        [Parameter(Mandatory)][string[]]$Candidates,
        [switch]$Optional
    )
    foreach ($candidate in $Candidates) {
        for ($c = 0; $c -lt $Columns.Count; $c++) {
            if ([string]::Equals($Columns[$c], $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $c
            }
        }
    }
    return -1
}

function Invoke-CostQuery {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Payload
    )

    $attempt = 0
    while ($true) {
        $attempt++
        $response = Invoke-AzRestMethod -Method POST -Uri $Uri -Payload $Payload

        if ($response.StatusCode -eq 200) {
            return ($response.Content | ConvertFrom-Json -Depth 20)
        }

        if ($response.StatusCode -in 429, 503 -and $attempt -le $MaxRetries) {
            $retryAfter = 30
            $headerNames = @(
                'x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after',
                'x-ms-ratelimit-microsoft.costmanagement-entity-retry-after',
                'x-ms-ratelimit-microsoft.costmanagement-tenant-retry-after',
                'Retry-After'
            )
            foreach ($name in $headerNames) {
                $values = $null
                try {
                    if ($response.Headers -and $response.Headers.TryGetValues($name, [ref]$values)) {
                        $parsed = 0
                        if ([int]::TryParse(($values | Select-Object -First 1), [ref]$parsed) -and $parsed -gt 0) {
                            $retryAfter = $parsed
                            break
                        }
                    }
                }
                catch { }
            }
            Write-Verbose "Throttled (HTTP $($response.StatusCode)). Waiting $retryAfter s (attempt $attempt/$MaxRetries)."
            Start-Sleep -Seconds $retryAfter
            continue
        }

        throw "Cost query failed. HTTP $($response.StatusCode): $($response.Content)"
    }
}
#endregion

#region Subscriptions under management group
$subscriptions = [System.Collections.Generic.List[object]]::new()
$graphQuery = @"
resourcecontainers
| where type == 'microsoft.resources/subscriptions'
| project subscriptionId, name, state = tostring(properties.state)
"@

$skipToken = $null
do {
    $graphParams = @{
        Query           = $graphQuery
        ManagementGroup = $ManagementGroupId
        First           = 1000
    }
    if ($skipToken) { $graphParams.SkipToken = $skipToken }

    $graphResult = Search-AzGraph @graphParams
    foreach ($row in $graphResult.Data) { $subscriptions.Add($row) }
    $skipToken = $graphResult.SkipToken
} while ($skipToken)

$subscriptions = $subscriptions | Where-Object { $_.state -ne 'Disabled' } | Sort-Object name
Write-Host "Subscriptions found: $($subscriptions.Count)" -ForegroundColor Cyan
if (-not $subscriptions) { return }
#endregion

#region Cost query body
$body = @{
    type       = 'ActualCost'
    timeframe  = 'Custom'
    timePeriod = @{
        from = $periodStart.ToString('yyyy-MM-ddT00:00:00Z')
        to   = $periodEnd.ToString('yyyy-MM-ddT23:59:59Z')
    }
    dataset    = @{
        granularity = 'None'
        aggregation = @{
            totalCost = @{ name = $CostColumn; function = 'Sum' }
        }
        grouping    = @(
            @{ type = 'Dimension'; name = 'ResourceId' }
        )
        filter      = @{
            dimensions = @{
                name     = 'ResourceType'
                operator = 'In'
                values   = @('microsoft.storage/storageaccounts')
            }
        }
    }
} | ConvertTo-Json -Depth 10
#endregion

#region Query costs per subscription
$results  = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[object]]::new()
$i = 0

foreach ($sub in $subscriptions) {
    $i++
    Write-Progress -Activity 'Querying storage account costs' -Status $sub.name -PercentComplete (($i / $subscriptions.Count) * 100)

    $uri = "$armUrl/subscriptions/$($sub.subscriptionId)/providers/Microsoft.CostManagement/query?api-version=$apiVersion"

    try {
        do {
            $data = Invoke-CostQuery -Uri $uri -Payload $body

            $columns     = @($data.properties.columns.name)
            $idxCost     = Get-ColumnIndex -Columns $columns -Candidates @('totalCost', $CostColumn, 'PreTaxCost', 'Cost')
            $idxResource = Get-ColumnIndex -Columns $columns -Candidates @('ResourceId')
            $idxCurrency = Get-ColumnIndex -Columns $columns -Candidates @('Currency') -Optional

            if ($idxCost -lt 0 -or $idxResource -lt 0) {
                throw "Expected columns not found. Returned columns: $($columns -join ', ')"
            }

            foreach ($row in $data.properties.rows) {
                $resourceId = [string]$row[$idxResource]
                $segments   = $resourceId.Split('/')
                $rgIndex    = [Array]::IndexOf($segments.ToLower(), 'resourcegroups')

                $results.Add([pscustomobject]@{
                    SubscriptionName = $sub.name
                    SubscriptionId   = $sub.subscriptionId
                    ResourceGroup    = if ($rgIndex -ge 0) { $segments[$rgIndex + 1] } else { '' }
                    StorageAccount   = $segments[-1]
                    Cost             = [math]::Round([double]$row[$idxCost], 2)
                    Currency         = if ($idxCurrency -ge 0) { $row[$idxCurrency] } else { '' }
                })
            }
            Write-Verbose "$($sub.name): columns = $($columns -join ', ')"

            $uri = $data.properties.nextLink
        } while ($uri)
    }
    catch {
        $failures.Add([pscustomobject]@{
            SubscriptionName = $sub.name
            SubscriptionId   = $sub.subscriptionId
            Error            = $_.Exception.Message
        })
        Write-Warning "Failed for $($sub.name): $($_.Exception.Message)"
    }
}
Write-Progress -Activity 'Querying storage account costs' -Completed
#endregion

#region Output
if (-not $results) {
    Write-Host 'No storage account costs found for the period.' -ForegroundColor Yellow
}
else {
    Write-Host "`n=== Cost per subscription / storage account ===" -ForegroundColor Cyan
    $results |
        Sort-Object -Property SubscriptionName, @{ Expression = 'Cost'; Descending = $true } |
        Format-Table -Property StorageAccount, ResourceGroup, Cost, Currency -GroupBy SubscriptionName -AutoSize

    Write-Host "=== Subscription totals ===" -ForegroundColor Cyan
    $results |
        Group-Object -Property SubscriptionName, Currency |
        ForEach-Object {
            [pscustomobject]@{
                SubscriptionName = $_.Group[0].SubscriptionName
                StorageAccounts  = $_.Count
                TotalCost        = [math]::Round(($_.Group | Measure-Object -Property Cost -Sum).Sum, 2)
                Currency         = $_.Group[0].Currency
            }
        } |
        Sort-Object -Property TotalCost -Descending |
        Format-Table -AutoSize

    Write-Host "=== Grand total ===" -ForegroundColor Cyan
    $results |
        Group-Object -Property Currency |
        ForEach-Object {
            [pscustomobject]@{
                Currency  = $_.Name
                TotalCost = [math]::Round(($_.Group | Measure-Object -Property Cost -Sum).Sum, 2)
            }
        } |
        Format-Table -AutoSize
}

if ($failures) {
    Write-Host "=== Failed subscriptions ===" -ForegroundColor Yellow
    $failures | Format-Table -AutoSize -Wrap
}
#endregion
