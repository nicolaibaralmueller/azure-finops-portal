# Offline tests for Setup/Set-SubscriptionScope.ps1. The Azure CLI is replaced by a PowerShell
# function named `az` (functions win over applications), backed by an in-memory table, so
# nothing reaches Azure. Run via Tests/Invoke-OfflineTests.ps1.

param([switch]$PassThru)

. (Join-Path $PSScriptRoot 'TestKit.ps1')

$script = Join-Path $root 'Setup/Set-SubscriptionScope.ps1'
$subA = $sub
$subB = '22222222-2222-3333-4444-555555555555'
$subC = '33333333-2222-3333-4444-555555555555'

$global:AzTables = @{}
$global:AzCalls = [System.Collections.Generic.List[string]]::new()
$global:AzLoginAllowed = $true

function global:az {
    $a = @($args | ForEach-Object { [string]$_ })
    $global:AzCalls.Add(($a -join ' '))
    $global:LASTEXITCODE = 0
    $opt = { param($name) $i = [array]::IndexOf($a, $name); if ($i -ge 0 -and $i + 1 -lt $a.Count) { $a[$i + 1] } else { $null } }
    $cmd = ($a[0..2] -join ' ')
    switch -Wildcard ($cmd) {
        'account show*' { if ((& $opt '--query') -eq 'user.name') { 'operator@contoso.com' } else { '{}' }; return }
        'account list*' { '[{"id":"' + $subA + '","name":"Production"}]'; return }
        'storage account list' { 'stportal'; return }
        'storage entity query' {
            if ((& $opt '--auth-mode') -eq 'login' -and -not $global:AzLoginAllowed) { $global:LASTEXITCODE = 1 }
            return
        }
        'storage entity show' {
            $t = $global:AzTables[(& $opt '--table-name')]
            $e = if ($t) { $t["$(& $opt '--partition-key')|$(& $opt '--row-key')"] } else { $null }
            if ($e) { $e | ConvertTo-Json -Compress } else { $global:LASTEXITCODE = 3 }
            return
        }
        'storage entity insert' {
            $table = & $opt '--table-name'
            $i = [array]::IndexOf($a, '--entity')
            $e = [ordered]@{}
            foreach ($kv in $a[($i + 1)..($a.Count - 1)]) { $k, $v = $kv -split '=', 2; $e[$k] = $v }
            if (-not $global:AzTables[$table]) { $global:AzTables[$table] = @{} }
            $global:AzTables[$table]["$($e.PartitionKey)|$($e.RowKey)"] = [PSCustomObject]$e
            return
        }
    }
    $global:LASTEXITCODE = 9
}

function Initialize-Az { param([string]$Included)
    $global:AzCalls.Clear(); $global:AzLoginAllowed = $true
    $global:AzTables = @{ PortalConfig = @{
        'subscriptions|discovered' = [PSCustomObject]@{ PartitionKey = 'subscriptions'; RowKey = 'discovered'; At = '2026-09-18T02:00:00Z'
            SubscriptionsJson = (@([ordered]@{ id = $subA; name = 'Production' }, [ordered]@{ id = $subB; name = 'Sandbox' }, [ordered]@{ id = $subC; name = 'Data Platform' }) | ConvertTo-Json -Compress -AsArray) }
    } }
    if ($Included) { $global:AzTables.PortalConfig['settings|scope'] = [PSCustomObject]@{ PartitionKey = 'settings'; RowKey = 'scope'; IncludedSubscriptionIds = $Included } }
}
function Get-SavedScope { $global:AzTables.PortalConfig['settings|scope'] }
# What the Function App will make of the saved row — the real reader, over the stub store.
function Get-EffectiveScope {
    $row = Get-SavedScope
    $global:Store = @{ PortalConfig = @{ 'settings|scope' = @{ PartitionKey = 'settings'; RowKey = 'scope'; IncludedSubscriptionIds = [string]$row.IncludedSubscriptionIds } } }
    Get-SubscriptionScope -Token 't'
}

Write-Host "`nSet-SubscriptionScope.ps1"
Test-That '-Show prints and writes nothing' {
    Initialize-Az
    & $script -ResourceGroupName rg -Show *> $null
    Assert-Equal 0 @($global:AzCalls | Where-Object { $_ -like 'storage entity insert*' }).Count 'no writes'
}
Test-That '-Exclude from ALL = every subscription except those; the Function App reads it back' {
    Initialize-Az
    & $script -ResourceGroupName rg -Exclude 'Sandbox' -Confirm:$false *> $null
    $row = Get-SavedScope
    Assert-Equal ((@($subA, $subC) | Sort-Object) -join ',') $row.IncludedSubscriptionIds 'ids'
    $eff = Get-EffectiveScope
    Assert-Equal 2 $eff.Count 'parsed by the app'
    Assert-Equal $eff.Hash $row.ScopeHash 'script and app compute the same hash'
    Assert-Equal 'operator@contoso.com' $row.UpdatedBy 'who'
    $audit = @($global:AzTables['AuditLog'].Values)
    Assert-Equal 1 $audit.Count 'audited'
    Assert-Equal 'SetSubscriptionScope' $audit[0].Action 'action'
}
Test-That '-Include adds to an existing list; ids or names, any case' {
    Initialize-Az -Included $subA
    & $script -ResourceGroupName rg -Include $subC.ToUpper() -Confirm:$false *> $null
    Assert-Equal ((@($subA, $subC) | Sort-Object) -join ',') (Get-SavedScope).IncludedSubscriptionIds 'added'
}
Test-That 'including everything, or -All, saves ALL (so new subscriptions are covered later)' {
    Initialize-Az -Included $subA
    & $script -ResourceGroupName rg -Include 'Sandbox', 'Data Platform' -Confirm:$false *> $null
    Assert-Equal '' (Get-SavedScope).IncludedSubscriptionIds 'every id listed = ALL'
    Initialize-Az -Included $subA
    & $script -ResourceGroupName rg -All -Confirm:$false *> $null
    Assert-Equal '' (Get-SavedScope).IncludedSubscriptionIds 'all'
    Assert-Equal 'all' (Get-SavedScope).ScopeHash 'hash'
    Assert-True ($null -eq (Get-EffectiveScope).Ids) 'the app reads ALL'
}
Test-That '-WhatIf changes nothing' {
    Initialize-Az
    & $script -ResourceGroupName rg -Exclude 'Sandbox' -WhatIf *> $null
    Assert-True ($null -eq (Get-SavedScope)) 'no scope row'
}
Test-That 'excluding everything is refused; unknown names are refused' {
    Initialize-Az -Included $subA
    $threw = $false; try { & $script -ResourceGroupName rg -Exclude 'Production' -Confirm:$false *> $null } catch { $threw = $true }
    Assert-True $threw 'empty scope refused'
    $threw = $false; try { & $script -ResourceGroupName rg -Exclude 'Nope' -Confirm:$false *> $null } catch { $threw = $true }
    Assert-True $threw 'unknown name refused'
    Assert-Equal $subA (Get-SavedScope).IncludedSubscriptionIds 'unchanged'
}
Test-That 'without a data-plane role it falls back to the account key, and says so' {
    Initialize-Az
    $global:AzLoginAllowed = $false
    & $script -ResourceGroupName rg -Exclude 'Sandbox' -Confirm:$false *> $null
    $insert = @($global:AzCalls | Where-Object { $_ -like 'storage entity insert*PortalConfig*' })[0]
    Assert-True ($insert -like '*--auth-mode key*') "wrote with the key: $insert"
}
Test-That 'before the first ingest it offers the operator''s own subscriptions' {
    Initialize-Az
    $global:AzTables.PortalConfig.Remove('subscriptions|discovered')
    $out = & $script -ResourceGroupName rg -Show 6>&1 | Out-String
    Assert-True ($out -match "YOUR account") 'says whose list it is'
}

Write-Host ""
Write-Host "Set-SubscriptionScope tests: $($script:Passed) passed, $($script:Failed.Count) failed" -ForegroundColor $(if ($script:Failed.Count) { 'Red' } else { 'Green' })
if ($PassThru) { return [PSCustomObject]@{ Passed = $script:Passed; Failed = @($script:Failed) } }
if ($script:Failed.Count) { exit 1 }
