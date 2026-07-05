<#
.SYNOPSIS
    Verify all known junctions are alive and report broken ones.
#>

$checks = @(
    @{ Name='npm cache';            Path="$env:LOCALAPPDATA\npm-cache"                       },
    @{ Name='npm global';           Path="$env:APPDATA\npm"                                  },
    @{ Name='Apple Backup';         Path="$env:USERPROFILE\Apple\MobileSync\Backup"          },
    @{ Name='Old iTunes Backup';    Path="$env:APPDATA\Apple Computer\MobileSync\Backup"     },
    @{ Name='pip cache';            Path="$env:LOCALAPPDATA\pip\cache"                       },
    @{ Name='Gradle';               Path="$env:USERPROFILE\.gradle"                          },
    @{ Name='Maven';                Path="$env:USERPROFILE\.m2"                              }
)

$ok = 0; $broken = 0; $absent = 0; $onC = 0
$lines = @()

foreach ($c in $checks) {
    if (-not (Test-Path $c.Path)) {
        $lines += [PSCustomObject]@{ Name=$c.Name; Status='absent'; Detail='' }
        $absent++
        continue
    }
    $item = Get-Item $c.Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { continue }

    if ($item.LinkType -eq 'Junction') {
        $target = ($item.Target | Select-Object -First 1)
        if (Test-Path $target) {
            $lines += [PSCustomObject]@{ Name=$c.Name; Status='OK'; Detail="-> $target" }
            $ok++
        } else {
            $lines += [PSCustomObject]@{ Name=$c.Name; Status='BROKEN'; Detail="-> $target (target missing!)" }
            $broken++
        }
    } else {
        $lines += [PSCustomObject]@{ Name=$c.Name; Status='ON C'; Detail='(not a junction)' }
        $onC++
    }
}

$header = "{0,-22} {1,-8} {2}" -f 'NAME', 'STATUS', 'DETAIL'
Write-Host "`n  Junction Health Check`n" -ForegroundColor Cyan
Write-Host $header
Write-Host ('-' * 70)
foreach ($l in $lines) {
    $color = if ($l.Status -eq 'OK') { 'Green' }
        elseif ($l.Status -eq 'BROKEN') { 'Red' }
        elseif ($l.Status -eq 'ON C') { 'Yellow' }
        else { 'DarkGray' }
    Write-Host ("{0,-22} {1,-8} {2}" -f $l.Name, $l.Status, $l.Detail) -ForegroundColor $color
}
Write-Host ('-' * 70)
$summaryColor = if ($broken -gt 0) { 'Red' } else { 'Green' }
Write-Host "OK:$ok  Broken:$broken  Absent:$absent  On-C:$onC" -ForegroundColor $summaryColor
