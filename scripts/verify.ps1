# verify.ps1
param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$tick = [char]0x2714
$cross = [char]0x2718
$line = "=" * 68
$rule = "-" * 68

function Get-FirstExistingPath([string[]]$Paths) {
    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }
    return $null
}

function Get-UninstallEntries {
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($root in $roots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName }
    }
}

$programFiles = $env:ProgramFiles
$programFilesX86 = ${env:ProgramFiles(x86)}
$localAppData = $env:LOCALAPPDATA

$officePaths = @()
$chromePaths = @()
$anyDeskPaths = @()
$winRarPaths = @()

if ($programFiles) {
    $officePaths += Join-Path $programFiles "Microsoft Office\root\Office16\WINWORD.EXE"
    $officePaths += Join-Path $programFiles "Microsoft Office\Office16\WINWORD.EXE"
    $chromePaths += Join-Path $programFiles "Google\Chrome\Application\chrome.exe"
    $anyDeskPaths += Join-Path $programFiles "AnyDesk\AnyDesk.exe"
    $winRarPaths += Join-Path $programFiles "WinRAR\WinRAR.exe"
}
if ($programFilesX86) {
    $officePaths += Join-Path $programFilesX86 "Microsoft Office\root\Office16\WINWORD.EXE"
    $officePaths += Join-Path $programFilesX86 "Microsoft Office\Office16\WINWORD.EXE"
    $chromePaths += Join-Path $programFilesX86 "Google\Chrome\Application\chrome.exe"
    $anyDeskPaths += Join-Path $programFilesX86 "AnyDesk\AnyDesk.exe"
    $winRarPaths += Join-Path $programFilesX86 "WinRAR\WinRAR.exe"
}
if ($localAppData) {
    $chromePaths += Join-Path $localAppData "Google\Chrome\Application\chrome.exe"
}

$uninstall = @(Get-UninstallEntries)
$nepaliEntry = $uninstall | Where-Object {
    $_.DisplayName -match '(?i)nepali.*roman|roman.*nepali'
} | Select-Object -First 1

$fontSource = Join-Path $Root "extracted\fonts"
$fontInstallDir = if ($localAppData) { Join-Path $localAppData "Microsoft\Windows\Fonts" } else { $null }
$fontSourceFiles = @()
$fontInstalledCount = 0
if (Test-Path $fontSource) {
    $fontSourceFiles = @(Get-ChildItem $fontSource -Recurse -File |
        Where-Object { $_.Extension -match '^\.(ttf|otf|ttc)$' })
}
$fontSourceCount = $fontSourceFiles.Count
if ($fontInstallDir -and (Test-Path $fontInstallDir)) {
    $fontInstalledNames = @(Get-ChildItem $fontInstallDir -File |
        Select-Object -ExpandProperty Name)
    $fontInstalledCount = @($fontSourceFiles | Where-Object { $_.Name -in $fontInstalledNames }).Count
}

$officePath = Get-FirstExistingPath $officePaths
$chromePath = Get-FirstExistingPath $chromePaths
$anyDeskPath = Get-FirstExistingPath $anyDeskPaths
$winRarPath = Get-FirstExistingPath $winRarPaths

$results = @(
    [pscustomobject]@{
        Item = "Microsoft Office"
        Verified = ($null -ne $officePath)
        Evidence = if ($officePath) { $officePath } else { "WINWORD.EXE not found" }
    },
    [pscustomobject]@{
        Item = "Google Chrome"
        Verified = ($null -ne $chromePath)
        Evidence = if ($chromePath) { $chromePath } else { "chrome.exe not found" }
    },
    [pscustomobject]@{
        Item = "AnyDesk"
        Verified = ($null -ne $anyDeskPath)
        Evidence = if ($anyDeskPath) { $anyDeskPath } else { "AnyDesk.exe not found" }
    },
    [pscustomobject]@{
        Item = "WinRAR"
        Verified = ($null -ne $winRarPath)
        Evidence = if ($winRarPath) { $winRarPath } else { "WinRAR.exe not found" }
    },
    [pscustomobject]@{
        Item = "Fonts"
        Verified = ($fontSourceCount -gt 0 -and $fontInstalledCount -gt 0)
        Evidence = if ($fontSourceCount -gt 0) {
            "$fontInstalledCount / $fontSourceCount font files installed"
        } else {
            "No extracted font files found"
        }
    },
    [pscustomobject]@{
        Item = "Nepali Romanized"
        Verified = ($null -ne $nepaliEntry)
        Evidence = if ($nepaliEntry) { $nepaliEntry.DisplayName } else { "Uninstall registry entry not found" }
    }
)

Write-Host ""
Write-Host $line -ForegroundColor Cyan
Write-Host ("{0,40}" -f "FINAL VERIFICATION") -ForegroundColor Cyan
Write-Host $line -ForegroundColor Cyan
Write-Host ""

$nameWidth = 24
foreach ($result in $results) {
    $glyph = if ($result.Verified) { $tick } else { $cross }
    $color = if ($result.Verified) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
    try {
        [Console]::ForegroundColor = $color
    } catch {}
    [Console]::Out.WriteLine(("  [{0}] {1} {2}" -f $glyph, $result.Item.PadRight($nameWidth), $result.Evidence))
    try {
        [Console]::ResetColor()
    } catch {}
}

$passed = @($results | Where-Object Verified).Count
$failed = $results.Count - $passed

Write-Host ""
Write-Host $rule -ForegroundColor DarkGray
if ($failed -eq 0) {
    Write-Host ("  ALL {0} ITEMS INSTALLED SUCCESSFULLY" -f $results.Count) -ForegroundColor Green
} else {
    Write-Host ("  {0} INSTALLED / {1} FAILED" -f $passed, $failed) -ForegroundColor Yellow
    $missing = @($results | Where-Object { -not $_.Verified } | ForEach-Object { $_.Item })
    Write-Host ("  Missing: {0}" -f ($missing -join ", ")) -ForegroundColor Red
}
Write-Host $rule -ForegroundColor DarkGray
Write-Host ""
