# ============================================================================
# Text.psm1 — the portal's own server-written texts in the deployment language.
#
# PORTAL_LANGUAGE (app setting, deploy.ps1 -Language → Bicep portalLanguage): 'en' (default) or
# 'da'. It decides the language of the texts this app writes itself — savings titles and details,
# the no-AI findings, the brief's notes — and the instruction the AI prompts get (Get-AiLanguageLine),
# so findings, explanations and Ask answers are written in it. Azure Advisor's texts stay as Azure
# writes them. Operator diagnostics (a query that failed, with Azure's error) stay English.
#
#   Get-PortalText -Key 'savings.orphan.detail' -Values @{ kind = …; name = … }
#
# Values fill {name} placeholders. Numbers should be formatted with Format-PortalNumber so a
# Danish text says 12,5 % and an English one 12.5%.
# ============================================================================

$script:Texts = @{
    en = @{
        'savings.stepUp.title'       = 'Sustained cost increase'
        'savings.stepUp.detail'      = 'Daily cost stepped up and has stayed at the new level for the last two weeks.'
        'savings.orphan.disk'        = 'Unattached managed disk'
        'savings.orphan.ip'          = 'Unassociated public IP'
        'savings.orphan.detail'      = "{kind} '{name}' is not attached to anything but still incurs cost. Safe to delete after confirming it isn't needed."
        'savings.rightsize.title'    = 'Resize {size} to {target}'
        'savings.rightsize.lowCpu'   = 'VM averaging {cpu}% CPU'
        'savings.rightsize.detail'   = "VM '{name}' ({size}) averaged {avg}% CPU and stayed under {p95}% for 95% of the hours measured; {mem}."
        'savings.rightsize.likely'   = ' Moving it to {target} saves the price difference at pay-as-you-go prices.'
        'savings.rightsize.noPrice'  = 'Azure does not publish a pay-as-you-go price for {size} or {target} in {region}, so the saving cannot be priced.'
        'savings.rightsize.noMem'    = 'no memory metric (the Azure Monitor agent is not sending one)'
        'savings.rightsize.mem'      = 'free memory stays above {pct}% of its usual level'
        'savings.schedule.title'     = 'Stop non-production VM outside working hours'
        'savings.schedule.detail'    = "VM '{name}' is tagged '{env}' but runs every day, weekends included. Stopping it outside 07:00–19:00 on weekdays (an auto-shutdown schedule, or Start/Stop VMs v2) saves the hours it stands idle. Its disks keep costing either way."
        'savings.storage.title'      = 'Move rarely used data out of the Hot tier'
        'savings.storage.detail'     = "Storage account '{name}' holds about {gib} GiB in the Hot tier but sees only {tx} transactions per GiB per month. Storing it as Cool ({red}) costs less per GB. A lifecycle rule that moves blobs untouched for 30 days is usually safer than switching the whole account; Cool reads cost more and data deleted within 30 days is still charged."
        'savings.la.title'           = 'Move Log Analytics workspace to the {best}'
        'savings.la.detail'          = "Workspace '{name}' ingested about {daily} GB/day over the last {days} days on {current}. The {best} costs less at list prices. A commitment tier can be lowered only after 31 days. If Microsoft Sentinel is enabled on this workspace, its own pricing applies and this estimate does not include it."
        'savings.overlap'            = " (Overlaps '{title}' for the same resource, which is the one counted in the total.)"
        'savings.unused.title'       = 'Unused {kind}: {name}'
        'savings.unused.detail'      = 'Over the last {days} days part of this {kind} paid for hours nothing used. {action}'
        'savings.unused.plan'        = 'A savings plan cannot be exchanged or cancelled, so the options are to widen its scope to shared, or move pay-as-you-go compute onto it. Don''t renew it at this size.'
        'savings.unused.reservation' = 'Widen its scope to shared (or to the management group) so other subscriptions can use it, exchange it for a size and region that are in use, or return it within the annual refund limit.'
        'kind.reservation'           = 'reservation'
        'kind.savings plan'          = 'savings plan'
        'kind.commitment'            = 'commitment'
        'rule.costUp'                = 'Cost up: {name}'
        'rule.notExplained'          = 'Not explained yet. Open the evidence to see what drove it.'
        'rule.askOwner'              = 'Ask the owner whether the increase is expected.'
        'brief.missingDays'          = 'Daily totals are missing for {n} day(s) of {month}, so its figures understate spend.'
        'brief.noPeriod.week'        = 'No week has been analysed for cost changes yet.'
        'brief.noPeriod.month'       = 'No month has been analysed for cost changes yet.'
        'brief.alternatives'         = '{n} Advisor purchase recommendation(s) not counted: other terms or look-back periods of the same reservation or savings plan.'
        'brief.idle'                 = '{n} saving(s) left out: the resource has had no cost for the last three days (stopped or deleted).'
        'brief.unconverted'          = '{n} Advisor recommendation(s) are in a currency with no exchange rate and are not counted.'
        'brief.noAllocation'         = 'Spend per owner and per resource group is not available yet (it is built nightly).'
        'status.week.history'        = 'The last 7 days are compared against the 4 weeks before them, which needs {need} days of stored daily cost. Only {have} are stored so far — the comparison starts once the rest have been collected.'
        'status.month.baseline1'     = 'A month is compared against the complete months before it, and only 1 complete month{list} of cost history has been collected. The first monthly comparison runs after {month} ends on {date}. Weekly comparison is unaffected — it needs far less history.'
        'status.month.baselineN'     = 'A month is compared against the complete months before it, and only {n} complete months{list} of cost history have been collected. The first monthly comparison runs after {month} ends on {date}. Weekly comparison is unaffected — it needs far less history.'
        'status.noData'              = 'No stored cost rows cover {period}, so there is nothing to compare. This clears once the daily cost sync has run for those days.'
        'commit.missingRole'         = "{kind}s: the portal's identity lacks the {role} role at tenant scope (Setup/Assign-AzureRbac.ps1 -IncludeReservationsReader / -IncludeSavingsPlanReader)."
    }
    da = @{
        'savings.stepUp.title'       = 'Vedvarende omkostningsstigning'
        'savings.stepUp.detail'      = 'Den daglige omkostning er steget og har ligget på det nye niveau de seneste to uger.'
        'savings.orphan.disk'        = 'Ikke-tilknyttet administreret disk'
        'savings.orphan.ip'          = 'Ikke-tilknyttet offentlig IP-adresse'
        'savings.orphan.detail'      = "{kind} '{name}' er ikke knyttet til noget, men koster stadig. Kan slettes, når det er bekræftet, at den ikke skal bruges."
        'savings.rightsize.title'    = 'Skift {size} til {target}'
        'savings.rightsize.lowCpu'   = 'VM med {cpu} % CPU i gennemsnit'
        'savings.rightsize.detail'   = "VM '{name}' ({size}) brugte i gennemsnit {avg} % CPU og lå under {p95} % i 95 % af de målte timer; {mem}."
        'savings.rightsize.likely'   = ' Et skift til {target} sparer prisforskellen ved pay-as-you-go-priser.'
        'savings.rightsize.noPrice'  = 'Azure offentliggør ikke en pay-as-you-go-pris for {size} eller {target} i {region}, så besparelsen kan ikke prissættes.'
        'savings.rightsize.noMem'    = 'ingen hukommelsesmåling (Azure Monitor-agenten sender ingen)'
        'savings.rightsize.mem'      = 'den frie hukommelse ligger over {pct} % af det normale niveau'
        'savings.schedule.title'     = 'Stop ikke-produktions-VM uden for arbejdstid'
        'savings.schedule.detail'    = "VM '{name}' er tagget '{env}', men kører hver dag, også i weekenden. Ved at stoppe den uden for 07:00–19:00 på hverdage (automatisk nedlukning eller Start/Stop VMs v2) spares de timer, hvor den står ubrugt. Dens diske koster stadig."
        'savings.storage.title'      = 'Flyt sjældent brugte data ud af Hot-niveauet'
        'savings.storage.detail'     = "Lagerkontoen '{name}' har omkring {gib} GiB i Hot-niveauet, men kun {tx} transaktioner pr. GiB pr. måned. Som Cool ({red}) koster de mindre pr. GB. En livscyklusregel, der flytter blobs der ikke er rørt i 30 dage, er som regel mere sikker end at skifte hele kontoen; læsning fra Cool koster mere, og data slettet inden 30 dage betales stadig."
        'savings.la.title'           = 'Flyt Log Analytics-arbejdsområdet til {best}'
        'savings.la.detail'          = "Arbejdsområdet '{name}' modtog omkring {daily} GB/dag de seneste {days} dage på {current}. {best} er billigere til listepris. Et commitment-niveau kan først sænkes efter 31 dage. Hvis Microsoft Sentinel er slået til på arbejdsområdet, gælder dens egne priser, og de er ikke med i dette skøn."
        'savings.overlap'            = " (Overlapper '{title}' for samme ressource, og det er den, der tælles med i totalen.)"
        'savings.unused.title'       = 'Ubrugt {kind}: {name}'
        'savings.unused.detail'      = 'De seneste {days} dage har en del af denne {kind} betalt for timer, som intet har brugt. {action}'
        'savings.unused.plan'        = 'En savings plan kan ikke ombyttes eller annulleres, så mulighederne er at udvide omfanget til delt eller flytte pay-as-you-go-compute over på den. Forny den ikke i denne størrelse.'
        'savings.unused.reservation' = 'Udvid omfanget til delt (eller til administrationsgruppen), så andre abonnementer kan bruge den, ombyt den til en størrelse og region der er i brug, eller returnér den inden for den årlige refusionsgrænse.'
        'kind.reservation'           = 'reservation'
        'kind.savings plan'          = 'savings plan'
        'kind.commitment'            = 'forpligtelse'
        'rule.costUp'                = 'Omkostning op: {name}'
        'rule.notExplained'          = 'Ikke forklaret endnu. Åbn dokumentationen for at se, hvad der drev den.'
        'rule.askOwner'              = 'Spørg ejeren, om stigningen er forventet.'
        'brief.missingDays'          = 'Daglige totaler mangler for {n} dag(e) i {month}, så tallene viser for lidt forbrug.'
        'brief.noPeriod.week'        = 'Ingen uge er analyseret for omkostningsændringer endnu.'
        'brief.noPeriod.month'       = 'Ingen måned er analyseret for omkostningsændringer endnu.'
        'brief.alternatives'         = '{n} Advisor-købsanbefaling(er) er ikke talt med: andre løbetider eller perioder for samme reservation eller savings plan.'
        'brief.idle'                 = '{n} besparelse(r) udeladt: ressourcen har ikke haft omkostninger de seneste tre dage (stoppet eller slettet).'
        'brief.unconverted'          = '{n} Advisor-anbefaling(er) er i en valuta uden vekselkurs og er ikke talt med.'
        'brief.noAllocation'         = 'Forbrug pr. ejer og pr. ressourcegruppe er ikke tilgængeligt endnu (det bygges hver nat).'
        'status.week.history'        = 'De seneste 7 dage sammenlignes med de 4 uger før, og det kræver {need} dages gemte daglige omkostninger. Kun {have} er gemt indtil videre — sammenligningen starter, når resten er hentet.'
        'status.month.baseline1'     = 'En måned sammenlignes med de hele måneder før den, og der er kun hentet 1 hel måneds omkostningshistorik{list}. Den første månedlige sammenligning kører, når {month} slutter den {date}. Den ugentlige sammenligning er ikke berørt — den kræver langt mindre historik.'
        'status.month.baselineN'     = 'En måned sammenlignes med de hele måneder før den, og der er kun hentet {n} hele måneders omkostningshistorik{list}. Den første månedlige sammenligning kører, når {month} slutter den {date}. Den ugentlige sammenligning er ikke berørt — den kræver langt mindre historik.'
        'status.noData'              = 'Der er ingen gemte omkostningsrækker for {period}, så der er intet at sammenligne. Det retter sig, når den daglige omkostningssynkronisering har kørt for de dage.'
        'commit.missingRole'         = "{kind}: portalens identitet mangler rollen {role} på tenant-niveau (Setup/Assign-AzureRbac.ps1 -IncludeReservationsReader / -IncludeSavingsPlanReader)."
    }
}

function Get-PortalLanguage {
    $l = ([string]$env:PORTAL_LANGUAGE).Trim().ToLowerInvariant()
    if ($l -eq 'da') { return 'da' }
    return 'en'
}

# The culture numbers are written in: '12,5' in Danish, '12.5' in English.
function Get-PortalCulture {
    if ((Get-PortalLanguage) -eq 'da') { return [System.Globalization.CultureInfo]::GetCultureInfo('da-DK') }
    return [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
}

function Format-PortalNumber {
    param([Parameter(Mandatory)][double]$Value, [int]$Decimals = 0)
    return [Math]::Round($Value, $Decimals).ToString("N$Decimals", (Get-PortalCulture))
}

function Get-PortalText {
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Values = @{})
    $table = $script:Texts[(Get-PortalLanguage)]
    $text = if ($table.ContainsKey($Key)) { $table[$Key] } else { $script:Texts.en[$Key] }
    if ($null -eq $text) { throw "Unknown text key '$Key'" }
    foreach ($k in $Values.Keys) { $text = $text.Replace("{$k}", [string]$Values[$k]) }
    return $text
}

# The line the AI prompts add so the model writes reader-facing text in the portal's language.
# Empty for English: the prompts are written in English and need no instruction.
function Get-AiLanguageLine {
    if ((Get-PortalLanguage) -eq 'da') {
        return 'Write all reader-facing text in Danish (dansk). Keep resource names, ids, field names and JSON keys exactly as given.'
    }
    return ''
}

# A system prompt with the language line appended (unchanged for English). The line becomes part
# of the prompt, so a narration cache keyed on the prompt is rebuilt when the language changes.
function Add-AiLanguageLine {
    param([Parameter(Mandatory)][string]$Prompt)
    $line = Get-AiLanguageLine
    # First and last: a long English prompt over English data otherwise drowns a single trailing line.
    if ($line) { return "LANGUAGE: $line`n`n$Prompt`n`nReminder: $line" }
    return $Prompt
}

# Every key in both languages (for the tests).
function Get-PortalTextKeys {
    param([ValidateSet('en', 'da')][string]$Language = 'en')
    return @($script:Texts[$Language].Keys)
}

Export-ModuleMember -Function Get-PortalLanguage, Get-PortalCulture, Format-PortalNumber, Get-PortalText, Get-AiLanguageLine, Add-AiLanguageLine, Get-PortalTextKeys
