<#
.SYNOPSIS
    Scan known C-drive space hogs and report size + junction status.
#>
param([switch] $Json)

$targets = @(
    @{ Name='Apple Backup';         Path="$env:USERPROFILE\Apple\MobileSync\Backup"          },
    @{ Name='npm cache';            Path="$env:LOCALAPPDATA\npm-cache"                       },
    @{ Name='npm global';           Path="$env:APPDATA\npm"                                  },
    @{ Name='pip cache';            Path="$env:LOCALAPPDATA\pip\cache"                       },
    @{ Name='Gradle cache';         Path="$env:USERPROFILE\.gradle"                          },
    @{ Name='Maven local repo';     Path="$env:USERPROFILE\.m2"                              },
    @{ Name='Old iTunes Backup';    Path="$env:APPDATA\Apple Computer\MobileSync\Backup"     }
)

$results = foreach ($t in $targets) {
    $exists = Test-Path $t.Path
    $sizeGB = 0
    $isJunction = $false
    if ($exists) {
        try {
            $item = Get-Item $t.Path -Force -ErrorAction SilentlyContinue
            $isJunction = ($item.LinkType -eq 'Junction')
            $sizeGB = [math]::Round(((Get-ChildItem $t.Path -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum / 1GB), 1)
        } catch { $sizeGB = -1 }
    }
    [PSCustomObject]@{ Name=$t.Name; Path=$t.Path; Exists=$exists; SizeGB=$sizeGB; IsJunction=$isJunction }
}

if ($Json) {
    $results | ConvertTo-Json -Compress
} else {
    $total = 0
    $header = "{0,-22} {1,10} {2,8} {3}" -f 'NAME', 'SIZE', 'STATUS', 'JUNCTION TARGET'
    Write-Host "`n  C-Drive Cache Scan`n" -ForegroundColor Cyan
    Write-Host $header
    Write-Host ('-' * 80)
    foreach ($r in $results) {
        if (-not $r.Exists) {
            Write-Host ("{0,-22} {1,10} {2,8}" -f $r.Name, '--', '(absent)') -ForegroundColor DarkGray
        } elseif ($r.IsJunction) {
            $size = if ($r.SizeGB -eq 0) { '0 GB' } else { "$($r.SizeGB) GB" }
            $junctionTarget = ((Get-Item $r.Path -Force).Target | Select-Object -First 1)
            Write-Host ("{0,-22} {1,10} {2,8} {3}" -f $r.Name, $size, 'JNCT', $junctionTarget) -ForegroundColor Green
        } else {
            $size = if ($r.SizeGB -eq 0) { '0 GB' } else { "$($r.SizeGB) GB" }
            Write-Host ("{0,-22} {1,10} {2,8}" -f $r.Name, $size, 'ON C') -ForegroundColor Yellow
            $total += $r.SizeGB
        }
    }
    Write-Host ('-' * 80)
    $color = if ($total -gt 5) { 'Red' } else { 'Green' }
    Write-Host "Total on C drive (not junctioned): $total GB" -ForegroundColor $color
    Write-Host ""
    Write-Host 'To migrate: powershell -File scripts/migrate.ps1 -Source "<path>" -Target "H:\Cache\<name>"' -ForegroundColor Cyan
}
