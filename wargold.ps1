<#
  Wardogs Gold -> Discord
  Reads today's WARDOGS gold bar price from community trackers and posts it
  to a Discord channel through a webhook. Safe to run as often as you like:
  it only posts once per UTC day (the in-game price resets at 00:00 UTC).

  Usage:
    .\wargold.ps1           normal run (what the scheduled task does)
    .\wargold.ps1 -Test     fetch and print the price, post nothing
    .\wargold.ps1 -Force    post right now even if today was already posted
#>
param(
    [switch]$Test,
    [switch]$Force,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$StatePath  = (Join-Path $PSScriptRoot 'state.json'),
    [string]$LogPath    = (Join-Path $PSScriptRoot 'wargold.log'),
    # For testing only: a folder of saved pages named <source-id>.html used instead of the web
    [string]$OfflineDir = ''
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------- helpers
function Write-Log([string]$msg) {
    $line = '{0:u}  {1}' -f (Get-Date).ToUniversalTime(), $msg
    Write-Host $line
    try {
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
        # keep the log small
        $lines = Get-Content -Path $LogPath -Encoding UTF8
        if ($lines.Count -gt 2000) { $lines | Select-Object -Last 1000 | Set-Content -Path $LogPath -Encoding UTF8 }
    } catch {}
}

function Get-Page([string]$id, [string]$url) {
    if ($OfflineDir) {
        $f = Join-Path $OfflineDir "$id.html"
        if (Test-Path $f) { return [IO.File]::ReadAllText($f) }
        throw "no offline file $f"
    }
    $headers = @{
        'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36'
        'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        'Accept-Language' = 'en-US,en;q=0.9'
    }
    $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 30
    return [string]$resp.Content
}

function Get-PlainText([string]$html) {
    $t = [regex]::Replace($html, '(?is)<(script|style)[^>]*>.*?</\1>', ' ')
    $t = [regex]::Replace($t, '(?s)<[^>]+>', ' ')
    $t = $t -replace '&nbsp;|&#160;', ' ' -replace '&amp;', '&' -replace '&#36;|&dollar;', '$' -replace '&#x2c;|&#44;', ','
    return ($t -replace '\s+', ' ')
}

function ConvertTo-Price([string]$s) {
    $n = [int64]($s -replace '[^\d]', '')
    if ($n -lt 1000 -or $n -gt 1000000000) { throw "implausible price $n" }
    return $n
}

function Format-Cash([int64]$n) { return '$' + $n.ToString('N0', [Globalization.CultureInfo]::InvariantCulture) }

# ---------------------------------------------------------------- sources
# Each parser returns @{ Price = <int64>; Date = <yyyy-MM-dd or $null> }.
# A source that states its date lets us confirm the price is today's.
$Sources = @(
    @{
        Id = 'wardogshub'; Name = 'WardogsHub'; Url = 'https://wardogshub.gg/gold-market/'
        Parse = {
            param($html)
            $m = [regex]::Match($html, 'costs\s*\$\s*([\d,]+)\s*on\s*(\d{1,2}\s+[A-Za-z]+\s+\d{4})')
            if (-not $m.Success) { $m = [regex]::Match((Get-PlainText $html), 'costs\s*\$\s*([\d,]+)\s*on\s*(\d{1,2}\s+[A-Za-z]+\s+\d{4})') }
            if (-not $m.Success) { throw 'price sentence not found' }
            $d = [datetime]::ParseExact(($m.Groups[2].Value -replace 'Sept', 'Sep'), [string[]]@('d MMMM yyyy', 'd MMM yyyy'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
            @{ Price = (ConvertTo-Price $m.Groups[1].Value); Date = $d.ToString('yyyy-MM-dd') }
        }
    },
    @{
        Id = 'wardogstats'; Name = 'Wardogstats'; Url = 'https://wardogstats.app/gold'
        Parse = {
            param($html)
            $t = Get-PlainText $html
            # "1 gold bar on Tuesday, October 13 $229,361" (no year shown; assume the current UTC year)
            $m = [regex]::Match($t, '(?i)1\s+gold\s+bar\s+on\s+[A-Za-z]+,?\s+([A-Za-z]+)\s+(\d{1,2})\s*\$\s*([\d,]{4,})')
            if ($m.Success) {
                $ds = '{0} {1} {2}' -f $m.Groups[2].Value, ($m.Groups[1].Value -replace 'Sept', 'Sep'), (Get-Date).ToUniversalTime().Year
                $d = [datetime]::ParseExact($ds, [string[]]@('d MMMM yyyy', 'd MMM yyyy'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
                return @{ Price = (ConvertTo-Price $m.Groups[3].Value); Date = $d.ToString('yyyy-MM-dd') }
            }
            $m = [regex]::Match($t, '\$\s*([\d,]{5,})\s*(per|/|a|each)?\s*(gold\s*)?bar', 'IgnoreCase')
            if (-not $m.Success) { $m = [regex]::Match($t, '(?i)gold\s*bar[^$]{0,80}\$\s*([\d,]{5,})') }
            if (-not $m.Success) { throw 'price not found' }
            @{ Price = (ConvertTo-Price $m.Groups[1].Value); Date = $null }
        }
    },
    @{
        Id = 'metaforge'; Name = 'MetaForge'; Url = 'https://metaforge.app/wardogs/market'
        Parse = {
            param($html)
            $t = Get-PlainText $html
            # "Gold Bar Market ... Current 229,361 7 days -50.04%"
            $m = [regex]::Match($t, '(?i)\bCurrent\s*\$?\s*([\d,]{4,})')
            if (-not $m.Success) { $m = [regex]::Match($t, '(?i)([\d,]{5,})\s*cash\s*per\s*gold\s*bar') }
            if (-not $m.Success) { throw 'price not found' }
            @{ Price = (ConvertTo-Price $m.Groups[1].Value); Date = $null }
        }
    }
)

# ---------------------------------------------------------------- config & state
# Settings come from config.json, or (on GitHub Actions) from secrets passed in as environment variables:
#   WARGOLD_CONFIG  the whole config.json contents, or
#   WEBHOOK_URLS    one or more webhook URLs, one per line (or separated by commas or spaces)
if (Test-Path $ConfigPath) {
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} elseif ($env:WARGOLD_CONFIG) {
    $cfg = $env:WARGOLD_CONFIG | ConvertFrom-Json
} elseif ($env:WEBHOOK_URLS) {
    $cfg = [pscustomobject]@{
        webhook_url = @($env:WEBHOOK_URLS -split '[\s,]+' | Where-Object { $_ })
        mode        = if ($env:WARGOLD_MODE) { $env:WARGOLD_MODE } else { 'post' }
        ping        = [string]$env:WARGOLD_PING
        username    = 'Wardogs Gold'
    }
} else {
    throw "Missing $ConfigPath - copy config.example.json to config.json and add your webhook URL (or set the WEBHOOK_URLS secret on GitHub)."
}
$graceHour = if ($null -ne $cfg.unconfirmed_post_after_utc_hour) { [int]$cfg.unconfirmed_post_after_utc_hour } else { 6 }

# Webhooks: "webhook_url" can be one URL or a list of URLs. "webhooks" can be a list of URLs or of
# objects like { "url": "...", "mode": "edit", "ping": "<@&123>", "username": "..." }.
# Anything a webhook doesn't set comes from the top-level "mode", "ping" and "username".
$hookEntries = @()
foreach ($h in @($cfg.webhook_url) + @($cfg.webhooks)) {
    if ($null -eq $h) { continue }
    if ($h -is [string]) { $h = [pscustomobject]@{ url = $h } }
    if (-not $h.url -or ([string]$h.url) -match 'PASTE_YOUR') { continue }
    $url = ([string]$h.url).Trim()
    $m = [regex]::Match($url, '^https://(discord|discordapp|ptb\.discord|canary\.discord)\.com/api/webhooks/(\d+)/[\w-]+')
    if (-not $m.Success) { Write-Log "Skipping a webhook that doesn't look like a Discord webhook URL: $($url.Substring(0, [math]::Min(45, $url.Length)))..."; continue }
    $hookEntries += [pscustomobject]@{
        Id       = $m.Groups[2].Value
        Url      = $url.Split('?')[0].TrimEnd('/')
        Mode     = if ($h.mode) { [string]$h.mode } elseif ($cfg.mode) { [string]$cfg.mode } else { 'post' }   # 'post' = new message each day, 'edit' = keep one message updated
        Ping     = if ($null -ne $h.ping) { [string]$h.ping } else { [string]$cfg.ping }
        Username = if ($h.username) { [string]$h.username } else { [string]$cfg.username }
    }
}
$hookEntries = @($hookEntries | Group-Object Id | ForEach-Object { $_.Group[0] })   # ignore duplicates
if ($hookEntries.Count -eq 0 -and -not $Test) { throw 'No valid Discord webhook URL in config.json.' }

$state = $null
if (Test-Path $StatePath) { try { $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null } }

# Per-webhook memory: the message to edit and the last day it was posted to.
$hookState = @{}
if ($state -and $state.hooks) {
    foreach ($p in $state.hooks.PSObject.Properties) { $hookState[$p.Name] = @{ message_id = [string]$p.Value.message_id; date = [string]$p.Value.date } }
} elseif ($state -and $state.message_id -and $hookEntries.Count -gt 0) {
    # state.json from the single-webhook version: it belongs to the first webhook
    $hookState[$hookEntries[0].Id] = @{ message_id = [string]$state.message_id; date = [string]$state.date }
}

$nowUtc = (Get-Date).ToUniversalTime()
$today = $nowUtc.ToString('yyyy-MM-dd')

$pending = @($hookEntries | Where-Object { $Force -or -not $hookState[$_.Id] -or $hookState[$_.Id].date -ne $today })
if (-not $Test -and $pending.Count -eq 0) {
    Write-Log "Already posted for $today ($(Format-Cash ([int64]$state.price))) to all $($hookEntries.Count) webhook(s). Nothing to do."
    exit 0
}

if (-not $Test -and -not $Force -and $state -and $state.date -eq $today -and $state.price) {
    # Today's price is already known; just post it to the webhooks that haven't had it yet.
    $price = [int64]$state.price
    $prevPrice = if ($state.prev_price) { [int64]$state.prev_price } else { $null }
    $agree = @(@($state.sources) | Where-Object { $_ })
    if ($agree.Count -eq 0) { $agree = @('community trackers') }
    Write-Log "Posting today's $(Format-Cash $price) to $($pending.Count) webhook(s) that haven't had it yet."
} else {
    # ------------------------------------------------------------ fetch
    $results = @()
    foreach ($s in $Sources) {
        try {
            $html = Get-Page $s.Id $s.Url
            $r = & $s.Parse $html
            $results += [pscustomobject]@{ Id = $s.Id; Name = $s.Name; Price = [int64]$r.Price; Date = $r.Date }
            Write-Log ("{0,-12} {1}{2}" -f $s.Name, (Format-Cash $r.Price), $(if ($r.Date) { "  (dated $($r.Date))" } else { '' }))
        } catch {
            Write-Log ("{0,-12} failed: {1}" -f $s.Name, $_.Exception.Message)
        }
    }
    if ($results.Count -eq 0) { Write-Log 'No source returned a price. Will try again next run.'; exit 1 }

    # Drop sources that say they are showing a different day.
    $usable = @($results | Where-Object { -not $_.Date -or $_.Date -eq $today })
    if ($usable.Count -eq 0) { Write-Log "Sources haven't updated to $today yet. Will try again next run."; exit 0 }

    # Pick the price: one confirmed by a source dated today wins; otherwise the most common
    # price; ties go to the earlier (more trusted) source.
    $groups = @($usable | Group-Object Price | Sort-Object @{ Expression = { [bool]($_.Group | Where-Object { $_.Date -eq $today }) }; Descending = $true }, @{ Expression = 'Count'; Descending = $true }, @{ Expression = { [array]::IndexOf(@($usable.Id), $_.Group[0].Id) } })
    $price = [int64]$groups[0].Name
    $agree = @($groups[0].Group | ForEach-Object { $_.Name })
    if ($groups.Count -gt 1) { Write-Log ("Sources disagree; using {0} (from {1})" -f (Format-Cash $price), ($agree -join ', ')) }

    # Compare with the last posted day (on a same-day rerun, with the day before that).
    $prevPrice = $null
    if ($state) {
        if ($state.date -ne $today -and $state.price) { $prevPrice = [int64]$state.price }
        elseif ($state.date -eq $today -and $state.prev_price) { $prevPrice = [int64]$state.prev_price }
    }

    # Is this really today's price? Confirmed if a dated source says so, or the price moved.
    $confirmed = [bool]($usable | Where-Object { $_.Date -eq $today -and $_.Price -eq $price }) -or ($null -eq $prevPrice) -or ($price -ne $prevPrice)
    if (-not $confirmed -and -not $Force -and $nowUtc.Hour -lt $graceHour) {
        Write-Log "Price unchanged and not yet confirmed for $today; waiting for trackers to update."
        exit 0
    }
}

# ---------------------------------------------------------------- message
$e = @{
    up    = [char]::ConvertFromUtf32(0x1F4C8)
    down  = [char]::ConvertFromUtf32(0x1F4C9)
    flat  = [char]::ConvertFromUtf32(0x2796)
    gold  = [char]::ConvertFromUtf32(0x1FA99)
    minus = [string][char]0x2212
}
$changeLine = 'First reading - no previous price yet.'
$color = 0xF1C40F
if ($null -ne $prevPrice -and $prevPrice -gt 0) {
    $diff = $price - $prevPrice
    $pct = [math]::Round(100.0 * $diff / $prevPrice, 1)
    if ($diff -gt 0)     { $changeLine = "$($e.up) +$(Format-Cash $diff) (+$pct%) vs $(Format-Cash $prevPrice)"; $color = 0x2ECC71 }
    elseif ($diff -lt 0) { $changeLine = "$($e.down) $($e.minus)$(Format-Cash (-$diff)) ($($e.minus)$([math]::Abs($pct))%) vs $(Format-Cash $prevPrice)"; $color = 0xE74C3C }
    else                 { $changeLine = "$($e.flat) No change since last update" }
}
$cashFor1m = if ($price -gt 0) { [math]::Round(1000000.0 / $price, 2) } else { 0 }

$embed = @{
    title       = "$($e.gold) WARDOGS Gold - $($nowUtc.ToString('ddd d MMM yyyy', [Globalization.CultureInfo]::InvariantCulture))"
    description = "**$(Format-Cash $price)** per gold bar`n$changeLine"
    color       = $color
    fields      = @(@{ name = '$1,000,000 buys'; value = "$cashFor1m bars"; inline = $true })
    footer      = @{ text = "Resets 00:00 UTC - source: $($agree -join ', ')" }
    timestamp   = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function New-Payload($hook) {
    $p = @{ embeds = @($embed); allowed_mentions = @{ parse = @() } }
    if ($hook.Username) { $p.username = $hook.Username }
    if ($hook.Ping)     { $p.content = $hook.Ping; $p.allowed_mentions = @{ parse = @('roles', 'everyone', 'users') } }
    return $p
}

if ($Test) {
    Write-Log "TEST: would post $(Format-Cash $price) for $today to $($hookEntries.Count) webhook(s). Nothing sent."
    foreach ($h in $hookEntries) { Write-Log "  webhook ...$($h.Id.Substring([math]::Max(0, $h.Id.Length - 6)))  mode=$($h.Mode)$(if ($h.Ping) { "  ping=$($h.Ping)" })" }
    New-Payload ([pscustomobject]@{ Username = [string]$cfg.username; Ping = [string]$cfg.ping }) | ConvertTo-Json -Depth 6
    exit 0
}

# ---------------------------------------------------------------- send
$failed = 0
foreach ($h in $pending) {
    $label = "webhook ...$($h.Id.Substring([math]::Max(0, $h.Id.Length - 6)))"
    $body = [Text.Encoding]::UTF8.GetBytes(((New-Payload $h) | ConvertTo-Json -Depth 6 -Compress))
    $old = $hookState[$h.Id]
    $messageId = $null
    try {
        if ($h.Mode -eq 'edit' -and $old -and $old.message_id) {
            try {
                $null = Invoke-RestMethod -Method Patch -Uri "$($h.Url)/messages/$($old.message_id)" -Body $body -ContentType 'application/json; charset=utf-8'
                $messageId = $old.message_id
                Write-Log "$label  edited message $messageId"
            } catch { Write-Log "$label  couldn't edit old message ($($_.Exception.Message)); posting a new one." }
        }
        if (-not $messageId) {
            $resp = Invoke-RestMethod -Method Post -Uri "$($h.Url)?wait=true" -Body $body -ContentType 'application/json; charset=utf-8'
            $messageId = [string]$resp.id
            Write-Log "$label  posted message $messageId"
        }
        $hookState[$h.Id] = @{ message_id = $messageId; date = $today }
    } catch {
        $failed++
        Write-Log "$label  FAILED: $($_.Exception.Message) (will retry next run)"
    }
    Start-Sleep -Milliseconds 300
}

@{ date = $today; price = $price; prev_price = $prevPrice; sources = $agree; hooks = $hookState; posted_at = $nowUtc.ToString('o') } |
    ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
Write-Log "Done: $(Format-Cash $price) for $today ($($pending.Count - $failed) of $($pending.Count) webhook(s) updated)"
if ($failed -gt 0) { exit 1 }
