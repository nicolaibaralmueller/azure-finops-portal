# Shared offline test kit: dot-source it from a *.Tests.ps1 file.
#
# Loads profile.ps1 (and so every module, imported -Global), then replaces the Azure-facing
# helpers with in-memory stubs. Test files are run with `pwsh -File`, which runs the script in
# the global scope, so the global stubs below REPLACE the real helpers for every caller —
# including code inside the modules, which resolves unknown commands through the global table.
#
# The real table helpers are kept in $global:Real before they are replaced, for tests of the
# helpers themselves (they still call the stubbed Invoke-WebRequest).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fa = Join-Path $root 'src/function-app'

# profile.ps1 defines the shared helpers and imports every module globally.
. (Join-Path $fa 'profile.ps1')

# --------------------------------------------------------------------------------------------
# Tiny assertion kit
# --------------------------------------------------------------------------------------------
$script:Passed = 0; $script:Failed = [System.Collections.Generic.List[string]]::new()
function Test-That {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Host "  ok   $Name" -ForegroundColor DarkGreen }
    catch { $script:Failed.Add("$Name — $($_.Exception.Message)"); Write-Host "  FAIL $Name — $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal { param($Expected, $Actual, [string]$What = 'value')
    if ($Expected -is [double] -or $Actual -is [double]) {
        if ([Math]::Abs([double]$Expected - [double]$Actual) -gt 0.005) { throw "$What`: expected $Expected, got $Actual" }
    } elseif ("$Expected" -ne "$Actual") { throw "$What`: expected '$Expected', got '$Actual'" }
}
function Assert-True { param($Condition, [string]$What) if (-not $Condition) { throw "expected true: $What" } }

$global:Real = @{
    GetTableEntities       = ${function:Get-TableEntities}
    RemoveTableEntityBatch = ${function:Remove-TableEntityBatch}
}

# --------------------------------------------------------------------------------------------
# Functions host shims: HTTP functions build [HttpResponseContext] and call Push-OutputBinding.
# --------------------------------------------------------------------------------------------
if (-not ('HttpResponseContext' -as [type])) {
    Add-Type -TypeDefinition @'
public class HttpResponseContext {
    public System.Net.HttpStatusCode StatusCode { get; set; } = System.Net.HttpStatusCode.OK;
    public object Body { get; set; }
    public System.Collections.IDictionary Headers { get; set; }
}
'@
}
$global:Responses = [System.Collections.Generic.List[object]]::new()
function global:Push-OutputBinding { param([string]$Name, $Value) $global:Responses.Add($Value) }
# Run an HTTP function and return its response. Anonymous callers are admins only when
# ALLOW_ANONYMOUS_ACCESS is 'true' (Get-Caller), which Reset-State sets.
function Invoke-HttpFunction {
    param([string]$Name, $Body, [hashtable]$Query = @{}, [hashtable]$Headers = @{})
    $global:Responses.Clear()
    $req = [PSCustomObject]@{ Body = $Body; Query = $Query; Headers = $Headers; Method = 'POST' }
    & (Join-Path $fa "$Name/run.ps1") -Request $req -TriggerMetadata ([PSCustomObject]@{ InvocationId = 'test-invocation' }) *> $null
    return $global:Responses[-1]
}

# --------------------------------------------------------------------------------------------
# Stubs
# --------------------------------------------------------------------------------------------
$env:AzureWebJobsStorage__tableServiceUri = 'https://teststore.table.core.windows.net/'
$global:TableReads = [System.Collections.Generic.List[object]]::new()
$global:TableResponder = $null
$global:Store = @{}
$global:WebCalls = [System.Collections.Generic.List[object]]::new()
$global:CostQueryBodies = [System.Collections.Generic.List[object]]::new()
$global:AiResponder = $null
$global:CostResponder = $null
$global:RestResponder = $null
$global:FailTableWrites = $false

function global:Get-ManagedIdentityToken { param([string]$Resource) return 'test-token' }
function global:Get-TableEntities {
    param([string]$Table, [string]$Filter, [string]$Select, [int]$Top = 0, [string]$Token)
    $global:TableReads.Add([PSCustomObject]@{ Table = $Table; Filter = $Filter })
    $t = $global:Store[$Table]; if (-not $t) { return @() }
    $rows = @($t.Values)
    if ($Filter -match "PartitionKey eq '((?:[^']|'')*)'") { $pk = $Matches[1].Replace("''", "'"); $rows = @($rows | Where-Object { $_.PartitionKey -eq $pk }) }
    if ($Filter -match "PartitionKey lt '([^']*)'") { $v = $Matches[1]; $rows = @($rows | Where-Object { [string]::CompareOrdinal([string]$_.PartitionKey, $v) -lt 0 }) }
    if ($Filter -match "RowKey eq '((?:[^']|'')*)'") { $rk = $Matches[1].Replace("''", "'"); $rows = @($rows | Where-Object { $_.RowKey -eq $rk }) }
    if ($Filter -match "RowKey ge '([^']*)'") { $ge = $Matches[1]; $rows = @($rows | Where-Object { [string]$_.RowKey -ge $ge }) }
    # Range ends compare ordinally, as Table storage does.
    if ($Filter -match "RowKey gt '([^']*)'") { $v = $Matches[1]; $rows = @($rows | Where-Object { [string]::CompareOrdinal([string]$_.RowKey, $v) -gt 0 }) }
    if ($Filter -match "RowKey le '([^']*)'") { $v = $Matches[1]; $rows = @($rows | Where-Object { [string]::CompareOrdinal([string]$_.RowKey, $v) -le 0 }) }
    if ($Filter -match "RowKey lt '([^']*)'") { $v = $Matches[1]; $rows = @($rows | Where-Object { [string]::CompareOrdinal([string]$_.RowKey, $v) -lt 0 }) }
    return @($rows | ForEach-Object { [PSCustomObject]$_ })
}
function global:Set-TableEntity {
    param([string]$Table, [hashtable]$Entity, [string]$Token)
    if ($global:FailTableWrites) { throw 'simulated storage outage' }
    if (-not $global:Store[$Table]) { $global:Store[$Table] = @{} }
    $k = "$($Entity.PartitionKey)|$($Entity.RowKey)"
    $existing = $global:Store[$Table][$k]
    $merged = if ($existing) { $existing.Clone() } else { @{} }
    foreach ($p in $Entity.Keys) { if ($null -ne $Entity[$p]) { $merged[$p] = $Entity[$p] } }   # MERGE keeps omitted/null
    $global:Store[$Table][$k] = $merged
}
function global:Set-TableEntityBatch {
    param([string]$Table, [array]$Entities, [string]$Token)
    foreach ($e in @($Entities)) { Set-TableEntity -Table $Table -Entity $e -Token $Token }
}
function global:Invoke-CostQueryRest {
    param([string]$Uri, [string]$Token, [string]$Body, [int]$MaxAttempts, [int]$MaxWaitSeconds, [int]$TimeoutSec, [double]$BudgetSeconds)
    $b = $Body | ConvertFrom-Json
    $global:CostQueryBodies.Add($b)
    return (& $global:CostResponder $b $Uri)
}
function global:Invoke-RestMethod {
    param([string]$Method, [string]$Uri, $Headers, $Body, [string]$ContentType, [int]$TimeoutSec)
    return (& $global:RestResponder $Method $Uri $Body)
}
function global:Invoke-WebRequest {
    param([string]$Method, [string]$Uri, $Headers, $Body, [string]$ContentType, [switch]$SkipHttpErrorCheck, [int]$TimeoutSec)
    # Calls made INSIDE CostAnalysis.psm1 reach the real Invoke-CostQueryRest (module-internal
    # lookup), which then calls this — so Cost Management traffic is answered here too.
    if ($Uri -like '*Microsoft.CostManagement/query*' -or $Uri -like '*Microsoft.CostManagement/forecast*') {
        $b = $Body | ConvertFrom-Json
        $global:CostQueryBodies.Add($b)
        $resp = & $global:CostResponder $b $Uri
        return [PSCustomObject]@{ StatusCode = 200; Content = ($resp | ConvertTo-Json -Depth 10); Headers = @{} }
    }
    # The real table helpers (kept in $global:Real) page through this.
    if ($Uri -like '*.table.core.windows.net/*') { return (& $global:TableResponder $Method $Uri) }
    $global:WebCalls.Add([PSCustomObject]@{ Uri = $Uri; Body = $Body; Headers = $Headers })
    $content = & $global:AiResponder ($Body | ConvertFrom-Json)
    return [PSCustomObject]@{ StatusCode = 200; Content = $content; Headers = @{} }
}

function New-ChatResponse { param($Object)
    return (@{ choices = @(@{ message = @{ content = ($Object | ConvertTo-Json -Depth 8 -Compress) }; finish_reason = 'stop' })
               usage = @{ prompt_tokens = 120; completion_tokens = 40 } } | ConvertTo-Json -Depth 10)
}
function Reset-State {
    $global:Store = @{}
    $global:WebCalls.Clear(); $global:CostQueryBodies.Clear()
    $global:FailTableWrites = $false
    $global:TableReads.Clear()
    $env:ALLOW_ANONYMOUS_ACCESS = 'true'
    & (Get-Module AiAdapter) { $script:AiLimitCache = @{ Value = $null; At = [datetime]::MinValue } }
    $env:AI_PROVIDER = 'openai'; $env:AI_ENDPOINT = 'https://api.openai.com/v1'; $env:AI_MODEL = 'gpt-4o-mini'; $env:AI_API_KEY = 'test-key'; $env:AI_AUTH_MODE = ''
}
function Set-Setting { param([hashtable]$Values)
    $e = @{ PartitionKey = 'settings'; RowKey = 'current' }; foreach ($k in $Values.Keys) { $e[$k] = $Values[$k] }
    Set-TableEntity -Table 'PortalConfig' -Entity $e
}

# Cost Management rows in the shape the API returns: columns + rows.
function New-CostResponse { param([string[]]$Columns, $Rows)
    return [PSCustomObject]@{ properties = [PSCustomObject]@{ columns = @($Columns | ForEach-Object { [PSCustomObject]@{ name = $_ } }); rows = @($Rows); nextLink = $null } }
}

$today = [datetime]::UtcNow.Date
$sub = '11111111-2222-3333-4444-555555555555'
$vm = "/subscriptions/$sub/resourcegroups/rg-app/providers/microsoft.compute/virtualmachines/vm-app01"
