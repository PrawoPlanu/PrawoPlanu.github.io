#requires -Version 5.1
<#
.SYNOPSIS
  Pobiera „szybkie newsy” z architektury i budownictwa z całego świata i zapisuje je jako news.json.

.DESCRIPTION
  Uruchamiany przez GitHub Actions co kilka godzin (oraz lokalnie do testów).
  Czyta kanały RSS wybranych serwisów oraz wyniki Google News (świat i Polska),
  czyści tytuły i zajawki, odrzuca szum (np. „architektura oprogramowania”)
  i zapisuje najświeższe wpisy z ostatnich dni. „Gorące tematy” wylicza już sama strona.
  Działa w Windows PowerShell 5.1 i PowerShell 7.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/newsy.ps1 -Out news.json
#>
param(
    [string]$Out = 'news.json',
    [int]$Days = 7,
    [int]$PerSource = 40
)

$ErrorActionPreference = 'Stop'
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$Sources = @(
    @{ id = 'archdaily';   name = 'ArchDaily';                  region = 'swiat';   site = 'https://www.archdaily.com';             url = 'https://www.archdaily.com/feed' }
    @{ id = 'dezeen';      name = 'Dezeen';                     region = 'swiat';   site = 'https://www.dezeen.com';                url = 'https://www.dezeen.com/feed/' }
    @{ id = 'designboom';  name = 'designboom';                 region = 'swiat';   site = 'https://www.designboom.com';            url = 'https://www.designboom.com/feed/' }
    @{ id = 'gcr';         name = 'Global Construction Review'; region = 'swiat';   site = 'https://www.globalconstructionreview.com'; url = 'https://www.globalconstructionreview.com/feed/' }
    @{ id = 'cdive';       name = 'Construction Dive';          region = 'swiat';   site = 'https://www.constructiondive.com';      url = 'https://www.constructiondive.com/feeds/news/' }
    @{ id = 'ib';          name = 'Inżynier Budownictwa';       region = 'polska';  site = 'https://inzynierbudownictwa.pl';        url = 'https://inzynierbudownictwa.pl/feed/' }
    @{ id = 'gn-swiat';    name = 'Google News';                region = 'swiat';   site = 'https://news.google.com'; aggregator = $true
       url = 'https://news.google.com/rss/search?q=' + [uri]::EscapeDataString('(architecture OR architect OR "urban planning" OR "building code" OR "construction industry" OR "housing construction") -software -cloud -enterprise when:1d') + '&hl=en-US&gl=US&ceid=US:en' }
    @{ id = 'gn-polska';   name = 'Google News';                region = 'polska';  site = 'https://news.google.com'; aggregator = $true
       url = 'https://news.google.com/rss/search?q=' + [uri]::EscapeDataString('(architektura OR architekt OR budownictwo OR "prawo budowlane" OR "plan ogólny" OR "warunki techniczne" OR deweloper) when:2d') + '&hl=pl&gl=PL&ceid=PL:pl' }
)

# Szum: „architektura” w znaczeniu IT, finansów itp.
$Noise = 'software|cloud|enterprise architecture|microservice|data architecture|network architecture|security architecture|zero[- ]trust|semiconductor|chip|processor|\bGPU\b|\bAI architecture|blockchain|architektur\w* (IT|systemu|systemów|danych|bezpieczeństwa|oprogramowania|chmur)|krypto'

$TzMap = @{ 'UT' = '+00:00'; 'UTC' = '+00:00'; 'GMT' = '+00:00'; 'Z' = '+00:00'; 'EST' = '-05:00'; 'EDT' = '-04:00'; 'CST' = '-06:00'; 'CDT' = '-05:00';
            'MST' = '-07:00'; 'MDT' = '-06:00'; 'PST' = '-08:00'; 'PDT' = '-07:00'; 'CET' = '+01:00'; 'CEST' = '+02:00'; 'BST' = '+01:00' }

function ConvertTo-UtcIso([string]$Text) {
    if (-not $Text) { return $null }
    $s = $Text.Trim()
    $m = [regex]::Match($s, '\s([A-Z]{1,4})$')
    if ($m.Success -and $TzMap.ContainsKey($m.Groups[1].Value)) { $s = $s.Substring(0, $m.Index) + ' ' + $TzMap[$m.Groups[1].Value] }
    $s = $s -replace '^[A-Za-z]{3},\s*', ''                # bez dnia tygodnia
    $s = $s -replace '\s([+-]\d{2})(\d{2})$', ' $1:$2'      # +0000 -> +00:00
    $d = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) {
        return $d.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return $null
}

function Get-CleanText([string]$Html, [int]$Max = 0) {
    if (-not $Html) { return '' }
    $t = $Html -replace '(?s)<script.*?</script>', ' ' -replace '(?s)<style.*?</style>', ' ' -replace '<[^>]+>', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace '(?s)The post .*? appeared first on .*$', '' -replace '(?s)Artykuł .*? pochodzi z serwisu .*$', ''
    $t = ($t -replace '\s+', ' ').Trim()
    if ($Max -gt 0 -and $t.Length -gt $Max) {
        $cut = $t.Substring(0, $Max)
        $sp = $cut.LastIndexOf(' ')
        if ($sp -gt $Max * 0.6) { $cut = $cut.Substring(0, $sp) }
        $t = $cut.TrimEnd(' ', ',', '.', ';', ':', '-') + '…'
    }
    return $t
}

function Get-NodeText($Node, [string]$Names) {
    $xp = ($Names.Split(',') | ForEach-Object { "local-name()='$($_.Trim())'" }) -join ' or '
    $n = $Node.SelectSingleNode("*[$xp]")
    if ($n) { return $n.InnerText }
    return ''
}

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$Days)
$all = New-Object System.Collections.ArrayList
$seenLinks = @{}
$report = New-Object System.Collections.ArrayList

foreach ($src in $Sources) {
    $count = 0; $err = ''
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'Mozilla/5.0 (compatible; RSS reader)'
        $wc.Headers['Accept'] = 'application/rss+xml, application/atom+xml, application/xml, text/xml'
        $bytes = $wc.DownloadData($src.url)
        $xml = New-Object System.Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load((New-Object IO.MemoryStream(, $bytes)))
        $nodes = $xml.SelectNodes("//*[local-name()='item' or local-name()='entry']")
        foreach ($n in $nodes) {
            if ($count -ge $PerSource) { break }
            $title = Get-CleanText (Get-NodeText $n 'title')
            if (-not $title) { continue }

            $link = Get-NodeText $n 'link'
            if (-not $link) {
                $ln = $n.SelectSingleNode("*[local-name()='link']")
                if ($ln -and $ln.Attributes['href']) { $link = $ln.Attributes['href'].Value }
            }
            $link = $link.Trim()
            if (-not $link -or $seenLinks.ContainsKey($link)) { continue }

            $date = ConvertTo-UtcIso (Get-NodeText $n 'pubDate,published,updated,date')
            if (-not $date) { continue }
            if ([DateTime]::Parse($date).ToUniversalTime() -lt $cutoff) { continue }

            $outlet = $src.name
            $summary = ''
            if ($src.aggregator) {
                $s = $n.SelectSingleNode("*[local-name()='source']")
                if ($s -and $s.InnerText) {
                    $outlet = $s.InnerText.Trim()
                    $suffix = ' - ' + $outlet
                    if ($title.EndsWith($suffix)) { $title = $title.Substring(0, $title.Length - $suffix.Length).Trim() }
                }
            } else {
                $summary = Get-CleanText (Get-NodeText $n 'description,summary') 240
            }
            if ("$title $summary" -match $Noise) { continue }

            $seenLinks[$link] = $true
            [void]$all.Add([ordered]@{
                src     = $src.id
                outlet  = $outlet
                via     = $(if ($src.aggregator) { 'Google News' } else { '' })
                region  = $src.region
                title   = $title
                link    = $link
                date    = $date
                summary = $summary
            })
            $count++
        }
    } catch {
        $err = $_.Exception.Message
    }
    [void]$report.Add([ordered]@{ id = $src.id; name = $src.name; region = $src.region; site = $src.site; ok = (-not $err); count = $count; error = $err })
    Write-Host ("{0,-12} {1,3} wpisów {2}" -f $src.id, $count, $err)
}

$items = @($all | Sort-Object { $_.date } -Descending | Select-Object -First 500)
$result = [ordered]@{
    generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    days      = $Days
    sources   = @($report)
    items     = $items
}
$json = ConvertTo-Json -InputObject $result -Depth 6 -Compress
$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host ("Zapisano {0} wpisów do {1}" -f $items.Count, $Out)

# Normy ISO (normy.json obok news.json) – osobny skrypt, błąd nie zatrzymuje publikacji newsów
$normyScript = Join-Path $PSScriptRoot 'normy.ps1'
if (Test-Path $normyScript) {
    $prevUrl = ''
    if ($env:GITHUB_REPOSITORY) {
        $owner, $repo = $env:GITHUB_REPOSITORY.Split('/')
        if ($repo -ieq "$owner.github.io") { $site = "https://$($owner.ToLower()).github.io/" } else { $site = "https://$($owner.ToLower()).github.io/$repo/" }
        $prevUrl = $site + 'normy.json'
    }
    try { & $normyScript -Out (Join-Path (Split-Path -Parent $Out) 'normy.json') -Previous $prevUrl }
    catch { Write-Host "Normy: $($_.Exception.Message)" }
}
