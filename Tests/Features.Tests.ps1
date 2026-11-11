# Offline tests for the 2026-09-18 feature round: the tenant cost scope (forecast/Ask coverage),
# allocation by owner/tag/resource group, the extra savings levers, and the cost explorer.
# No Azure: everything goes through the stubs in TestKit.ps1. Run via Tests/Invoke-OfflineTests.ps1.

param([switch]$PassThru)

. (Join-Path $PSScriptRoot 'TestKit.ps1')

$subA = $sub
$subB = '22222222-2222-3333-4444-555555555555'
$subC = '33333333-2222-3333-4444-555555555555'
function Read-Body { param($Response) [string]$Response.Body | ConvertFrom-Json }

# ARM: two management groups; 'mg-all' holds A, B and C, 'mg-prod' holds A and B.
$global:MgListFails = $false
$global:RestResponder = {
    param($Method, $Uri, $Body)
    if ($Uri -match 'Microsoft\.Management/managementGroups\?api-version') {
        if ($global:MgListFails) { throw '403 Forbidden' }
        return [PSCustomObject]@{ value = @(
            [PSCustomObject]@{ name = 'mg-all'; properties = [PSCustomObject]@{ displayName = 'Tenant Root' } }
            [PSCustomObject]@{ name = 'mg-prod'; properties = [PSCustomObject]@{ displayName = 'Production' } }
        ); nextLink = $null }
    }
    if ($Uri -like '*managementGroups/mg-all/descendants*') {
        return [PSCustomObject]@{ value = @(
            [PSCustomObject]@{ type = 'Microsoft.Management/managementGroups'; name = 'mg-prod' }
            [PSCustomObject]@{ type = '/subscriptions'; name = $subA }
            [PSCustomObject]@{ type = '/subscriptions'; name = $subB }
            [PSCustomObject]@{ type = '/subscriptions'; name = $subC }
        ); nextLink = $null }
    }
    if ($Uri -like '*managementGroups/mg-prod/descendants*') {
        return [PSCustomObject]@{ value = @(
            [PSCustomObject]@{ type = '/subscriptions'; name = $subA }
            [PSCustomObject]@{ type = '/subscriptions'; name = $subB }
        ); nextLink = $null }
    }
    if ($Uri -like '*management.azure.com/subscriptions?api-version*') {
        return [PSCustomObject]@{ value = @(
            [PSCustomObject]@{ subscriptionId = $subA; displayName = 'Payments'; state = 'Enabled' }
            [PSCustomObject]@{ subscriptionId = $subB; displayName = 'Data'; state = 'Enabled' }
        ); nextLink = $null }
    }
    if ($global:ExtraRest) { $r = & $global:ExtraRest $Method $Uri $Body; if ($null -ne $r) { return $r } }
    throw "unexpected REST call: $Method $Uri"
}

Write-Host "`nTenant cost scope"
Test-That 'the smallest management group that contains every subscription is chosen' {
    Reset-State
    $mg = Find-CoveringManagementGroup -MgmtToken 't' -SubscriptionIds @($subA, $subB)
    Assert-Equal '/providers/Microsoft.Management/managementGroups/mg-prod' $mg.Scope 'smallest covering group'
    Assert-Equal 0 $mg.Extra 'holds nothing else'
    $mg = Find-CoveringManagementGroup -MgmtToken 't' -SubscriptionIds @($subA, $subC)
    Assert-Equal '/providers/Microsoft.Management/managementGroups/mg-all' $mg.Scope 'only the root covers A and C'
    Assert-Equal 1 $mg.Extra 'one extra subscription to filter out'
}
Test-That 'no readable group means no scope, stored as such; COST_QUERY_SCOPE always wins' {
    Reset-State
    $global:MgListFails = $true
    try {
        $r = Update-ResolvedCostScope -MgmtToken 't' -StorageToken 't' -SubscriptionIds @($subA, $subB)
        Assert-Equal 'none' $r.Source 'none'
        Assert-Equal '' (Get-ResolvedCostScope -StorageToken 't').Scope 'stored as none'
    } finally { $global:MgListFails = $false }
    $null = Update-ResolvedCostScope -MgmtToken 't' -StorageToken 't' -SubscriptionIds @($subA, $subB)
    Assert-Equal 'discovered' (Get-ResolvedCostScope -StorageToken 't').Source 'discovered and stored'
    $env:COST_QUERY_SCOPE = '/providers/Microsoft.Management/managementGroups/configured'
    try { Assert-Equal 'configured' (Get-ResolvedCostScope -StorageToken 't').Source 'configured wins' }
    finally { $env:COST_QUERY_SCOPE = '' }
}
Test-That 'Ask uses the discovered group, filtered to the portal''s subscriptions when it holds more' {
    Reset-State
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'subscriptions'; RowKey = 'discovered'
        SubscriptionsJson = (@([ordered]@{ id = $subA; name = 'A' }, [ordered]@{ id = $subC; name = 'C' }) | ConvertTo-Json -Compress -AsArray) }
    $null = Update-ResolvedCostScope -MgmtToken 't' -StorageToken 't' -SubscriptionIds @($subA, $subC)
    $global:AiResponder = {
        param($req)
        $sys = [string]$req.messages[0].content
        if ($sys -match 'structured') { New-ChatResponse @{ timeframe = 'MonthToDate'; from = $null; to = $null; granularity = 'None'; groupBy = @('ServiceName'); filters = $null; compareWithPrevious = $false; scopeToContextSubscription = $false; filterDimension = $null; filterValues = $null } }
        else { New-ChatResponse @{ answer = 'Mostly compute.' } }
    }
    $global:CostResponder = { param($b, $u) $global:LastCostUri = $u; New-CostResponse -Columns @('Cost', 'ServiceName', 'Currency') -Rows @(, @(5.0, 'Compute', 'EUR')) }
    $r = Invoke-HttpFunction -Name 'QueryCosts' -Body ([PSCustomObject]@{ question = 'what did we spend by service?' })
    Assert-Equal 200 ([int]$r.StatusCode) "status: $($r.Body)"
    Assert-True ($global:LastCostUri -like '*managementGroups/mg-all/*') "asked at the group: $($global:LastCostUri)"
    $f = $global:CostQueryBodies[-1].dataset.filter.dimensions
    Assert-Equal 'SubscriptionId' $f.name 'filtered'
    Assert-Equal ((@($subA, $subC) | Sort-Object) -join ',') ((@($f.values) | Sort-Object) -join ',') 'to the two covered subscriptions'
}
Test-That 'without any group Ask says it only sees the deployment subscription' {
    Reset-State
    $env:AZURE_SUBSCRIPTION_ID = $subA
    $r = Invoke-HttpFunction -Name 'QueryCosts' -Body ([PSCustomObject]@{ question = 'what did we spend by service?' })
    $body = Read-Body $r
    Assert-True ([string]$body.scope -like 'only the deployment subscription*') "scope label: $($body.scope)"
}

Write-Host "`nAllocation: who spends it"
$rgPay = "/subscriptions/$subA/resourceGroups/rg-payments"
$rgData = "/subscriptions/$subB/resourceGroups/rg-data"
$vmPay = "$rgPay/providers/Microsoft.Compute/virtualMachines/vm-pay"
$sqlPay = "$rgPay/providers/Microsoft.Sql/servers/sql-pay"
$lakeData = "$rgData/providers/Microsoft.Storage/storageAccounts/lake"
$gone = "$rgData/providers/Microsoft.Compute/disks/old-disk"
# Resource Graph: the payments group is owned by team-payments; the VM overrides its owner and
# says it is prod; the lake has no tags and its group none either; the old disk no longer exists.
$global:ExtraRest = {
    param($Method, $Uri, $Body)
    if ($Uri -notlike '*Microsoft.ResourceGraph/resources*') { return $null }
    $q = [string](($Body | ConvertFrom-Json).query)
    $data = if ($q -match 'resourcecontainers') {
        @([PSCustomObject]@{ id = $rgPay.ToLower(); tags = [PSCustomObject]@{ Owner = 'team-payments'; 'Cost-Center' = 'CC-100' } }
          [PSCustomObject]@{ id = $rgData.ToLower(); tags = $null })
    } else {
        @([PSCustomObject]@{ id = $vmPay.ToLower(); tags = [PSCustomObject]@{ owner = 'alice'; Environment = 'prod' } }
          [PSCustomObject]@{ id = $sqlPay.ToLower(); tags = $null }
          [PSCustomObject]@{ id = $lakeData.ToLower(); tags = $null })
    }
    return [PSCustomObject]@{ data = $data; '$skipToken' = $null }
}
Test-That 'tag keys are matched loosely and inherit from the resource group key by key' {
    Assert-Equal 'costcenter' (ConvertTo-TagKeyNorm 'Cost-Center') 'normalised'
    $idx = Get-ResourceTagIndex -MgmtToken 't' -SubscriptionIds @($subA, $subB)
    $keys = @('owner', 'costcenter', 'environment', 'application')
    $vm = Get-ResourceAllocation -Index $idx -ResourceId $vmPay -TagKeys $keys
    Assert-Equal 'alice' $vm.owner 'own tag wins'
    Assert-Equal 'CC-100' $vm.costcenter 'group tag fills the gap'
    Assert-Equal 'prod' $vm.environment 'own tag'
    Assert-Equal '(untagged)' $vm.application 'nowhere'
    Assert-Equal 'rg-payments' $vm.resourceGroup 'group name'
    Assert-Equal 'team-payments' (Get-ResourceAllocation -Index $idx -ResourceId $sqlPay -TagKeys $keys).owner 'inherited owner'
    Assert-Equal '(resource no longer exists)' (Get-ResourceAllocation -Index @{ x = @{ Tags = @{} } } -ResourceId $gone -TagKeys $keys).owner 'gone'
    Assert-True ($null -eq (Get-ResourceAllocation -Index @{} -ResourceId $vmPay -TagKeys $keys)) 'nothing readable = unknown, not untagged'
}
Test-That 'the rollup sums each owner, compares with the same days last month, and shares add to 100' {
    $idx = Get-ResourceTagIndex -MgmtToken 't' -SubscriptionIds @($subA, $subB)
    $per = @{
        $vmPay.ToLower()    = @{ Current = 300.0; PreviousSameDays = 200.0; PreviousMonth = 400.0 }
        $sqlPay.ToLower()   = @{ Current = 100.0; PreviousSameDays = 100.0; PreviousMonth = 210.0 }
        $lakeData.ToLower() = @{ Current = 100.0; PreviousSameDays = 50.0; PreviousMonth = 90.0 }
    }
    $r = Measure-AllocationRollup -PerResource $per -Index $idx -TagKeys @('owner', 'costcenter') -SubscriptionNames @{ $subA = 'Payments'; $subB = 'Data' }
    $owners = @($r['tag:owner'])
    Assert-Equal 'alice,team-payments,(untagged)' (($owners | ForEach-Object key) -join ',') 'largest first'
    Assert-Equal 60.0 $owners[0].sharePct 'alice is 300 of 500'
    Assert-Equal 50.0 $owners[0].deltaPct '+50% on the same days'
    Assert-Equal 100.0 (($owners | Measure-Object -Property sharePct -Sum).Sum) 'shares add up'
    $rgs = @($r['resourceGroup'])
    Assert-Equal 'rg-payments (Payments)' $rgs[0].label 'group labelled with its subscription'
    Assert-Equal 2 $rgs[0].resources 'two resources with cost'
}
# What SyncAllocation-Timer stored: { meta; dims (names, sorted); rows(dim) }.
function Read-Allocation {
    $all = @($global:Store['CostSummary'].Values | Where-Object PartitionKey -eq 'allocation')
    $meta = @($all | Where-Object RowKey -eq 'meta')[0]
    [PSCustomObject]@{
        meta = $meta
        dims = (@($all | Where-Object RowKey -ne 'meta' | ForEach-Object RowKey | Sort-Object) -join ',')
        rows = { param($d) $r = @($all | Where-Object RowKey -eq $d)[0]; if ($r) { @([string]$r.RowsJson | ConvertFrom-Json) } else { @() } }.GetNewClosure()
    }
}
Test-That 'nightly allocation from stored snapshots, per dimension; resource groups follow the scope' {
    Reset-State
    Set-Setting @{ AllocationTagKeys = 'Owner, cost-center' }
    $settled = Get-RollingWindowEndDate
    $monthStart = Get-UtcMonthStart -Date $settled
    for ($d = $monthStart.AddMonths(-1); $d -le $settled; $d = $d.AddDays(1)) {
        foreach ($x in @(@{ id = $vmPay; c = 10.0 }, @{ id = $lakeData; c = 5.0 })) {
            Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $d.ToString('yyyy-MM-dd'); RowKey = (Get-ShortHash -Value $x.id)
                ResourceId = $x.id; Scope = (Get-RowSubscriptionId -Row $x.id); CostUsd = $x.c }
        }
    }
    & (Join-Path $fa 'SyncAllocation-Timer/run.ps1') -Timer $null *> $null
    $a = Read-Allocation
    Assert-True ($null -ne $a.meta) 'ready'
    Assert-Equal 'resourceGroup,tag:costcenter,tag:owner' $a.dims 'configured keys and groups'
    $days = ($settled - $monthStart).Days + 1
    Assert-Equal (15.0 * $days) ([double]$a.meta.TotalCurrentUsd) 'this month so far'
    $alice = @((& $a.rows 'tag:owner') | Where-Object key -eq 'alice')[0]
    Assert-Equal (10.0 * $days) $alice.currentUsd 'alice'
    Assert-Equal (10.0 * $days) $alice.previousSameDaysUsd 'same days of last month'
    Assert-Equal 2 @(& $a.rows 'resourceGroup').Count 'two groups'
    Assert-Equal 2 @(Get-InsightResourceGroups -Token 't').Count 'both groups on the Overview'
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'settings'; RowKey = 'scope'; IncludedSubscriptionIds = $subA }
    Assert-Equal 1 @(Get-InsightResourceGroups -Token 't').Count 'the excluded subscription''s group is hidden at once'
}
Write-Host "`nBudget pace and monthly statements"
Test-That 'month spend reports the calendar length, so budget pace is not always 100%' {
    $days = @{}
    for ($d = 1; $d -le 10; $d++) { $days["2026-09-$('{0:d2}' -f $d)"] = @{ TotalUsd = 10.0 } }
    $m = Measure-MonthSpend -Days $days -Month ([datetime]'2026-09-01') -ThroughDay 10
    Assert-Equal 10 $m.throughDay 'through day'
    Assert-Equal 10 $m.expectedDays 'days counted'
    Assert-Equal 30 $m.daysInMonth 'September has 30 days'
    Assert-True $m.complete 'all counted days present'
}
Test-That 'the statement groups last month per owner, with services, top resources and savings' {
    $idx = Get-ResourceTagIndex -MgmtToken 't' -SubscriptionIds @($subA, $subB)
    $per = @{
        $vmPay.ToLower()    = @{ LastMonth = 300.0; MonthBefore = 200.0; Meters = @{ 'Virtual Machines' = @(270.0, 200.0); 'Bandwidth' = @(20.0, 0.0); 'Storage' = @(10.0, 0.0) } }
        $sqlPay.ToLower()   = @{ LastMonth = 100.0; MonthBefore = 100.0; Meters = @{ 'SQL Database' = @(100.0, 100.0) } }
        $lakeData.ToLower() = @{ LastMonth = 100.0; MonthBefore = 50.0; Meters = @{ 'Storage' = @(100.0, 50.0) } }
    }
    $savings = @(
        [PSCustomObject]@{ id = 'S-1'; title = 'Resize vm-pay'; resourceId = $vmPay; resourceName = 'vm-pay'; monthlyUsd = 40.0; source = 'analysis'; tier = 'likely' }
        [PSCustomObject]@{ id = 'S-2'; title = 'Delete disk'; resourceId = $lakeData; resourceName = 'lake'; monthlyUsd = 5.0; source = 'analysis'; tier = 'certain' }
        [PSCustomObject]@{ id = 'A-1'; title = 'Buy a reservation'; resourceId = "/subscriptions/$subA"; resourceName = ''; monthlyUsd = 99.0; source = 'advisor'; tier = 'likely' }
    )
    $r = Measure-AllocationStatement -PerResource $per -Index $idx -TagKeys @('owner', 'costcenter') -Savings $savings -BilledUsd 625.0 -TopServices 2
    Assert-Equal 625.0 $r.reconciliation.billedUsd 'billed'
    Assert-Equal 500.0 $r.reconciliation.attributedUsd 'resource-attributed'
    Assert-Equal 125.0 $r.reconciliation.sharedUsd 'shared = billed - attributed, shown separately'
    $owners = @($r.dims['tag:owner'].index)
    Assert-Equal 'alice,team-payments,(untagged)' (($owners | ForEach-Object key) -join ',') 'owners first, untagged last'
    Assert-True $owners[2].separate 'untagged is flagged to be shown apart'
    Assert-Equal 48.0 $owners[0].sharePct 'share of the BILL: 300 of 625'
    Assert-Equal 100.0 ((($owners | Measure-Object -Property sharePct -Sum).Sum) + $r.reconciliation.sharedPct) 'owners + untagged + shared = 100%'
    Assert-Equal 50.0 $owners[0].deltaPct 'alice +50% on the month before'
    $alice = $r.dims['tag:owner'].statements['alice']
    Assert-Equal 'Virtual Machines,Other (2)' (($alice.byService | ForEach-Object name) -join ',') 'top services, the rest folded'
    Assert-Equal 30.0 @($alice.byService)[1].usd 'folded amount'
    Assert-Equal 40.0 $alice.openSavingsUsd 'the saving on her VM'
    Assert-Equal 'S-1' @($alice.savings)[0].id 'listed'
    Assert-Equal 5.0 $r.dims['tag:owner'].statements['(untagged)'].openSavingsUsd 'untagged savings stay with untagged'
    Assert-Equal 0 @($r.dims['tag:owner'].statements.Values | Where-Object { @($_.savings | Where-Object id -eq 'A-1').Count }).Count 'a saving with no resource belongs to nobody'
    $cc = @($r.dims['tag:costcenter'].index)
    Assert-Equal 'CC-100' $cc[0].key 'both payments resources inherit CC-100'
    Assert-Equal 400.0 $cc[0].totalUsd 'cost centre total'
    $noBill = Measure-AllocationStatement -PerResource $per -Index $idx -TagKeys @('owner')
    Assert-True ($null -eq $noBill.reconciliation.sharedUsd) 'no bill, no invented shared figure'
    Assert-Equal 60.0 @($noBill.dims['tag:owner'].index)[0].sharePct 'shares fall back to the attributed total'
}
Test-That 'nightly statement from stored snapshots, served per owner and filtered by scope' {
    Reset-State
    Set-Setting @{ AllocationTagKeys = 'Owner, cost-center' }
    function global:Remove-TableEntityBatch { param($Table, $Entities, $Token)
        foreach ($e in @($Entities)) { $null = $global:Store[$Table].Remove("$($e.PartitionKey)|$($e.RowKey)") }; @($Entities).Count }
    try {
        $settled = Get-RollingWindowEndDate
        $stmtMonth = Get-BriefTargetMonth
        $mk = $stmtMonth.ToString('yyyy-MM')
        for ($d = $stmtMonth.AddMonths(-1); $d -le $settled; $d = $d.AddDays(1)) {
            foreach ($x in @(@{ id = $vmPay; c = 10.0; m = 'Virtual Machines' }, @{ id = $lakeData; c = 5.0; m = 'Storage' })) {
                Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $d.ToString('yyyy-MM-dd'); RowKey = (Get-ShortHash -Value $x.id)
                    ResourceId = $x.id; Scope = (Get-RowSubscriptionId -Row $x.id); Meter = $x.m; CostUsd = $x.c }
            }
            Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = $d.ToString('yyyy-MM-dd'); Date = $d.ToString('yyyy-MM-dd'); TotalUsd = 20.0 }
        }
        Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings-meta'; RowKey = 'latest'; LatestRunId = 'r1' }
        Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = 'aaaaaaaaaaaaaaaa'; RunId = 'r1'; Category = 'rightsize'; Tier = 'likely'
            ResourceId = $vmPay; ResourceName = 'vm-pay'; Title = 'Resize vm-pay'; Detail = 'x'; EstMonthlySavingsUsd = 40.0 }
        # A statement row from 14 months back is pruned; an orphan in this month is removed.
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'statement'; RowKey = "$($stmtMonth.AddMonths(-14).ToString('yyyy-MM'))|tag:owner|index"; Month = 'old' }
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'statement'; RowKey = "$mk|tag:owner|ffffffffffffffff"; Value = 'bob' }

        & (Join-Path $fa 'SyncAllocation-Timer/run.ps1') -Timer $null *> $null
        $dim = [datetime]::DaysInMonth($stmtMonth.Year, $stmtMonth.Month)
        $body = Read-Body (Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = $mk })
        Assert-True $body.ready 'ready'
        Assert-Equal $mk $body.month 'the last complete month'
        $cur = (Get-UtcMonthStart -Date $settled).ToString('yyyy-MM')
        if ($cur -ne $mk) { Assert-Equal $cur (Read-Body (Invoke-HttpFunction -Name 'GetStatement')).month 'the page opens on the current month so far' }
        Assert-Equal 'tag:owner,tag:costcenter' ($body.dimensions -join ',') 'configured tag keys, in order'
        Assert-True $body.complete 'every day covered'
        Assert-Equal (20.0 * $dim) $body.reconciliation.billedUsd 'billed from dailytotal'
        Assert-Equal (5.0 * $dim) $body.reconciliation.sharedUsd 'shared spend shown separately'
        Assert-Equal 'alice,(untagged)' (($body.rows | ForEach-Object key) -join ',') 'owners, then untagged'
        $oldKey = "statement|$($stmtMonth.AddMonths(-14).ToString('yyyy-MM'))|tag:owner|index"
        Assert-True (-not $global:Store['CostSummary'].ContainsKey($oldKey)) 'a month older than 13 is pruned'
        $alice = (Read-Body (Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = $mk; value = 'alice' })).statement
        Assert-Equal (10.0 * $dim) $alice.totalUsd 'alice last month'
        Assert-Equal 'Virtual Machines' @($alice.byService)[0].name 'by service'
        Assert-Equal 40.0 $alice.openSavingsUsd 'her open saving'
        Assert-Equal 404 ([int](Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = $mk; value = 'bob' }).StatusCode) 'orphan removed'
        Assert-Equal 400 ([int](Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = "x' or '1" }).StatusCode) 'month shape checked'
        Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'settings'; RowKey = 'scope'; IncludedSubscriptionIds = $subA }
        $un = Read-Body (Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = $mk; value = '(untagged)' })
        Assert-Equal 0 @($un.statement.topResources).Count 'the excluded subscription''s resources are hidden at once'
        Assert-True $un.scopePending 'the sums wait for tonight'
    } finally { Remove-Item function:global:Remove-TableEntityBatch -ErrorAction SilentlyContinue }
}
Write-Host "`nOwner and cost-centre views"
Test-That 'variant tag values merge; an alias gives the canonical value as written' {
    Assert-Equal 'team payments' (ConvertTo-TagValueNorm -Value '  Team   Payments ' -Key 'owner') 'trimmed, collapsed, lower-cased'
    $aliases = ConvertTo-AllocationAliasMap -Setting '{"Cost-Center":{"cc100":"CC-100"},"owner":{"payments":"team-payments"}}'
    Assert-Equal 'CC-100' (ConvertTo-TagValueNorm -Value 'cc100' -Key 'costcenter' -Aliases $aliases) 'variant -> canonical, verbatim'
    Assert-True ((ConvertTo-TagValueNorm -Value 'cc-100' -Key 'costcenter' -Aliases $aliases) -ceq 'CC-100') 'the canonical in another case lands on it too'
    Assert-Equal 'team-payments' (ConvertTo-TagValueNorm -Value 'Payments' -Key 'owner' -Aliases $aliases) 'owner alias'
    Assert-Equal 0 (ConvertTo-AllocationAliasMap -Setting 'not json').Count 'bad setting = no aliases, no throw'
    $rgA = "/subscriptions/$subA/resourceGroups/rg-a"
    $idx = @{}
    $vm1 = "$rgA/providers/Microsoft.Compute/virtualMachines/vm1"; $vm2 = "$rgA/providers/Microsoft.Compute/virtualMachines/vm2"; $vm3 = "$rgA/providers/Microsoft.Compute/virtualMachines/vm3"
    $idx[$vm1.ToLower()] = @{ Tags = (ConvertTo-NormalisedTags -Tags @{ Owner = 'Team-Payments' } -Aliases $aliases); Exists = $true }
    $idx[$vm2.ToLower()] = @{ Tags = (ConvertTo-NormalisedTags -Tags @{ owner = 'team-payments ' } -Aliases $aliases); Exists = $true }
    $idx[$vm3.ToLower()] = @{ Tags = (ConvertTo-NormalisedTags -Tags @{ owner = 'payments' } -Aliases $aliases); Exists = $true }
    $per = @{ $vm1.ToLower() = @{ Current = 1.0; PreviousSameDays = 0.0; PreviousMonth = 0.0 }; $vm2.ToLower() = @{ Current = 2.0; PreviousSameDays = 0.0; PreviousMonth = 0.0 }; $vm3.ToLower() = @{ Current = 4.0; PreviousSameDays = 0.0; PreviousMonth = 0.0 } }
    $owners = @((Measure-AllocationRollup -PerResource $per -Index $idx -TagKeys @('owner'))['tag:owner'])
    Assert-Equal 1 $owners.Count 'one owner, not three'
    Assert-Equal 7.0 $owners[0].currentUsd 'all spend on it'
}
Test-That 'value aliases are a validated PATCH setting, echoed by GetPortalConfig' {
    Reset-State
    Assert-Equal 400 ([int](Invoke-HttpFunction -Name 'SavePortalConfig' -Body ([PSCustomObject]@{ allocationValueAliases = 'owner=x' })).StatusCode) 'must be an object'
    Assert-Equal 400 ([int](Invoke-HttpFunction -Name 'SavePortalConfig' -Body ([PSCustomObject]@{ allocationValueAliases = [PSCustomObject]@{ owner = [PSCustomObject]@{ a = ('x' * 200) } } })).StatusCode) 'too long'
    Assert-Equal 200 ([int](Invoke-HttpFunction -Name 'SavePortalConfig' -Body ([PSCustomObject]@{ allocationValueAliases = [PSCustomObject]@{ owner = [PSCustomObject]@{ payments = 'team-payments' } } })).StatusCode) 'ok'
    Assert-Equal 'team-payments' (Read-Body (Invoke-HttpFunction -Name 'GetPortalConfig')).allocationValueAliases.owner.payments 'echoed'
    Assert-Equal 'team-payments' ((Get-AllocationValueAliases -StorageToken 't')['owner']['payments']) 'read back by the timers'
}
Test-That 'coverage, and the resource groups to tag first' {
    $idx = Get-ResourceTagIndex -MgmtToken 't' -SubscriptionIds @($subA, $subB)
    $lake2 = "$rgData/providers/Microsoft.Storage/storageAccounts/lake2"
    $per = @{
        $vmPay.ToLower()    = @{ LastMonth = 300.0; MonthBefore = 0.0; Meters = @{} }
        $lakeData.ToLower() = @{ LastMonth = 60.0; MonthBefore = 0.0; Meters = @{} }
        $lake2.ToLower()    = @{ LastMonth = 40.0; MonthBefore = 0.0; Meters = @{} }
    }
    $r = Measure-AllocationStatement -PerResource $per -Index $idx -TagKeys @('owner')
    Assert-Equal 75.0 $r.dims['tag:owner'].coveragePct '300 of 400 has an owner'
    $groups = @($r.dims['tag:owner'].statements['(untagged)'].untaggedGroups)
    Assert-Equal 1 $groups.Count 'one group holds the untagged spend'
    Assert-Equal 'rg-data' $groups[0].name 'named'
    Assert-Equal 100.0 $groups[0].usd 'its untagged spend'
    Assert-Equal 2 $groups[0].resources 'two resources fixed by tagging it'
    Assert-Equal 0 @($r.dims['tag:owner'].statements['alice'].untaggedGroups).Count 'only on the untagged statement'
}
Test-That 'budget tag filters are parsed: tags alone, inside and[], and narrowed by other clauses' {
    Reset-State
    $prev = $global:ExtraRest
    $global:ExtraRest = {
        param($Method, $Uri, $Body)
        if ($Uri -notlike '*Microsoft.Consumption/budgets*') { return $null }
        [PSCustomObject]@{ value = @(
            [PSCustomObject]@{ name = 'cc-100-monthly'; properties = [PSCustomObject]@{ category = 'Cost'; amount = 1000; timeGrain = 'Monthly'
                currentSpend = [PSCustomObject]@{ amount = 700; unit = 'EUR' }; forecastSpend = [PSCustomObject]@{ amount = 1200; unit = 'EUR' }
                filter = [PSCustomObject]@{ tags = [PSCustomObject]@{ name = 'Cost-Center'; operator = 'In'; values = @('cc100') } } } }
            [PSCustomObject]@{ name = 'alice-vms'; properties = [PSCustomObject]@{ category = 'Cost'; amount = 500; timeGrain = 'Monthly'
                currentSpend = [PSCustomObject]@{ amount = 100; unit = 'EUR' }
                filter = [PSCustomObject]@{ and = @([PSCustomObject]@{ tags = [PSCustomObject]@{ name = 'owner'; operator = 'In'; values = @('Alice') } }
                                                  [PSCustomObject]@{ dimensions = [PSCustomObject]@{ name = 'ResourceType'; operator = 'In'; values = @('x') } }) } } }
            [PSCustomObject]@{ name = 'whole-sub'; properties = [PSCustomObject]@{ category = 'Cost'; amount = 9000; timeGrain = 'Monthly'; currentSpend = [PSCustomObject]@{ amount = 100; unit = 'EUR' } } }
            [PSCustomObject]@{ name = 'bi-dev-MonthlyBudget'; id = "/subscriptions/$subA/resourceGroups/bi-dev/providers/Microsoft.Consumption/budgets/bi-dev-MonthlyBudget"
                properties = [PSCustomObject]@{ category = 'Cost'; amount = 1300; timeGrain = 'Monthly'; currentSpend = [PSCustomObject]@{ amount = 2176; unit = 'EUR' } } }
        ); nextLink = $null }
    }
    try {
        $b = @(Get-ConsumptionBudgets -Scope "/subscriptions/$subA" -MgmtToken 't' -ScopeName 'Payments')
        $cc = @($b | Where-Object Name -eq 'cc-100-monthly')[0]
        Assert-Equal 'costcenter' @($cc.TagFilters)[0].key 'tag key normalised'
        Assert-Equal 'cc100' @(@($cc.TagFilters)[0].values)[0] 'values kept'
        Assert-True (-not $cc.ExtraFilters) 'a pure tag budget'
        $al = @($b | Where-Object Name -eq 'alice-vms')[0]
        Assert-Equal 'owner' @($al.TagFilters)[0].key 'tag inside and[]'
        Assert-True $al.ExtraFilters 'a dimension clause narrows it further'
        Assert-Equal 0 @(@($b | Where-Object Name -eq 'whole-sub')[0].TagFilters).Count 'no filter, no tags'
        Assert-Equal '' @($b | Where-Object Name -eq 'whole-sub')[0].ResourceGroupId 'a subscription budget'
        $grp = @($b | Where-Object Name -eq 'bi-dev-MonthlyBudget')[0]
        Assert-Equal "/subscriptions/$subA/resourcegroups/bi-dev" $grp.ResourceGroupId 'the listing includes group budgets; recognised by their id'
        Assert-Equal 'bi-dev' $grp.ScopeName 'named after the group, not the subscription'
    } finally { $global:ExtraRest = $prev }
}
Test-That 'one owner page: this month so far, a 12-month trend and tag budgets' {
    Reset-State
    Set-Setting @{ AllocationTagKeys = 'Owner, cost-center'; AllocationValueAliases = '{"costcenter":{"cc100":"CC-100"}}' }
    function global:Remove-TableEntityBatch { param($Table, $Entities, $Token)
        foreach ($e in @($Entities)) { $null = $global:Store[$Table].Remove("$($e.PartitionKey)|$($e.RowKey)") }; @($Entities).Count }
    try {
        $settled = Get-RollingWindowEndDate
        $stmtMonth = Get-BriefTargetMonth
        $monthStart = Get-UtcMonthStart -Date $settled
        $mk = $stmtMonth.ToString('yyyy-MM'); $cur = $monthStart.ToString('yyyy-MM')
        for ($d = $stmtMonth.AddMonths(-1); $d -le $settled; $d = $d.AddDays(1)) {
            foreach ($x in @(@{ id = $vmPay; c = 10.0; m = 'Virtual Machines' }, @{ id = $lakeData; c = 5.0; m = 'Storage' })) {
                Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $d.ToString('yyyy-MM-dd'); RowKey = (Get-ShortHash -Value $x.id)
                    ResourceId = $x.id; Scope = (Get-RowSubscriptionId -Row $x.id); Meter = $x.m; CostUsd = $x.c }
            }
            Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = $d.ToString('yyyy-MM-dd'); Date = $d.ToString('yyyy-MM-dd'); TotalUsd = 20.0 }
        }
        # Two older months, stored before values were merged ('Alice' then, 'alice' now).
        foreach ($i in 1..2) {
            $om = $stmtMonth.AddMonths(-$i).ToString('yyyy-MM')
            Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'statement'; RowKey = "$om|tag:owner|index"; Month = $om; Dimension = 'tag:owner'
                RowsJson = (ConvertTo-Json -InputObject @([PSCustomObject]@{ key = 'Alice'; totalUsd = (100.0 * $i) }) -Compress); Complete = $true; Partial = $false }
        }
        # A cost-centre budget written against a variant of the value.
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'monthoverview'; RowKey = 'current'
            TagBudgetsJson = (ConvertTo-Json -Compress -Depth 4 -InputObject @([PSCustomObject]@{ Name = 'cc-budget'; Scope = "/subscriptions/$subA"; ScopeName = 'Payments'; Amount = 1000.0; Currency = 'EUR'
                TimeGrain = 'Monthly'; SpentAmount = 700.0; ForecastAmount = 1200.0; TagFilters = @([PSCustomObject]@{ key = 'costcenter'; values = @('cc100') }); ExtraFilters = $false })) }

        & (Join-Path $fa 'SyncAllocation-Timer/run.ps1') -Timer $null *> $null
        $cov = ([string](Read-Allocation).meta.CoverageJson | ConvertFrom-Json).owner
        Assert-True ($cov -gt 0 -and $cov -lt 100) "owner tag coverage: $cov"

        $body = Read-Body (Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = $mk })
        Assert-Equal $mk $body.month 'a complete month on request'
        Assert-True (-not $body.partial) 'not partial'
        $trend = $body.trend
        $days = [datetime]::DaysInMonth($stmtMonth.Year, $stmtMonth.Month)
        $fmt = { param($a) (@($a) | ForEach-Object { if ($null -eq $_) { '-' } else { $_ } }) -join ',' }
        if ($monthStart -ne $stmtMonth) {
            Assert-Equal (@($stmtMonth.AddMonths(-2).ToString('yyyy-MM'), $stmtMonth.AddMonths(-1).ToString('yyyy-MM'), $mk, $cur) -join ',') ($trend.months -join ',') 'complete months and this month so far, oldest first'
            Assert-Equal "200,100,$(10.0 * $days),-" (& $fmt $trend.series.alice) 'older ''Alice'' lines up with ''alice''; no whole-month total for this month'
            Assert-Equal $settled.Day $trend.throughDay 'same days: to the settled day'
            Assert-Equal $cur $trend.partialMonth 'the current month'
            $pm = $stmtMonth.AddMonths(-1); $n = $settled.Day
            $exp = @('-', (10.0 * [Math]::Min($n, [datetime]::DaysInMonth($pm.Year, $pm.Month))), (10.0 * [Math]::Min($n, $days)), (10.0 * $n))
            Assert-Equal ($exp -join ',') (& $fmt $trend.sameDays.alice) 'days 1..N in every month with a daily series; none for a month stored before them'
            $one = Read-Body (Invoke-HttpFunction -Name 'GetStatement' -Query @{ value = 'alice' })
            Assert-Equal ($exp -join ',') (& $fmt $one.statement.trendSameDays) 'on the statement too'
        } else {
            Assert-Equal "200,100,$(10.0 * $days)" (& $fmt $trend.series.alice) 'older ''Alice'' lines up with ''alice'''
        }
        if ($monthStart -ne $stmtMonth) {
            Assert-Equal $cur @($body.months)[0].month 'this month so far is listed first'
            Assert-True @($body.months)[0].partial 'and marked partial'
            $now = Read-Body (Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = $cur; dimension = 'tag:costcenter' })
            Assert-True $now.partial 'partial month served'
            Assert-Equal $settled.ToString('yyyy-MM-dd') $now.throughDate 'through the settled day'
            $cc = @($now.rows | Where-Object key -ceq 'CC-100')[0]
            Assert-True ($null -ne $cc) "the alias gives 'CC-100': $(($now.rows | ForEach-Object key) -join ',')"
            Assert-Equal 'cc-budget' @($cc.budgets)[0].name 'the tag budget sits on its cost centre'
            Assert-Equal 70.0 @($cc.budgets)[0].usedPct 'used'
            Assert-True @($cc.budgets)[0].projectedToExceed 'projected to exceed'
            $old = Read-Body (Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = $mk; dimension = 'tag:costcenter' })
            Assert-Equal 0 @(@($old.rows | Where-Object key -ceq 'CC-100')[0].budgets).Count 'no budget on a complete month'
            $un = (Read-Body (Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = $cur; value = '(untagged)' })).statement
            Assert-Equal 'rg-data' @($un.untaggedGroups)[0].name 'the group to tag'
        }
    } finally { Remove-Item function:global:Remove-TableEntityBatch -ErrorAction SilentlyContinue }
}
Test-That 'statement trend: spend per value cumulative by day, as the statements resolve it' {
    $vp = $vmPay.ToLowerInvariant(); $ld = $lakeData.ToLowerInvariant()
    $idx = @{
        $vp = @{ Tags = @{ owner = 'alice' }; Exists = $true }
        $ld = @{ Tags = @{}; Exists = $true }
    }
    $daily = @{ $vp = [double[]]@(1, 2, 3); $ld = [double[]]@(5, 0, 5); '/subscriptions/x/resourcegroups/gone/providers/a/b/c' = [double[]]@(0, 1, 0) }
    $s = Measure-AllocationDailySeries -PerResourceDaily $daily -Index $idx -TagKeys @('owner') -Days 3
    Assert-Equal '1,3,6' (@($s['tag:owner']['alice']) -join ',') 'cumulative'
    Assert-Equal '5,5,10' (@($s['tag:owner']['(untagged)']) -join ',') 'untagged apart'
    Assert-Equal '0,1,1' (@($s['tag:owner']['(resource no longer exists)']) -join ',') 'deleted apart'
    $two = Measure-AllocationDailySeries -PerResourceDaily $daily -Index $idx -TagKeys @('owner') -Days 2
    Assert-Equal 2 @($two['tag:owner']['alice']).Count 'only the days asked for (the current month so far)'
}
Test-That 'statement trend: older months backfilled from snapshots, one per night, oldest first' {
    Reset-State
    Set-Setting @{ AllocationTagKeys = 'Owner' }
    function global:Remove-TableEntityBatch { param($Table, $Entities, $Token)
        foreach ($e in @($Entities)) { $null = $global:Store[$Table].Remove("$($e.PartitionKey)|$($e.RowKey)") }; @($Entities).Count }
    try {
        $settled = Get-RollingWindowEndDate
        $monthStart = Get-UtcMonthStart -Date $settled
        $stmtPrev = (Get-BriefTargetMonth).AddMonths(-1)
        $loopStart = if ($stmtPrev -lt $monthStart.AddMonths(-1)) { $stmtPrev } else { $monthStart.AddMonths(-1) }
        $older = @($loopStart.AddMonths(-2), $loopStart.AddMonths(-1))
        for ($d = $older[0]; $d -le $settled; $d = $d.AddDays(1)) {
            Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $d.ToString('yyyy-MM-dd'); RowKey = (Get-ShortHash -Value $vmPay)
                ResourceId = $vmPay; Scope = (Get-RowSubscriptionId -Row $vmPay); Meter = 'Virtual Machines'; CostUsd = 10.0 }
        }
        $months = { @($global:Store['CostSummary'].Values | Where-Object { $_.PartitionKey -eq 'statement-daily' } | ForEach-Object { [string]$_.Month } | Select-Object -Unique | Sort-Object) }
        & (Join-Path $fa 'SyncAllocation-Timer/run.ps1') -Timer $null *> $null
        $m1 = & $months
        Assert-True ($m1 -contains $older[0].ToString('yyyy-MM')) "the oldest missing month first: $($m1 -join ',')"
        Assert-True ($m1 -notcontains $older[1].ToString('yyyy-MM')) 'only one per night'
        Assert-True ($m1 -contains $monthStart.ToString('yyyy-MM')) 'the current month from the nightly pass'
        & (Join-Path $fa 'SyncAllocation-Timer/run.ps1') -Timer $null *> $null
        Assert-True ((& $months) -contains $older[1].ToString('yyyy-MM')) 'the next one the night after'
        $row = @($global:Store['CostSummary'].Values | Where-Object { $_.PartitionKey -eq 'statement-daily' -and $_.Month -eq $older[0].ToString('yyyy-MM') })[0]
        $dim = [datetime]::DaysInMonth($older[0].Year, $older[0].Month)
        Assert-True $row.Complete 'a whole month'
        $alice = @(([string]$row.SeriesJson | ConvertFrom-Json).alice)
        Assert-Equal (10.0 * $dim) $alice[-1] 'its total'
    } finally { Remove-Item function:global:Remove-TableEntityBatch -ErrorAction SilentlyContinue }
}

Write-Host "`nConfigured allocation tags"
Test-That 'tag keys come from the deploy setting unless saved in the portal; labels as written' {
    Reset-State
    $env:ALLOCATION_TAG_KEYS = 'ServiceLead, ProjectName, CostCenter, Environment'
    try {
        Assert-Equal 'servicelead,projectname,costcenter,environment' ((Get-AllocationTagKeys -StorageToken 't') -join ',') 'from the app setting'
        $l = Get-AllocationTagLabels -StorageToken 't'
        Assert-Equal 'Service lead' $l['servicelead'] 'camelCase split'
        Assert-Equal 'Project name' $l['projectname'] 'second'
        $cfg = Read-Body (Invoke-HttpFunction -Name 'GetPortalConfig')
        Assert-Equal 'Service lead' $cfg.allocationTagLabels.servicelead 'served to the portal'
        Set-Setting @{ AllocationTagKeys = 'Owner' }
        Assert-Equal 'owner' ((Get-AllocationTagKeys -StorageToken 't') -join ',') 'a saved setting wins'
    } finally { $env:ALLOCATION_TAG_KEYS = '' }
}
Test-That 'the owner on findings and in the brief is the first configured tag' {
    Reset-State
    $env:ALLOCATION_TAG_KEYS = 'ServiceLead, ProjectName'
    try {
        $row = [PSCustomObject]@{ AllocationJson = '{"servicelead":"jane","projectname":"atlas","owner":"someone-else"}' }
        Assert-Equal 'jane' (Get-BriefOwner $row -Key (@(Get-AllocationTagKeys -StorageToken 't')[0])) 'first key'
        Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings-meta'; RowKey = 'latest'; LatestRunId = 'r1' }
        Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = 'aaaaaaaaaaaaaaaa'; RunId = 'r1'; Category = 'orphaned'; Tier = 'certain'
            ResourceId = $vmPay; Title = 'x'; Detail = 'x'; EstMonthlySavingsUsd = 10.0; AllocationJson = $row.AllocationJson }
        Assert-Equal 'jane' @((Get-BriefSavings -Token 't').items)[0].owner 'brief savings carry the owner'
        Assert-True ((Get-OwnerTags @{ ServiceLead = 'jane'; Colour = 'blue' }).Contains('ServiceLead')) 'evidence treats it as owner-like'
    } finally { $env:ALLOCATION_TAG_KEYS = '' }
}
Test-That 'dropped tags leave the tabs; resource-group budgets land on the group''s tag values' {
    Reset-State
    Set-Setting @{ AllocationTagKeys = 'ServiceLead, ProjectName' }
    function global:Remove-TableEntityBatch { param($Table, $Entities, $Token)
        foreach ($e in @($Entities)) { $null = $global:Store[$Table].Remove("$($e.PartitionKey)|$($e.RowKey)") }; @($Entities).Count }
    $prev = $global:ExtraRest
    # Resource Graph: rg-payments carries ServiceLead and ProjectName; the resources inherit.
    $global:ExtraRest = {
        param($Method, $Uri, $Body)
        if ($Uri -notlike '*Microsoft.ResourceGraph/resources*') { return $null }
        $q = [string](($Body | ConvertFrom-Json).query)
        $data = if ($q -match 'resourcecontainers') {
            @([PSCustomObject]@{ id = $rgPay.ToLower(); tags = [PSCustomObject]@{ ServiceLead = 'Jane'; ProjectName = 'Atlas' } }
              [PSCustomObject]@{ id = $rgData.ToLower(); tags = $null })
        } else {
            @([PSCustomObject]@{ id = $vmPay.ToLower(); tags = $null }; [PSCustomObject]@{ id = $lakeData.ToLower(); tags = $null })
        }
        return [PSCustomObject]@{ data = $data; '$skipToken' = $null }
    }
    try {
        $settled = Get-RollingWindowEndDate
        $stmtMonth = Get-BriefTargetMonth
        $monthStart = Get-UtcMonthStart -Date $settled
        for ($d = $stmtMonth.AddMonths(-1); $d -le $settled; $d = $d.AddDays(1)) {
            foreach ($x in @(@{ id = $vmPay; c = 10.0 }, @{ id = $lakeData; c = 5.0 })) {
                Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $d.ToString('yyyy-MM-dd'); RowKey = (Get-ShortHash -Value $x.id)
                    ResourceId = $x.id; Scope = (Get-RowSubscriptionId -Row $x.id); Meter = 'VM'; CostUsd = $x.c }
            }
            Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = $d.ToString('yyyy-MM-dd'); Date = $d.ToString('yyyy-MM-dd'); TotalUsd = 20.0 }
        }
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'monthoverview'; RowKey = 'current'
            RgBudgetsJson = (ConvertTo-Json -Compress -Depth 4 -InputObject @([PSCustomObject]@{ Name = 'atlas-rg'; Scope = $rgPay.ToLower(); ScopeName = 'rg-payments'; ResourceGroupId = $rgPay.ToLower()
                Currency = 'EUR'; TimeGrain = 'Monthly'; Amount = 2000.0; SpentAmount = 500.0; ForecastAmount = 1500.0; TagFilters = @(); ExtraFilters = $false })) }
        # Left over from when the tags were owner / application.
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'allocation'; RowKey = 'tag:owner'; RowsJson = '[]' }
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'statement'; RowKey = "$($stmtMonth.ToString('yyyy-MM'))|tag:application|index"; Month = $stmtMonth.ToString('yyyy-MM'); Dimension = 'tag:application'; RowsJson = '[]' }

        & (Join-Path $fa 'SyncAllocation-Timer/run.ps1') -Timer $null *> $null
        Assert-Equal 'resourceGroup,tag:projectname,tag:servicelead' (Read-Allocation).dims 'no owner dimension'
        Assert-True (-not $global:Store['CostSummary'].ContainsKey('allocation|tag:owner')) 'the dropped dimension is removed'
        $st = Read-Body (Invoke-HttpFunction -Name 'GetStatement')
        Assert-Equal 'tag:servicelead,tag:projectname' ($st.dimensions -join ',') 'no application tab'
        Assert-Equal 'Service lead' $st.tagLabels.servicelead 'labelled'
        if ($monthStart -ne $stmtMonth) {
            foreach ($dim in @('tag:servicelead', 'tag:projectname')) {
                $now = Read-Body (Invoke-HttpFunction -Name 'GetStatement' -Query @{ month = $monthStart.ToString('yyyy-MM'); dimension = $dim })
                $r = @($now.rows | Where-Object { -not $_.separate })[0]
                Assert-Equal 'atlas-rg' @($r.budgets)[0].name "the group's budget on $dim ($($r.key))"
                Assert-Equal 25.0 @($r.budgets)[0].usedPct 'used'
                Assert-Equal 'resource group rg-payments' @($r.budgets)[0].scopeName 'says where the budget is set'
            }
        }
    } finally { $global:ExtraRest = $prev; Remove-Item function:global:Remove-TableEntityBatch -ErrorAction SilentlyContinue }
}
Test-That 'findings carry their owner through the API' {
    Reset-State
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings-meta'; RowKey = 'latest'; LatestRunId = 'r1' }
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = 'aaaaaaaaaaaaaaaa'; RunId = 'r1'; Category = 'orphaned'; Tier = 'certain'
        ResourceId = $vmPay; Title = 'x'; Detail = 'x'; EstMonthlySavingsUsd = 10.0; AllocationJson = '{"owner":"alice","resourceGroup":"rg-payments"}' }
    $f = @((Read-Body (Invoke-HttpFunction -Name 'GetSavings')).findings)[0]
    Assert-Equal 'alice' $f.allocation.owner 'owner'
}
Test-That 'allocation tag keys are a validated PATCH setting' {
    Reset-State
    Assert-Equal 400 ([int](Invoke-HttpFunction -Name 'SavePortalConfig' -Body ([PSCustomObject]@{ allocationTagKeys = @('a', 'b', 'c', 'd', 'e', 'f', 'g') })).StatusCode) 'too many'
    Assert-Equal 200 ([int](Invoke-HttpFunction -Name 'SavePortalConfig' -Body ([PSCustomObject]@{ allocationTagKeys = 'Owner, Team' })).StatusCode) 'ok'
    Assert-Equal 'owner,team' ((Read-Body (Invoke-HttpFunction -Name 'GetPortalConfig')).allocationTagKeys -join ',') 'normalised on read'
}

Write-Host "`nSavings levers"
function New-DaySeries { param([double]$Weekday, [double]$Weekend, [int]$Days = 14)
    $end = [datetime]::UtcNow.Date
    @(for ($i = $Days - 1; $i -ge 0; $i--) {
        $d = $end.AddDays(-$i)
        $usd = if ($d.DayOfWeek -in @([System.DayOfWeek]::Saturday, [System.DayOfWeek]::Sunday)) { $Weekend } else { $Weekday }
        [PSCustomObject]@{ Date = $d.ToString('yyyy-MM-dd'); Usd = $usd }
    })
}
Test-That 'non-production is read from the environment value; preprod is left alone' {
    foreach ($v in @('dev', 'Test', 'qa-2', 'UAT', 'sandbox', 'non-prod')) { Assert-True (Test-NonProductionValue $v) $v }
    foreach ($v in @('prod', 'production', 'preprod', '', $null)) { Assert-True (-not (Test-NonProductionValue $v)) "not: $v" }
    Assert-True (Test-RunsAroundTheClock -Days (New-DaySeries 10 10)) 'runs every day'
    Assert-True (-not (Test-RunsAroundTheClock -Days (New-DaySeries 10 1))) 'stops at weekends'
    Assert-True (-not (Test-RunsAroundTheClock -Days (New-DaySeries 10 10 -Days 8))) 'too little history'
}
$vmDev = "/subscriptions/$subA/resourcegroups/rg-dev/providers/microsoft.compute/virtualmachines/vm-dev"
$vmOff = "/subscriptions/$subA/resourcegroups/rg-dev/providers/microsoft.compute/virtualmachines/vm-off"
$vmProd = "/subscriptions/$subA/resourcegroups/rg-prod/providers/microsoft.compute/virtualmachines/vm-prod"
$stCold = "/subscriptions/$subA/resourcegroups/rg-data/providers/microsoft.storage/storageaccounts/stcold"
$law = "/subscriptions/$subA/resourcegroups/rg-mon/providers/microsoft.operationalinsights/workspaces/law-central"
$global:ExtraRest = {
    param($Method, $Uri, $Body)
    if ($Uri -like '*Microsoft.ResourceGraph/resources*') {
        $q = [string](($Body | ConvertFrom-Json).query)
        $data = if ($q -match 'virtualmachines') {
            @([PSCustomObject]@{ id = $vmDev; name = 'vm-dev'; location = 'westeurope'; vmSize = 'Standard_D4s_v5'; powerState = 'PowerState/running' }
              [PSCustomObject]@{ id = $vmOff; name = 'vm-off'; location = 'westeurope'; vmSize = 'Standard_D4s_v5'; powerState = 'PowerState/deallocated' }
              [PSCustomObject]@{ id = $vmProd; name = 'vm-prod'; location = 'westeurope'; vmSize = 'Standard_D4s_v5'; powerState = 'PowerState/running' })
        } elseif ($q -match 'storageaccounts') {
            @([PSCustomObject]@{ id = $stCold; name = 'stcold'; location = 'westeurope'; sku = 'Standard_LRS' })
        } elseif ($q -match 'workspaces') {
            @([PSCustomObject]@{ id = $law; name = 'law-central'; location = 'westeurope'; subscriptionId = $subA; skuName = 'PerGB2018'; level = 0 })
        } else { @() }
        return [PSCustomObject]@{ data = $data; '$skipToken' = $null }
    }
    if ($Uri -like '*stcold/providers/microsoft.insights/metrics*') {
        $cap = 2.0 * [Math]::Pow(1024, 4)   # 2 TiB
        return [PSCustomObject]@{ value = @(
            [PSCustomObject]@{ name = [PSCustomObject]@{ value = 'UsedCapacity' }; timeseries = @([PSCustomObject]@{ data = @(1..48 | ForEach-Object { [PSCustomObject]@{ average = $cap } }) }) }
            [PSCustomObject]@{ name = [PSCustomObject]@{ value = 'Transactions' }; timeseries = @([PSCustomObject]@{ data = @([PSCustomObject]@{ total = 500.0 }) }) }
        ) }
    }
    if ($Uri -like '*prices.azure.com*') {
        $f = [uri]::UnescapeDataString($Uri)
        $items = if ($f -match "meterName eq 'Hot LRS Data Stored'") { @([PSCustomObject]@{ retailPrice = 0.0184; tierMinimumUnits = 0; productName = 'General Block Blob v2'; meterName = 'Hot LRS Data Stored' }) }
                 elseif ($f -match "meterName eq 'Cool LRS Data Stored'") { @([PSCustomObject]@{ retailPrice = 0.01; tierMinimumUnits = 0; productName = 'General Block Blob v2'; meterName = 'Cool LRS Data Stored' }) }
                 elseif ($f -match "serviceName eq 'Log Analytics'") {
                     @([PSCustomObject]@{ retailPrice = 2.30; meterName = 'Analytics Logs Data Ingestion' }
                       [PSCustomObject]@{ retailPrice = 196.0; meterName = '100 GB Commitment Tier Capacity Reservation' }
                       [PSCustomObject]@{ retailPrice = 368.0; meterName = '200 GB Commitment Tier Capacity Reservation' })
                 } else { @() }
        return [PSCustomObject]@{ Items = $items; NextPageLink = $null }
    }
    return $null
}
Test-That 'a non-production VM running around the clock is priced at its own cost outside working hours' {
    Reset-State
    $costMap = @{
        $vmDev  = [PSCustomObject]@{ Days = (New-DaySeries 10 10); AvgDaily = 10.0 }
        $vmOff  = [PSCustomObject]@{ Days = (New-DaySeries 10 10); AvgDaily = 10.0 }
        $vmProd = [PSCustomObject]@{ Days = (New-DaySeries 10 10); AvgDaily = 10.0 }
    }
    $idx = @{
        $vmDev  = @{ Tags = @{ environment = 'Dev' } }
        $vmOff  = @{ Tags = @{ environment = 'dev' } }
        $vmProd = @{ Tags = @{ environment = 'prod' } }
    }
    $f = @(Get-NonProdAlwaysOnVms -CostMap $costMap -MgmtToken 't' -SubscriptionIds @($subA) -TagIndex $idx)
    Assert-Equal 1 $f.Count 'only the running dev VM'
    Assert-Equal $vmDev $f[0].ResourceId 'which one'
    Assert-Equal ([Math]::Round(304.0 * (108 / 168), 2)) $f[0].EstMonthlySavingsUsd '108 of 168 hours of its own cost'
    Assert-Equal 'likely' $f[0].Tier 'tier'
    Assert-Equal 0 @(Get-NonProdAlwaysOnVms -CostMap $costMap -MgmtToken 't' -SubscriptionIds @($subA) -TagIndex $idx -CoveredResourceIds @($vmDev)).Count 'a committed VM saves nothing by stopping'
}
Test-That 'a large, untouched Hot storage account is priced at the Hot-Cool difference' {
    Reset-State
    $costMap = @{ $stCold = [PSCustomObject]@{ Days = @(); AvgDaily = 3.0 } }
    $f = @(Get-HotStorageCandidates -CostMap $costMap -MgmtToken 't' -SubscriptionIds @($subA))
    Assert-Equal 1 $f.Count 'found'
    # 2048 GiB x (0.0184 - 0.01) = 17.20, but never more than the account costs (3 x 30.4 = 91.2).
    Assert-Equal 17.2 $f[0].EstMonthlySavingsUsd 'saving'
    Assert-Equal 'likely' $f[0].Tier 'nearly untouched and over 1 TiB'
}
Test-That 'Log Analytics: the cheapest tier is chosen, overage priced at the tier rate' {
    $m = Measure-LogAnalyticsTierCost -DailyGb 150 -Prices @{ PerGb = 2.30; Tiers = @{ 100 = 196.0; 200 = 368.0 } }
    Assert-Equal 100 $m.Best.Level 'the 100 GB tier'
    Assert-Equal 294.0 $m.Best.Daily '196 + 50 GB x 1.96'
    Assert-Equal 345.0 $m.Current.Daily 'pay-as-you-go now'
    Reset-State
    $global:CostResponder = { param($b, $u) New-CostResponse -Columns @('UsageQuantity', 'ResourceId', 'Meter') -Rows @(
        , @(4200.0, $law, 'Analytics Logs Data Ingestion')
        , @(300.0, $law, 'Basic Logs Data Ingestion')) }
    $f = @(Get-LogAnalyticsTierFindings -MgmtToken 't' -SubscriptionIds @($subA))
    Assert-Equal 1 $f.Count 'found'
    Assert-Equal 140.0 $f[0].Evidence.dailyGb 'basic logs left out: 4200 GB / 30 days'
    Assert-Equal ([Math]::Round((140 * 2.30 - (196 + 40 * 1.96)) * 30.4, 2)) $f[0].EstMonthlySavingsUsd 'saving'
}
Test-That 'unused reservation and savings-plan hours become a finding each' {
    Reset-State
    $global:CostResponder = { param($b, $u) New-CostResponse -Columns @('CostUSD', 'BenefitId', 'BenefitName') -Rows @(
        , @(300.0, '/providers/Microsoft.Capacity/reservationOrders/o1/reservations/r1', 'D4s v5 west')
        , @(3.0, '/providers/Microsoft.BillingBenefits/savingsPlanOrders/o2/savingsPlans/s1', 'tiny')) }
    $u = Get-UnusedCommitmentCost -MgmtToken 't' -Scopes @('/providers/Microsoft.Management/managementGroups/mg') -SubscriptionIds @($subA)
    $body = $global:CostQueryBodies[0]
    Assert-Equal 'AmortizedCost' $body.type 'unused hours only exist in amortized data'
    Assert-Equal 2 @($body.dataset.filter.and).Count 'charge type + subscription filter'
    $f = @(ConvertTo-UnusedCommitmentFindings -Unused $u)
    Assert-Equal 1 $f.Count 'the tiny one is under the floor'
    Assert-Equal 304.0 $f[0].EstMonthlySavingsUsd '300 over 30 days = 304 a month'
    Assert-Equal 'reservation' $f[0].Evidence.kind 'kind'
}
Test-That 'one saving per resource in the totals' {
    $a = [PSCustomObject]@{ ResourceId = $vmDev; Tier = 'likely'; EstMonthlySavingsUsd = 100.0; Title = 'Resize'; Detail = 'r' }
    $b = [PSCustomObject]@{ ResourceId = $vmDev.ToUpper(); Tier = 'likely'; EstMonthlySavingsUsd = 195.0; Title = 'Stop at night'; Detail = 's' }
    $c = [PSCustomObject]@{ ResourceId = $vmProd; Tier = 'likely'; EstMonthlySavingsUsd = 50.0; Title = 'x'; Detail = 'x' }
    $out = @(Resolve-OverlappingSavings -Findings @($a, $b, $c))
    Assert-Equal 'indicative' $a.Tier 'the smaller overlapping one is shown, not counted'
    Assert-True ($a.Detail -like '*Stop at night*') 'and says which one is'
    Assert-Equal 'likely' $b.Tier 'the larger stays'
    Assert-Equal 'likely' $c.Tier 'other resources untouched'
}
Test-That 'commitment inventory: utilisation and expiry; a missing role is a note, not a failure' {
    Reset-State
    $exp = [datetime]::UtcNow.Date.AddDays(40).ToString('yyyy-MM-ddT00:00:00Z')
    $saved = $global:ExtraRest
    $global:ExtraRest = {
        param($Method, $Uri, $Body)
        if ($Uri -like '*Microsoft.Capacity/reservations*') {
            return [PSCustomObject]@{ value = @([PSCustomObject]@{ id = '/providers/Microsoft.Capacity/reservationOrders/o1/reservations/r1'; name = 'r1'
                properties = [PSCustomObject]@{ displayName = 'VM D4s v5'; skuDescription = 'Standard_D4s_v5'; quantity = 3; term = 'P1Y'; expiryDateTime = $exp; renew = $false; appliedScopeType = 'Single'; provisioningState = 'Succeeded'
                    utilization = [PSCustomObject]@{ aggregates = @([PSCustomObject]@{ grain = 7; value = 55.5 }, [PSCustomObject]@{ grain = 30; value = 61.0 }) } } }
                [PSCustomObject]@{ id = '/providers/Microsoft.Capacity/reservationOrders/o9/reservations/r9'; name = 'r9'
                    properties = [PSCustomObject]@{ displayName = 'Old D2s'; skuDescription = 'Standard_D2s_v5'; quantity = 1; term = 'P1Y'; provisioningState = 'Cancelled' } }
                [PSCustomObject]@{ id = '/providers/Microsoft.Capacity/reservationOrders/o8/reservations/r8'; name = 'r8'
                    properties = [PSCustomObject]@{ displayName = 'Failed buy'; provisioningState = 'Failed' } }); nextLink = $null }
        }
        if ($Uri -like '*Microsoft.BillingBenefits/savingsPlans*') { throw 'Response status code does not indicate success: 403 (Forbidden).' }
        return $null
    }
    try {
        $inv = Get-CommitmentInventory -MgmtToken 't'
        Assert-Equal 2 @($inv.Items).Count 'the active and the cancelled one; a failed purchase is left out'
        Assert-Equal 'active' $inv.Items[0].status 'active first'
        Assert-Equal 'cancelled' $inv.Items[1].status 'cancelled kept, with its status'
        Assert-True (-not $inv.Items[1].expiringSoon) 'an ended one is never "ending soon"'
        Assert-Equal 61.0 $inv.Items[0].utilisation30d '30-day utilisation'
        Assert-True $inv.Items[0].expiringSoon 'expires within 60 days'
        Assert-True ((@($inv.Notes) -join ' ') -like '*Savings plan Reader*') 'says which role is missing'
    } finally { $global:ExtraRest = $saved }
}
Test-That 'purchase recommendations: monthly saving and the committed usage''s share of pay-as-you-go' {
    Reset-State
    $saved = $global:ExtraRest
    $global:ExtraRest = {
        param($Method, $Uri, $Body)
        if ($Uri -like '*reservationRecommendations*') {
            return [PSCustomObject]@{ value = @([PSCustomObject]@{ location = 'westeurope'; properties = [PSCustomObject]@{
                resourceType = 'VirtualMachines'; normalizedSize = 'Standard_D2s_v5'; term = 'P1Y'; recommendedQuantity = 4; lookBackPeriod = 'Last30Days'
                costWithNoReservedInstances = 1000.0; totalCostWithReservedInstances = 640.0; netSavings = 360.0 } }); nextLink = $null }
        }
        if ($Uri -like '*benefitRecommendations*') {
            if ($Uri -like "*P3Y*") { return [PSCustomObject]@{ value = @() } }
            return [PSCustomObject]@{ value = @([PSCustomObject]@{ properties = [PSCustomObject]@{ term = 'P1Y'; lookBackPeriod = 'Last30Days'; costWithoutBenefit = 2000.0
                recommendationDetails = [PSCustomObject]@{ savingsAmount = 300.0; totalCost = 1700.0; commitmentAmount = 2.5; coveragePercentage = 80 } } }) }
        }
        return $null
    }
    try {
        $r = Get-CommitmentRecommendations -MgmtToken 't' -SubscriptionIds @($subA) -SubscriptionNames @{ $subA = 'Payments' }
        $ri = @($r.Items | Where-Object kind -eq 'reservation')[0]
        Assert-Equal 364.8 $ri.monthlySavingsUsd '360 over 30 days'
        Assert-Equal 64.0 $ri.effectiveCostPct 'costs 64% of pay-as-you-go'
        $sp = @($r.Items | Where-Object kind -eq 'savings plan')[0]
        Assert-Equal 2.5 $sp.hourlyCommitment 'hourly commitment'
        Assert-Equal 85.0 $sp.effectiveCostPct '1700 of 2000'
    } finally { $global:ExtraRest = $saved }
}

Test-That 'nightly commitments: inventory, notes and recommendations served, recommendations scoped' {
    Reset-State
    $saved = $global:ExtraRest
    $global:ExtraRest = {
        param($Method, $Uri, $Body)
        if ($Uri -like '*Microsoft.Capacity/reservations*') { return [PSCustomObject]@{ value = @(); nextLink = $null } }
        if ($Uri -like '*Microsoft.BillingBenefits/savingsPlans*') { throw '403 Forbidden' }
        if ($Uri -like '*reservationRecommendations*') {
            $sid = if ($Uri -like "*$subB*") { 'b' } else { 'a' }
            return [PSCustomObject]@{ value = @([PSCustomObject]@{ location = 'westeurope'; properties = [PSCustomObject]@{ resourceType = 'VirtualMachines'; normalizedSize = "size-$sid"; term = 'P1Y'
                recommendedQuantity = 1; lookBackPeriod = 'Last30Days'; costWithNoReservedInstances = 100.0; totalCostWithReservedInstances = 70.0; netSavings = 30.0 } }); nextLink = $null }
        }
        if ($Uri -like '*benefitRecommendations*') { return [PSCustomObject]@{ value = @() } }
        return $null
    }
    try {
        & (Join-Path $fa 'SyncCommitments-Timer/run.ps1') -Timer $null *> $null
        $body = Read-Body (Invoke-HttpFunction -Name 'GetCommitments')
        Assert-True $body.ready 'stored'
        Assert-Equal 2 @($body.recommendations).Count 'one per subscription'
        Assert-True ((@($body.notes) -join ' ') -like '*Savings plan Reader*') 'missing role reported'
        Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'settings'; RowKey = 'scope'; IncludedSubscriptionIds = $subA }
        $body = Read-Body (Invoke-HttpFunction -Name 'GetCommitments')
        Assert-Equal 1 @($body.recommendations).Count 'the excluded subscription''s recommendation is hidden'
    } finally { $global:ExtraRest = $saved }
}

Write-Host "`nReservations: which resources use each commitment"
$r1 = '/providers/Microsoft.Capacity/reservationOrders/o1/reservations/r1'
$r2 = '/providers/Microsoft.Capacity/reservationOrders/o2/reservations/r2'
$vmA1 = "/subscriptions/$subA/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-a1"
$vmA2 = "/subscriptions/$subA/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-a2"
$vmB1 = "/subscriptions/$subB/resourceGroups/rg-other/providers/Microsoft.Compute/virtualMachines/vm-b1"
# Usage query (charge type Usage, with the PricingModel filter) vs unused query (charge type only).
$commitmentResponder = {
    param($b, $u)
    $d = { param([int]$Ago) [int][datetime]::UtcNow.Date.AddDays(-$Ago).ToString('yyyyMMdd') }
    if ($b.dataset.filter.and) {
        return New-CostResponse -Columns @('CostUSD', 'UsageQuantity', 'UsageDate', 'BenefitId', 'ResourceId', 'Currency') -Rows @(
            , @(30.0, 24.0, (& $d 2), $r1, $vmA1, 'USD')
            , @(30.0, 24.0, (& $d 20), $r1, $vmA1, 'USD')
            , @(20.0, 24.0, (& $d 20), $r1, $vmB1, 'USD')
            , @(10.0, 12.0, (& $d 25), $r2, $vmA2, 'USD'))
    }
    # The name query (one row per commitment, no daily buckets).
    if ($b.dataset.granularity -eq 'None') {
        return New-CostResponse -Columns @('CostUSD', 'BenefitId', 'BenefitName', 'Currency') -Rows @(
            , @(80.0, $r1, 'E4s pool', 'USD')
            , @(10.0, $r2, 'D2s west', 'USD'))
    }
    return New-CostResponse -Columns @('CostUSD', 'UsageDate', 'BenefitId', 'BenefitName', 'Currency') -Rows @(
        , @(15.0, (& $d 3), $r2, 'D2s west', 'USD')
        , @(5.0, (& $d 20), $r2, 'D2s west', 'USD'))
}
Test-That 'commitment consumption: per-resource shares, 7- and 30-day totals, unused cost' {
    Reset-State
    $global:CostResponder = $commitmentResponder
    $c = Get-CommitmentConsumption -MgmtToken 't' -Scopes @('/providers/Microsoft.Management/managementGroups/mg')
    $body = $global:CostQueryBodies[0]
    Assert-Equal 'AmortizedCost' $body.type 'amortized cost carries the per-resource attribution'
    Assert-Equal 'Daily' $body.dataset.granularity 'daily, for the 7-day figures'
    Assert-Equal 'PricingModel' $body.dataset.filter.and[0].dimensions.name 'reservation / savings plan usage only'
    Assert-Equal 2 @($body.dataset.grouping).Count 'two groupings, the API maximum'
    $a = @($c.Items | Where-Object id -eq $r1.ToLowerInvariant())[0]
    Assert-Equal 80.0 $a.used30dUsd 'all usage of r1'
    Assert-Equal 30.0 $a.used7dUsd 'only the recent day'
    Assert-Equal 2 $a.resourceCount 'two resources'
    Assert-Equal $vmA1.ToLowerInvariant() $a.resources[0].resourceId 'largest consumer first'
    Assert-Equal 75.0 $a.resources[0].sharePct '60 of 80'
    Assert-Equal 2 $a.resources[0].days 'used on two days'
    Assert-Equal $subB $a.resources[1].subscriptionId 'subscription from the resource id'
    $b = @($c.Items | Where-Object id -eq $r2.ToLowerInvariant())[0]
    Assert-Equal 20.0 $b.unused30dUsd 'unused over 30 days'
    Assert-Equal 15.0 $b.unused7dUsd 'unused over 7 days'
    Assert-Equal 'D2s west' $b.name 'name from cost data'
    Assert-Equal 0.0 $b.used7dUsd 'nothing used r2 this week'
    Assert-Equal 'E4s pool' $a.name 'a fully used reservation (no unused hours) is named too'
}
Test-That 'commitment consumption: a tenant that reports 0 for covered cost is judged on usage hours' {
    Reset-State
    $global:CostResponder = {
        param($b, $u)
        $d = { param([int]$Ago) [int][datetime]::UtcNow.Date.AddDays(-$Ago).ToString('yyyyMMdd') }
        if ($b.dataset.filter.and) {
            return New-CostResponse -Columns @('CostUSD', 'UsageQuantity', 'UsageDate', 'BenefitId', 'ResourceId', 'Currency') -Rows @(
                , @(0.0, 24.0, (& $d 2), $r1, $vmA1, 'DKK')
                , @(0.0, 72.0, (& $d 20), $r1, $vmA2, 'DKK'))
        }
        return New-CostResponse -Columns @('CostUSD', 'BenefitId', 'BenefitName', 'Currency') -Rows @()
    }
    $c = Get-CommitmentConsumption -MgmtToken 't' -Scopes @("/subscriptions/$subA")
    $a = @($c.Items | Where-Object id -eq $r1.ToLowerInvariant())[0]
    Assert-True $a.costHidden 'cost hidden'
    Assert-Equal 24.0 $a.quantity7d 'used this week, by hours'
    Assert-Equal 96.0 $a.quantity30d 'hours over 30 days'
    Assert-Equal $vmA2.ToLowerInvariant() $a.resources[0].resourceId 'largest by hours first'
    Assert-Equal 75.0 $a.resources[0].sharePct 'share by hours (72 of 96)'
}
Test-That 'commitment display name: never a bare GUID' {
    $g1 = '0a1b2c3d-1111-2222-3333-444455556666'; $g2 = '9f8e7d6c-1111-2222-3333-444455556666'
    $id = "/providers/microsoft.capacity/reservationorders/$g1/reservations/$g2"
    Assert-Equal 'VM E4s v6' (Get-CommitmentDisplayName -Candidates @('VM E4s v6', 'other') -Id $id) 'first real name'
    Assert-Equal 'E4s pool' (Get-CommitmentDisplayName -Candidates @("$g1/$g2", 'E4s pool') -Id $id) 'an ARM order/reservation name is skipped'
    Assert-Equal 'E4s pool' (Get-CommitmentDisplayName -Candidates @('', $g2, 'E4s pool') -Id $id) 'empty and GUID skipped'
    Assert-Equal 'Reservation 9f8e7d6c' (Get-CommitmentDisplayName -Candidates @('', $null) -Id $id) 'kind + short id as the last resort'
    Assert-Equal 'Savings plan 9f8e7d6c' (Get-CommitmentDisplayName -Candidates @() -Id $id -Kind 'savings plan') 'savings plan'
}
Test-That 'Reservations page: inventory joined with usage; out-of-scope resources summed, not listed' {
    Reset-State
    $global:CostResponder = $commitmentResponder
    $savedScope = $env:COST_QUERY_SCOPE; $env:COST_QUERY_SCOPE = '/providers/Microsoft.Management/managementGroups/mg'
    $saved = $global:ExtraRest
    $global:ExtraRest = {
        param($Method, $Uri, $Body)
        if ($Uri -like '*Microsoft.Capacity/reservations*') {
            return [PSCustomObject]@{ value = @([PSCustomObject]@{ id = $r1; name = 'r1'; location = 'westeurope'
                properties = [PSCustomObject]@{ displayName = 'VM E4s v6'; skuDescription = 'Standard_E4s_v6'; quantity = 1; term = 'P3Y'; renew = $true; appliedScopeType = 'Shared'; provisioningState = 'Succeeded'
                    utilization = [PSCustomObject]@{ aggregates = @([PSCustomObject]@{ grain = 7; value = 100 }, [PSCustomObject]@{ grain = 30; value = 100 }) } } }
                [PSCustomObject]@{ id = '/providers/Microsoft.Capacity/reservationOrders/o3/reservations/r3'; name = 'r3'; location = 'westeurope'
                    properties = [PSCustomObject]@{ displayName = 'Cancelled B2s'; skuDescription = 'Standard_B2s'; quantity = 1; term = 'P1Y'; provisioningState = 'Cancelled' } }); nextLink = $null }
        }
        if ($Uri -like '*Microsoft.BillingBenefits/savingsPlans*') { return [PSCustomObject]@{ value = @(); nextLink = $null } }
        if ($Uri -like '*Recommendations*') { return [PSCustomObject]@{ value = @() } }
        return $null
    }
    try {
        & (Join-Path $fa 'SyncCommitments-Timer/run.ps1') -Timer $null *> $null
        $body = Read-Body (Invoke-HttpFunction -Name 'GetReservations')
        Assert-True $body.ready 'stored'
        Assert-Equal 3 @($body.items).Count 'the inventoried reservations and the one seen only in cost data'
        $a = @($body.items | Where-Object id -eq $r1.ToLowerInvariant())[0]
        Assert-Equal 'VM E4s v6' $a.name 'inventory name wins'
        Assert-Equal 'westeurope' $a.location 'region'
        Assert-Equal 2 @($a.resources).Count 'both resources while every subscription is in scope'
        $b = @($body.items | Where-Object id -eq $r2.ToLowerInvariant())[0]
        Assert-True (-not $b.inInventory) 'cost data only'
        Assert-Equal 'active' $a.status 'active'
        Assert-Equal 'unknown' $b.status 'seen only in cost data'
        Assert-Equal 'cancelled' @($body.items | Where-Object name -eq 'Cancelled B2s')[0].status 'a cancelled reservation is listed, with its status'
        Assert-Equal 0 @((Read-Body (Invoke-HttpFunction -Name 'GetCommitments')).inventory | Where-Object name -eq 'Cancelled B2s').Count 'but not on the Savings page''s panel'
        Assert-Equal 20.0 $b.unused30dUsd 'unused cost served'
        Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'settings'; RowKey = 'scope'; IncludedSubscriptionIds = $subA }
        $body = Read-Body (Invoke-HttpFunction -Name 'GetReservations')
        $a = @($body.items | Where-Object id -eq $r1.ToLowerInvariant())[0]
        Assert-Equal 1 @($a.resources).Count 'the excluded subscription''s VM is not listed'
        Assert-Equal 1 $a.otherSubscriptions.count 'but counted'
        Assert-Equal 25.0 $a.otherSubscriptions.sharePct 'with its share'
    } finally { $global:ExtraRest = $saved; $env:COST_QUERY_SCOPE = $savedScope }
}

Write-Host "`nOverview: one projection, owners on actions"
Test-That 'the brief carries Azure''s forecast instead of the run-rate, and owners on its items' {
    Reset-State
    $today = [datetime]::UtcNow.Date
    $settled = Get-BriefSettledDate -Today $today
    $ms = Get-UtcMonthStart -Date $settled
    for ($d = $ms.AddMonths(-1); $d -le $settled; $d = $d.AddDays(1)) {
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = $d.ToString('yyyy-MM-dd'); TotalUsd = 100.0 }
    }
    Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'monthoverview'; RowKey = 'current'; Month = $ms.ToString('yyyy-MM'); ForecastUsd = 3333.0 }
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings-meta'; RowKey = 'latest'; LatestRunId = 'r1' }
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = 'aaaaaaaaaaaaaaaa'; RunId = 'r1'; Category = 'orphaned'; Tier = 'certain'
        ResourceId = $vmPay; Title = 'Delete disk'; Detail = 'x'; EstMonthlySavingsUsd = 40.0; AllocationJson = '{"owner":"alice"}' }
    $p = Build-BriefPayload -Grain 'week' -Token 't' -Today $today
    if ($p.spend.kind -eq 'month-to-date') {
        Assert-Equal 3333.0 $p.spend.forecastUsd 'forecast in the payload'
        Assert-True ($null -eq $p.spend.runRateUsd) 'no second month-end figure'
    }
    Assert-Equal 'alice' @($p.savings.items)[0].owner 'owner on the saving'
}
Test-That 'a brief built before owners existed gets them filled in when served' {
    Reset-State
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = 'bbbbbbbbbbbbbbbb'; AllocationJson = '{"owner":"bob"}' }
    Set-TableEntity -Table 'CostSpikes' -Entity @{ PartitionKey = 'week|2026-09-15'; RowKey = '1111111111111111'; AllocationJson = '{"owner":"(untagged)"}' }
    $doc = @{ grain = 'week'; generatedAtIso = [datetime]::UtcNow.ToString('o'); aiStatus = 'not-configured'; grounded = $true; ai = $null
        payload = @{ spend = @{}; notes = @()
            changes = @{ periodType = 'week'; period = '2026-09-15'; total = 1; items = @(@{ id = 'C-1111111111111111'; findingId = '1111111111111111'; name = 'vm'; deltaUsd = 10 }) }
            savings = @{ totalMonthlyUsd = 40; count = 1; items = @(@{ id = 'S-bbbbbbbbbbbbbbbb'; source = 'analysis'; title = 'x'; monthlyUsd = 40 }) } } }
    Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'brief'; RowKey = 'week'; BriefJson = ($doc | ConvertTo-Json -Depth 10 -Compress) }
    $b = (Read-Body (Invoke-HttpFunction -Name 'GetBrief' -Query @{ grain = 'week' })).brief
    Assert-Equal 'bob' @($b.payload.savings.items)[0].owner 'owner looked up'
    Assert-Equal '' @($b.payload.changes.items)[0].owner 'untagged reads as no owner'
}


Write-Host ""
Write-Host "Feature tests: $($script:Passed) passed, $($script:Failed.Count) failed" -ForegroundColor $(if ($script:Failed.Count) { 'Red' } else { 'Green' })
if ($PassThru) { return [PSCustomObject]@{ Passed = $script:Passed; Failed = @($script:Failed) } }
if ($script:Failed.Count) { exit 1 }
