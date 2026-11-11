# Offline tests for the findings agent (CostAgent.psm1, Invoke-AiAgent in AiAdapter.psm1).
# No Azure, no AI provider: the stubs live in TestKit.ps1. Run via Tests/Invoke-OfflineTests.ps1.

param([switch]$PassThru)

. (Join-Path $PSScriptRoot 'TestKit.ps1')

Write-Host "`nEnvironment guess"
Test-That 'resource-group names read as non-production, production or unknown' {
    Assert-Equal 'non-production' (Get-EnvironmentGuess 'datawarehouse-dev') 'suffix'
    Assert-Equal 'non-production' (Get-EnvironmentGuess 'doi-roi-replica-ptvt-test') 'test'
    Assert-Equal 'non-production' (Get-EnvironmentGuess 'sandbox_tsm') 'underscore'
    Assert-Equal 'production' (Get-EnvironmentGuess 'webshop-prod') 'prod'
    Assert-Equal 'unknown' (Get-EnvironmentGuess 'shared-resources') 'neither'
    Assert-Equal 'unknown' (Get-EnvironmentGuess 'developer-portal') 'a word that only starts like dev'
}

Write-Host "`nPseudonyms"
Test-That 'names and GUIDs are replaced and come back unchanged' {
    $m = New-PseudonymMap
    Add-Pseudonym -Map $m -Value 'jane.doe@contoso.com' -Prefix 'OWNER'
    Add-Pseudonym -Map $m -Value 'Sandbox Sub' -Prefix 'SUBN'
    Add-Pseudonym -Map $m -Value '(untagged)' -Prefix 'OWNER'
    $text = "{""owner"":""jane.doe@contoso.com"",""sub"":""Sandbox Sub"",""id"":""/subscriptions/$sub/resourcegroups/x"",""o2"":""(untagged)""}"
    $p = Protect-AgentText -Map $m -Text $text
    Assert-True ($p -notmatch 'contoso') 'owner hidden'
    Assert-True ($p -notmatch 'Sandbox Sub') 'subscription name hidden'
    Assert-True ($p -notmatch [regex]::Escape($sub)) 'subscription id hidden'
    Assert-True ($p -match '\(untagged\)') 'placeholders stay readable'
    Assert-Equal $text (Unprotect-AgentText -Map $m -Text $p) 'round trip'
}
Test-That 'a short value is not used as a pseudonym (would replace ordinary words)' {
    $m = New-PseudonymMap
    Add-Pseudonym -Map $m -Value 'BI' -Prefix 'OWNER'
    Assert-Equal 0 $m.Forward.Count 'not registered'
}

Write-Host "`nReader-facing text"
Test-That 'ids, field names and USD amounts are taken out of finding text' {
    $t = Remove-InsightJargon 'Advisor item A-9f6b4d0c7e02de2a recommends right-sizing VM VM-APP-001 with monthlyUsd $596.0 and lists an owner.'
    Assert-Equal 'Advisor recommends right-sizing VM VM-APP-001 and lists an owner.' $t 'cleaned'
    Assert-Equal 'High-confidence VM right-size recommendation' (Remove-InsightJargon 'High-confidence VM right-size recommendation ($596/mo)') 'amount in brackets'
    Assert-Equal 'Spend up 64% since 21 Sep on bi-dw-dev.' (Remove-InsightJargon 'Spend up 64% since 21 Sep on bi-dw-dev (Q1).') 'percentages, dates and names stay; refs go'
    Assert-Equal 'Leaving open savings not owned.' (Remove-InsightJargon 'Leaving about 13,770.98 USD of open savings not owned.') 'amount with a currency'
    Assert-Equal 'Savings sit on resources that are deleted.' (Remove-InsightJargon 'Savings sit on resources that are (resource no longer exists).') 'placeholder in words'
    Assert-Equal 'VM costs more since 3 Sep, 8 units.' (Remove-InsightJargon 'VM costs $596 a month more since 3 Sep, 8 units.') 'dollar amount; counts and dates stay'
}
Test-That 'a cost change that is falling is never priority 1; one already back to normal is no finding' {
    $m = New-PseudonymMap
    $f = { param($Refs, [int]$Prio) [PSCustomObject]@{ priority = $Prio; title = 't'; why = 'w'; owner = ''; monthlyCost = $null; estMonthlySavings = $null
        currency = 'USD'; action = 'a'; actionScript = ''; refs = @($Refs) } }
    $parsed = [PSCustomObject]@{ summary = 's'; findings = @(
        (& $f @('C-open') 1)
        (& $f @('C-down') 1)
        (& $f @('C-gone') 1)
        (& $f @('C-down', 'S-x') 1)) }
    $r = Select-InsightFindings -Parsed $parsed -AllowedText '{}' -KnownRefs @{ 'C-open' = $true; 'C-down' = $true; 'C-gone' = $true; 'S-x' = $true } -Map $m `
        -ChangeStates @{ 'C-open' = 'open'; 'C-down' = 'decreasing'; 'C-gone' = 'resolved' }
    $byRefs = @{}; foreach ($x in $r.findings) { $byRefs[($x.refs -join ',')] = $x }
    Assert-Equal 3 @($r.findings).Count 'the resolved one is dropped'
    Assert-Equal 1 $byRefs['C-open'].priority 'open keeps P1'
    Assert-Equal 2 $byRefs['C-down'].priority 'decreasing capped at P2'
    Assert-Equal 1 $byRefs['C-down,S-x'].priority 'a saving in the refs lifts the cap'

    # Ranked on what is still overspent now, against last month's spend of 100,000.
    $parsed = [PSCustomObject]@{ summary = 's'; findings = @((& $f @('C-big') 1), (& $f @('C-small') 1)) }
    $r = Select-InsightFindings -Parsed $parsed -AllowedText '{}' -KnownRefs @{ 'C-big' = $true; 'C-small' = $true } -Map $m `
        -ChangeStates @{ 'C-big' = 'decreasing'; 'C-small' = 'decreasing' } -ChangeExcess @{ 'C-big' = 5000.0; 'C-small' = 100.0 } -BaseUsd 100000
    $byRefs = @{}; foreach ($x in $r.findings) { $byRefs[($x.refs -join ',')] = $x }
    Assert-Equal 2 $byRefs['C-big'].priority 'still 5% overspent: P2 (never P1 while falling)'
    Assert-Equal 3 $byRefs['C-small'].priority 'little left overspent: P3'

    $rule = @(Get-RuleFindings -Payload ([PSCustomObject]@{ spend = @{ previousMonth = @{ usd = 1000 } }; savings = @{ items = @() }
        changes = @{ items = @(
            [PSCustomObject]@{ id = 'C-1'; name = 'dota'; deltaUsd = 500; currentUsd = 600; owner = ''; cause = $null; state = 'decreasing'; currentExcessUsd = 300 }
            [PSCustomObject]@{ id = 'C-3'; name = 'tail'; deltaUsd = 500; currentUsd = 600; owner = ''; cause = $null; state = 'decreasing'; currentExcessUsd = 2 }
            [PSCustomObject]@{ id = 'C-2'; name = 'gone'; deltaUsd = 900; currentUsd = 950; owner = ''; cause = $null; state = 'resolved'; resolved = $true }) } }))
    Assert-Equal 2 $rule.Count 'no-AI findings skip a resolved change'
    $byRef = @{}; foreach ($x in $rule) { $byRef[$x.refs[0]] = $x }
    Assert-Equal 2 $byRef['C-1'].priority 'a large overspend still running is capped at P2'
    Assert-Equal 3 $byRef['C-3'].priority 'almost back to normal is P3'
}
Test-That 'the owner is not repeated in a title' {
    $m = New-PseudonymMap; Add-Pseudonym -Map $m -Value 'jane.doe@contoso.com' -Prefix 'OWNER'
    $parsed = [PSCustomObject]@{ summary = 's'; findings = @([PSCustomObject]@{ priority = 2; title = 'VM right-size recommendation owned by OWNER_1'; why = 'w'; owner = 'OWNER_1'
        monthlyCost = $null; estMonthlySavings = $null; currency = 'USD'; action = 'a'; actionScript = ''; refs = @('S-x') }) }
    $r = Select-InsightFindings -Parsed $parsed -AllowedText '{}' -KnownRefs @{ 'S-x' = $true } -Map $m
    Assert-Equal 'VM right-size recommendation' $r.findings[0].title 'title'
    Assert-Equal 'jane.doe@contoso.com' $r.findings[0].owner 'owner column keeps it'
}
Test-That 'a missing owner tag is a finding without a saving; commands with portal ids are dropped' {
    $m = New-PseudonymMap
    $f = { param($Refs, $Save, $Script) [PSCustomObject]@{ priority = 2; title = 't'; why = 'w'; owner = ''; monthlyCost = $null; estMonthlySavings = $Save
        currency = 'USD'; action = 'a'; actionScript = $Script; refs = @($Refs) } }
    $parsed = [PSCustomObject]@{ summary = 's'; findings = @(
        (& $f @('O-2') 3600.0 "az advisor recommendation list --query `"[?contains(id, 'A-')]`"")
        (& $f @('O-2', 'S-x') 100.0 '')
        (& $f @('RG-1') 100.0 '')
        (& $f @('S-x') 100.0 'az vm deallocate -g rg-01 -n vm-q1')) }
    $r = Select-InsightFindings -Parsed $parsed -AllowedText '{"monthlyUsd":100}' -KnownRefs @{ 'O-2' = $true; 'S-x' = $true; 'RG-1' = $true } -Map $m -UntaggedRefs @{ 'O-2' = $true }
    Assert-Equal 4 @($r.findings).Count 'all kept — a missing owner is fine to mention'
    $byRefs = @{}; foreach ($x in $r.findings) { $byRefs[($x.refs -join ',')] = $x }
    Assert-Equal $null $byRefs['O-2'].estMonthlySavings 'no saving on the untagged row'
    Assert-Equal '' $byRefs['O-2'].actionScript 'a command quoting a portal id is dropped'
    Assert-Equal $null $byRefs['O-2,S-x'].estMonthlySavings 'not even with a saving cited alongside'
    Assert-Equal $null $byRefs['RG-1'].estMonthlySavings 'a resource-group row is not a saving'
    Assert-Equal 100.0 $byRefs['S-x'].estMonthlySavings 'a cited saving keeps its figure'
    Assert-Equal 'az vm deallocate -g rg-01 -n vm-q1' $byRefs['S-x'].actionScript 'ordinary names are not mistaken for ids'
}
Test-That 'billing-account purchases: never "lacking an owner", no cost copied from the saving' {
    $m = New-PseudonymMap
    $f = { param($Title, $Refs, $Cost, $Save) [PSCustomObject]@{ priority = 2; title = $Title; why = 'w'; owner = ''; monthlyCost = $Cost; estMonthlySavings = $Save
        currency = 'USD'; action = 'a'; actionScript = ''; refs = @($Refs) } }
    $parsed = [PSCustomObject]@{ summary = 's'; findings = @(
        (& $f 'High-value reservation recommendations exist but lack an owner' @('A-1') 3210.0 3210.0)
        (& $f 'Buy the 3-year reservation for D4s v5 in West Europe' @('A-1') 3210.0 3210.0)
        (& $f 'Notable untagged spend with no owner assigned' @('O-2') 26378.0 $null)) }
    $r = Select-InsightFindings -Parsed $parsed -AllowedText '{"monthlyUsd":3210,"currentUsd":26378}' -KnownRefs @{ 'A-1' = $true; 'O-2' = $true } -Map $m `
        -UntaggedRefs @{ 'O-2' = $true } -BillingScopeRefs @{ 'A-1' = $true }
    Assert-Equal 2 @($r.findings).Count 'the purchase blamed on a missing owner is dropped'
    Assert-Equal 1 $r.dropped 'counted as dropped'
    $buy = @($r.findings | Where-Object { $_.refs -contains 'A-1' })[0]
    Assert-True $buy.billingScope 'shown as a billing-account purchase'
    Assert-Equal $null $buy.monthlyCost 'a savings item has no monthly cost to copy'
    Assert-Equal 3210.0 $buy.estMonthlySavings 'the saving stays'
    $untagged = @($r.findings | Where-Object { $_.refs -contains 'O-2' })[0]
    Assert-Equal 26378.0 $untagged.monthlyCost 'untagged spend keeps its cost'
    Assert-Equal $null $untagged.estMonthlySavings 'and has no saving'
}

Write-Host "`nIdle resources"
Test-That 'a saving on a resource with no cost for three days is left out of the overview' {
    Reset-State
    $settled = Get-BriefSettledDate
    $idleVm = "/subscriptions/$sub/resourcegroups/rg-vms/providers/microsoft.compute/virtualmachines/vm-app-001"
    $sqlServer = "/subscriptions/$sub/resourcegroups/rg-db/providers/microsoft.sql/servers/sql1"
    for ($i = 0; $i -lt 3; $i++) {
        $day = $settled.AddDays(-$i).ToString('yyyy-MM-dd')
        Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $day; RowKey = 'a'; DimensionKey = $vm; CostUsd = 12.0 }
        Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $day; RowKey = 'b'; DimensionKey = $idleVm; CostUsd = 0.0 }
        Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $day; RowKey = 'c'; DimensionKey = "$sqlServer/databases/db1"; CostUsd = 5.0 }
    }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'advisor-meta'; RowKey = 'latest'; LatestRunId = 'r' }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = 'idle'; RunId = 'r'; Solution = 'Right-size'; ResourceId = $idleVm; EstMonthlySavingsUsd = 596.0; SavingsConverted = $true }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = 'busy'; RunId = 'r'; Solution = 'Right-size'; ResourceId = $vm; EstMonthlySavingsUsd = 100.0; SavingsConverted = $true }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = 'parent'; RunId = 'r'; Solution = 'Elastic pool'; ResourceId = $sqlServer; EstMonthlySavingsUsd = 50.0; SavingsConverted = $true }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = 'plan'; RunId = 'r'; Solution = 'Savings plan'; ResourceId = "/subscriptions/$sub"; EstMonthlySavingsUsd = 70.0; SavingsConverted = $true }
    $s = Get-BriefSavings -Token 't' -Top 100 -ExcludeIdle
    Assert-Equal 'A-busy,A-plan,A-parent' (@($s.items).id -join ',') 'idle VM left out; parent of a costed child and billing-scope kept'
    Assert-Equal 1 $s.idleCount 'counted'
    Assert-Equal 4 @((Get-BriefSavings -Token 't' -Top 100).items).Count 'without the switch nothing is left out'
    $global:Store['CostSnapshots'].Remove("$($settled.ToString('yyyy-MM-dd'))|a"); $global:Store['CostSnapshots'].Remove("$($settled.ToString('yyyy-MM-dd'))|b"); $global:Store['CostSnapshots'].Remove("$($settled.ToString('yyyy-MM-dd'))|c")
    Assert-Equal 4 @((Get-BriefSavings -Token 't' -Top 100 -ExcludeIdle).items).Count 'a day with no snapshots: no conclusion, nothing left out'
}

Write-Host "`nAdvisor purchase alternatives"
Test-That 'a reservation listed for 1 and 3 years and two look-backs counts once, at its best figure' {
    Reset-State
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'advisor-meta'; RowKey = 'latest'; LatestRunId = 'r' }
    $i = 0
    foreach ($alt in @(@{ t = 'P1Y'; l = 'Last30Days'; s = 100.0 }, @{ t = 'P3Y'; l = 'Last30Days'; s = 180.0 }, @{ t = 'P1Y'; l = 'Last60Days'; s = 90.0 }, @{ t = 'P3Y'; l = 'Last60Days'; s = 170.0 })) {
        $i++
        Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = "ri$i"; RunId = 'r'; ResourceId = $sub; Solution = 'Buy reserved instances'
            Region = 'westeurope'; ReservedResourceType = 'VirtualMachines'; TargetSku = 'Standard_D4s_v5'; Term = $alt.t; LookbackPeriod = $alt.l
            EstMonthlySavingsUsd = $alt.s; SavingsConverted = $true }
    }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = 'sp'; RunId = 'r'; ResourceId = $sub; Solution = 'Buy a savings plan'
        Term = 'P1Y'; EstMonthlySavingsUsd = 50.0; SavingsConverted = $true }
    $s = Get-BriefSavings -Token 't' -Top 100
    Assert-Equal 230.0 $s.totalMonthlyUsd 'best reservation alternative (180) + the savings plan (50), not 590'
    Assert-Equal 2 $s.count 'two purchases'
    Assert-Equal 3 $s.alternativeCount 'three alternatives left out'
    Assert-Equal 'P3Y' (@($s.items | Where-Object title -eq 'Buy reserved instances')[0].term) 'the term kept is shown'
}

Write-Host "`nRule findings (no AI)"
Test-That 'savings and changes ranked by amount against last month' {
    $payload = [PSCustomObject]@{
        spend = [PSCustomObject]@{ previousMonth = [PSCustomObject]@{ usd = 10000.0 }; current = [PSCustomObject]@{ usd = 5000.0 } }
        savings = [PSCustomObject]@{ items = @(
            [PSCustomObject]@{ id = 'S-big'; title = 'Delete disk'; resourceName = 'd1'; detail = 'x'; owner = 'ann'; monthlyUsd = 300.0 }
            [PSCustomObject]@{ id = 'S-small'; title = 'Cool tier'; resourceName = 's1'; detail = 'y'; owner = ''; monthlyUsd = 20.0 }) }
        changes = [PSCustomObject]@{ items = @([PSCustomObject]@{ id = 'C-1'; name = 'vm1'; owner = 'bob'; currentUsd = 400.0; deltaUsd = 80.0; cause = $null }) }
    }
    $r = @(Get-RuleFindings -Payload $payload)
    Assert-Equal 'S-big' $r[0].refs[0] 'largest first'
    Assert-Equal 1 $r[0].priority '3% of last month -> 1'
    Assert-Equal 2 (@($r | Where-Object { $_.refs[0] -eq 'C-1' })[0].priority) '0.8% -> 2'
    Assert-Equal 3 (@($r | Where-Object { $_.refs[0] -eq 'S-small' })[0].priority) '0.2% -> 3'
}

Write-Host "`nAgent loop"
function Initialize-AgentStore {
    Reset-State
    $env:COST_QUERY_SCOPE = "/subscriptions/$sub"
    for ($d = [datetime]::UtcNow.Date.AddDays(-70); $d -lt [datetime]::UtcNow.Date; $d = $d.AddDays(1)) {
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = $d.ToString('yyyy-MM-dd'); TotalUsd = 1000.0 }
    }
    $owners = @(@{ key = 'jane.doe@contoso.com'; label = 'jane.doe@contoso.com'; subscriptionId = ''; currentUsd = 8000.0; previousSameDaysUsd = 7000.0; previousMonthUsd = 15000.0; deltaUsd = 1000.0; deltaPct = 14.3; sharePct = 80.0; resources = 12 })
    $rgs = @(@{ key = "/subscriptions/$sub/resourcegroups/bi-dw-dev"; label = 'bi-dw-dev (Sandbox Sub)'; subscriptionId = $sub; currentUsd = 5900.0; previousSameDaysUsd = 5000.0; previousMonthUsd = 9000.0; deltaUsd = 900.0; deltaPct = 18.0; sharePct = 58.0; resources = 9 })
    Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'allocation'; RowKey = 'tag:owner'; RowsJson = ($owners | ConvertTo-Json -Depth 5 -Compress -AsArray) }
    Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'allocation'; RowKey = 'resourceGroup'; RowsJson = ($rgs | ConvertTo-Json -Depth 5 -Compress -AsArray) }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'subscriptions'; RowKey = 'discovered'
        SubscriptionsJson = (@([ordered]@{ id = $sub; name = 'Sandbox Sub' }, [ordered]@{ id = '22222222-2222-2222-2222-222222222222'; name = 'Production Sub' }) | ConvertTo-Json -Compress -AsArray) }
}
function New-ToolCallResponse { param([string]$Name, $Arguments)
    return (@{ choices = @(@{ message = @{ content = $null; tool_calls = @(@{ id = 'call_1'; type = 'function'; function = @{ name = $Name; arguments = ($Arguments | ConvertTo-Json -Depth 8 -Compress) } }) }; finish_reason = 'tool_calls' })
               usage = @{ prompt_tokens = 300; completion_tokens = 60 } } | ConvertTo-Json -Depth 12)
}

Test-That 'the agent queries, names stay private, figures are checked, owners come back' {
    Initialize-AgentStore
    $savedAi = $global:AiResponder; $savedCost = $global:CostResponder
    $global:CostUris = [System.Collections.Generic.List[string]]::new()
    $global:CostResponder = { param($b, $uri) $global:CostUris.Add([string]$uri); New-CostResponse -Columns @('Cost', 'ResourceGroupName', 'Currency') -Rows @(, @(4321.0, 'bi-dw-dev', 'EUR')) }
    $global:AgentStep = 0
    $global:AiResponder = {
        param($req)
        $global:AgentStep++
        $user = $req.messages[1].content | ConvertFrom-Json
        $subToken = [string]$user.resourceGroups[0].subscription
        $ownerToken = [string]$user.owners[0].owner
        if ($global:AgentStep -eq 1) {
            return New-ToolCallResponse 'cost_query' @{ timeframe = 'MonthToDate'; from = $null; to = $null; granularity = 'None'
                groupBy = @('ResourceGroupName', 'Password'); groupByOwner = $false
                filters = @(@{ dimension = 'SubscriptionName'; values = @($subToken) }); compareWithPrevious = $false }
        }
        return New-ChatResponse @{
            summary = 'Non-production spend dominates.'
            findings = @(
                @{ priority = 1; title = 'Dev data warehouse runs like production'; why = 'bi-dw-dev costs 4321 this month.'; owner = $ownerToken
                   monthlyCost = 4321; estMonthlySavings = $null; currency = 'EUR'; action = 'Pause it at night.'; actionScript = 'az resource invoke-action --action suspend --ids x'; refs = @('RG-1', 'Q1') }
                @{ priority = 1; title = 'Invented'; why = 'It costs 98765 a month.'; owner = ''; monthlyCost = 98765; estMonthlySavings = $null
                   currency = 'USD'; action = 'x'; actionScript = ''; refs = @('RG-1') })
        }
    }
    try {
        $doc = Update-PortfolioBrief -Grain week -Token 't'
        Assert-Equal 'explained' $doc.aiStatus 'status'
        Assert-Equal 2 $global:AgentStep 'two model calls'
        $sent = ($global:WebCalls | ForEach-Object { [string]$_.Body }) -join "`n"
        Assert-True ($sent -notmatch 'contoso') 'no owner name sent to the model'
        Assert-True ($sent -notmatch 'Sandbox Sub') 'no subscription name sent to the model'
        Assert-True ($sent -notmatch [regex]::Escape($sub)) 'no subscription id sent to the model'
        $q = $global:CostQueryBodies | Select-Object -Last 1
        $qJson = $q | ConvertTo-Json -Depth 12 -Compress
        Assert-Equal 1 $global:CostUris.Count 'the named subscription only'
        Assert-True ($global:CostUris[0] -like "*/subscriptions/$sub/*") 'asked of the subscription the token stood for'
        Assert-True ($qJson -notmatch 'Password') 'a dimension outside the allowlist is dropped'
        Assert-Equal 1 @($doc.ai.findings).Count 'ungrounded finding dropped'
        $f = $doc.ai.findings[0]
        Assert-Equal 'jane.doe@contoso.com' $f.owner 'owner mapped back'
        Assert-Equal 'EUR' $f.currency 'currency from the query row'
        Assert-Equal 'Q1' $doc.ai.toolCalls[0].ref 'tool call logged'
        Assert-True ($doc.ai.toolCalls[0].args -match 'Sandbox Sub') 'the log shows the real arguments'
        Assert-True (-not $doc.grounded) 'flagged that a finding was dropped'
        Assert-Equal 'non-production' $doc.payload.resourceGroups[0].environment 'environment guess in the payload'
    } finally { $global:AiResponder = $savedAi; $global:CostResponder = $savedCost; $env:COST_QUERY_SCOPE = $null }
}
Test-That 'a tool error goes back to the model instead of failing the run' {
    Initialize-AgentStore
    $savedAi = $global:AiResponder
    $global:AgentStep = 0
    $global:AiResponder = {
        param($req)
        $global:AgentStep++
        if ($global:AgentStep -eq 1) { return New-ToolCallResponse 'change_evidence' @{ id = 'C-nope' } }
        $toolMsg = @($req.messages | Where-Object { $_.role -eq 'tool' })[0]
        Assert-True ([string]$toolMsg.content -match 'unknown change id') 'error returned as the tool result'
        return New-ChatResponse @{ summary = 's'; findings = @(@{ priority = 2; title = 'Owner spend rising'; why = 'Up 14.3 percent.'; owner = ''; monthlyCost = $null
            estMonthlySavings = $null; currency = 'USD'; action = 'Ask why.'; actionScript = ''; refs = @('O-1') }) }
    }
    try {
        $doc = Update-PortfolioBrief -Grain week -Token 't'
        Assert-Equal 'explained' $doc.aiStatus 'status'
        Assert-Equal 1 @($doc.ai.findings).Count 'finding kept'
        Assert-True ($doc.ai.toolCalls[0].summary -like 'failed:*') 'failure logged'
    } finally { $global:AiResponder = $savedAi; $env:COST_QUERY_SCOPE = $null }
}
Test-That 'the last step forbids further tool calls' {
    Initialize-AgentStore
    $savedAi = $global:AiResponder
    $global:Choices = [System.Collections.Generic.List[string]]::new()
    $global:AiResponder = {
        param($req)
        $global:Choices.Add([string]$req.tool_choice)
        if ($req.tool_choice -eq 'none') { return New-ChatResponse @{ summary = 's'; findings = @() } }
        return New-ToolCallResponse 'saving_detail' @{ id = 'S-x' }
    }
    try {
        $r = Invoke-AiAgent -System 's' -User 'u' -Tools @(@{ name = 'saving_detail'; description = 'd'; parameters = @{ type = 'object' } }) `
            -ToolHandler { param($n, $a) @{ ok = $true } } -MaxSteps 3
        Assert-Equal 'auto,auto,none' ($global:Choices -join ',') 'tool_choice per step'
        Assert-Equal 2 @($r.ToolCalls).Count 'two tool calls ran'
    } finally { $global:AiResponder = $savedAi }
}

Write-Host "`nLanguage (PORTAL_LANGUAGE)"
$savedLanguage = $env:PORTAL_LANGUAGE
Test-That 'every server text exists in English and Danish; anything but da is English' {
    $en = @(Get-PortalTextKeys -Language en | Sort-Object); $da = @(Get-PortalTextKeys -Language da | Sort-Object)
    Assert-Equal ($en -join ',') ($da -join ',') 'same keys'
    $env:PORTAL_LANGUAGE = 'fr'; Assert-Equal 'en' (Get-PortalLanguage) 'unknown language → English'
    $env:PORTAL_LANGUAGE = 'da'; Assert-Equal 'Omkostning op: vm-1' (Get-PortalText 'rule.costUp' @{ name = 'vm-1' }) 'Danish, placeholder filled'
    Assert-Equal '1.234,5' (Format-PortalNumber 1234.5 1) 'Danish number'
    $env:PORTAL_LANGUAGE = 'en'; Assert-Equal '1,234.5' (Format-PortalNumber 1234.5 1) 'English number'
}
Test-That 'the portal''s own savings and no-AI findings are written in Danish for da, without dollar amounts' {
    $env:PORTAL_LANGUAGE = 'da'
    $f = @(ConvertTo-UnusedCommitmentFindings -Unused ([PSCustomObject]@{ Items = @([PSCustomObject]@{ Id = '/providers/microsoft.capacity/reservationorders/o/reservations/r'; Name = 'D4s'; Kind = 'reservation'; UnusedUsd = 300.0; Days = 30 }) }))
    Assert-Equal 'Ubrugt reservation: D4s' $f[0].Title 'title'
    Assert-True ($f[0].Detail -notmatch '\$') "no dollar amount: $($f[0].Detail)"
    $rule = @(Get-RuleFindings -Payload ([PSCustomObject]@{ spend = @{ previousMonth = @{ usd = 1000 } }; savings = @{ items = @() }
        changes = @{ items = @([PSCustomObject]@{ id = 'C-1'; name = 'vm-1'; deltaUsd = 50; currentUsd = 80; owner = ''; cause = $null }) } }))
    Assert-Equal 'Omkostning op: vm-1' $rule[0].title 'rule finding title'
    $env:PORTAL_LANGUAGE = 'en'
    $f = @(ConvertTo-UnusedCommitmentFindings -Unused ([PSCustomObject]@{ Items = @([PSCustomObject]@{ Id = 'x/reservationorders/o/reservations/r'; Name = 'D4s'; Kind = 'reservation'; UnusedUsd = 300.0; Days = 30 }) }))
    Assert-Equal 'Unused reservation: D4s' $f[0].Title 'English unchanged'
}
Test-That 'the AI prompts ask for Danish only when the portal is Danish' {
    $env:PORTAL_LANGUAGE = 'en'
    Assert-True ((Get-InsightSystemPrompt) -notmatch 'Danish') 'findings prompt, English'
    Assert-True ((Get-CostChangeExplanationSystemPrompt) -notmatch 'Danish') 'explanation prompt, English'
    $env:PORTAL_LANGUAGE = 'da'
    Assert-True ((Get-InsightSystemPrompt) -match 'in Danish \(dansk\)') 'findings prompt, Danish'
    Assert-True ((Get-CostChangeExplanationSystemPrompt) -match 'in Danish \(dansk\)') 'explanation prompt, Danish'
    $ask = Get-Content (Join-Path $fa 'QueryCosts/run.ps1') -Raw
    Assert-True ($ask -match '\$answerSystem = Add-AiLanguageLine') 'the Ask answer prompt gets the same line'
}
Test-That 'Danish guards: a purchase blamed on a missing owner is dropped; Danish figures are checked' {
    $env:PORTAL_LANGUAGE = 'da'
    $m = New-PseudonymMap
    $parsed = [PSCustomObject]@{ summary = 's'; findings = @(
        [PSCustomObject]@{ priority = 2; title = 'Reservationsanbefalingen mangler en ejer'; why = 'w'; owner = ''; monthlyCost = $null; estMonthlySavings = 3210.0
            currency = 'USD'; action = 'a'; actionScript = ''; refs = @('A-1') }
        [PSCustomObject]@{ priority = 2; title = 'Køb en 3-årig reservation til D4s v5'; why = 'Sparer 3.210 kr. om måneden'; owner = ''; monthlyCost = $null; estMonthlySavings = 3210.0
            currency = 'USD'; action = 'a'; actionScript = ''; refs = @('A-1') }) }
    $r = Select-InsightFindings -Parsed $parsed -AllowedText '{"monthlyUsd":3210}' -KnownRefs @{ 'A-1' = $true } -Map $m -BillingScopeRefs @{ 'A-1' = $true }
    Assert-Equal 1 @($r.findings).Count 'the "mangler en ejer" finding is dropped'
    Assert-True (Test-NarrativeGrounding -Narrative 'Det koster 3.210 kr. og 45,6 % af forbruget' -Payload '{"a":3210,"b":45.6}') 'Danish figures found in the data'
    Assert-True (-not (Test-NarrativeGrounding -Narrative 'Det koster 1.234,5 kr.' -Payload '{"a":99}')) 'a Danish figure not in the data is caught'
    $env:PORTAL_LANGUAGE = 'en'
    Assert-True (Test-NarrativeGrounding -Narrative 'It costs 1,234.5 USD' -Payload '{"a":1234.5}') 'English figures unchanged'
}
$env:PORTAL_LANGUAGE = $savedLanguage

Write-Host ""
Write-Host "Cost agent tests: $($script:Passed) passed, $($script:Failed.Count) failed" -ForegroundColor $(if ($script:Failed.Count) { 'Red' } else { 'Green' })
if ($PassThru) { return [PSCustomObject]@{ Passed = $script:Passed; Failed = @($script:Failed) } }
if ($script:Failed.Count) { exit 1 }
