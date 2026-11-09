param($Timer)

Write-Host "=== Executive brief started ==="

# Builds the Overview's executive brief (Brief.psm1) after the nightly analysis has run:
#   week   on Mondays, or when missing / more than 7 days old
#   month  once the previous month is settled (from the 2nd), once per month
# Each is at most one AI call; without AI (or over the daily AI limit) the stored brief carries
# the deterministic figures only and the page renders them as a template.

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$today = [datetime]::UtcNow.Date
# A subscription-scope change makes both briefs due, so neither keeps describing the old set.
$scopeHash = (Get-SubscriptionScope -Token $storageToken).Hash

foreach ($grain in @('week', 'month')) {
    try {
        $stored = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'brief' and RowKey eq '$grain'" -Token $storageToken) | Select-Object -First 1
        if (-not (Test-BriefDue -Grain $grain -Stored $stored -Today $today -ScopeHash $scopeHash)) {
            Write-Host "$grain brief is current (generated $($stored.GeneratedAt)) — skipping."
            continue
        }
        # The page shows the weekly brief's findings (they include last month's changes); the
        # monthly brief only supplies last month's figures, so it runs without AI.
        $doc = Update-PortfolioBrief -Grain $grain -Token $storageToken -Today $today -SkipAi:($grain -eq 'month')
        Write-Host ("$grain brief written for $($doc.payload.spend.month): $(@($doc.payload.changes.items).Count) change(s), " +
                    "$(@($doc.payload.savings.items).Count) saving(s), AI $($doc.aiStatus).")
    } catch {
        # One grain failing must not stop the other.
        Write-Host "$grain brief failed: $($_.Exception.Message)"
    }
}

Write-Host "=== Executive brief finished ==="
