#requires -Version 5.1
<#
.SYNOPSIS
  Buduje normy.json: wszystkie aktualne normy ISO z budownictwa i inżynierii lądowej (ICS 91 i 93).

.DESCRIPTION
  Źródło: otwarte dane ISO (ISO Open Data – metadane wszystkich dokumentów ISO, aktualizowane co tydzień).
  Plik ma ok. 80 MB, dlatego skrypt najpierw pobiera poprzedni normy.json z opublikowanej strony (-Previous)
  i jeśli jest młodszy niż -MaxAgeHours, używa go ponownie zamiast ściągać dane od nowa.
  Polskie Normy (PKN) nie mają otwartego źródła danych, więc ich listę prowadzi sama strona (index.html).
  Działa w PowerShell 5.1 i 7. Wywoływany z newsy.ps1 w GitHub Actions.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/normy.ps1 -Out normy.json
#>
param(
    [string]$Out = 'normy.json',
    [string]$Previous = '',
    [int]$MaxAgeHours = 20
)

$ErrorActionPreference = 'Stop'
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
$Utf8 = New-Object System.Text.UTF8Encoding $false
$IsoUrl = 'https://isopublicstorageprod.blob.core.windows.net/opendata/_latest/iso_deliverables_metadata/json/iso_deliverables_metadata.jsonl'

function Get-IsoBuilding {
    $wc = New-Object System.Net.WebClient
    $s = $wc.OpenRead($IsoUrl)
    $sr = New-Object System.IO.StreamReader($s, [System.Text.Encoding]::UTF8)
    $res = New-Object System.Collections.ArrayList
    try {
        while ($null -ne ($line = $sr.ReadLine())) {
            if ($line -notmatch '"9[13]\.') { continue }                                  # szybki filtr przed parsowaniem
            $o = $line | ConvertFrom-Json
            if ($o.supplementType) { continue }                                            # bez poprawek i errat
            if (@('IS', 'TS') -notcontains $o.deliverableType) { continue }               # normy i specyfikacje techniczne
            if ($o.currentStage -lt 6060 -or $o.currentStage -ge 9500) { continue }        # tylko opublikowane, niewycofane
            $ics = @($o.icsCode | Where-Object { $_ -match '^9[13]\.' })
            if (-not $ics.Count) { continue }
            [void]$res.Add([ordered]@{
                id    = $o.id
                ref   = $o.reference
                title = $o.title.en
                date  = [string]$o.publicationDate
                ics   = $ics[0]
                type  = $o.deliverableType
            })
        }
    } finally { $sr.Close(); $s.Close() }
    return , @($res | Sort-Object { $_.ics }, { $_.ref })
}

# --- poprzednia wersja (żeby nie pobierać 80 MB co 3 godziny) ---
$prevText = $null
if ($Previous) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $prevText = $wc.DownloadString($Previous)
        $prev = $prevText | ConvertFrom-Json
        $age = ((Get-Date).ToUniversalTime() - [DateTime]::Parse($prev.generated).ToUniversalTime()).TotalHours
        if ($age -lt $MaxAgeHours -and @($prev.iso).Count -gt 0) {
            [IO.File]::WriteAllText($Out, $prevText, $Utf8)
            Write-Host ("Normy: użyto wersji sprzed {0:N1} h" -f $age)
            return
        }
    } catch { Write-Host "Normy: brak poprzedniej wersji ($($_.Exception.Message))" }
}

try {
    $iso = Get-IsoBuilding
    $result = [ordered]@{
        generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        source    = 'ISO Open Data'
        iso       = $iso
    }
    [IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject $result -Depth 5 -Compress), $Utf8)
    Write-Host ("Normy ISO (budownictwo): {0}, zapisano {1}" -f $iso.Count, $Out)
} catch {
    if ($prevText) {
        [IO.File]::WriteAllText($Out, $prevText, $Utf8)
        Write-Host "Normy: błąd ($($_.Exception.Message)), zostawiono poprzednią wersję"
    } else { throw }
}
