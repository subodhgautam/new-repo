# verify.ps1
param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = "Continue"

function Test-ExecutableInPaths([string[]]$Paths) {
    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }
    }
    return $false
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

$programFilesX86 = ${env:ProgramFiles(x86)}
$officePaths = @(
    (Join-Path $env:ProgramFiles "Microsoft Office\root\Office16\WINWORD.EXE"),
    (Join-Path $programFilesX86 "Microsoft Office\root\Office16\WINWORD.EXE"),
    (Join-Path $env:ProgramFiles "Microsoft Office\Office16\WINWORD.EXE"),
    (Join-Path $programFilesX86 "Microsoft Office\Office16\WINWORD.EXE")
)
$chromePaths = @(
    (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
    (Join-Path $programFilesX86 "Google\Chrome\Application\chrome.exe"),
    (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
)
$anyDeskPaths = @(
    (Join-Path $env:ProgramFiles "AnyDesk\AnyDesk.exe"),
    (Join-Path $programFilesX86 "AnyDesk\AnyDesk.exe")
)
$winRarPaths = @(
    (Join-Path $env:ProgramFiles "WinRAR\WinRAR.exe"),
    (Join-Path $programFilesX86 "WinRAR\WinRAR.exe")
)

$uninstall = @(Get-UninstallEntries)
$nepaliEntry = $uninstall | Where-Object {
    $_.DisplayName -match '(?i)nepali.*roman|roman.*nepali'
} | Select-Object -First 1

$fontSource = Join-Path $Root "extracted\fonts"
$fontInstallDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
$fontSourceFiles = @()
$fontInstalledCount = 0
if (Test-Path $fontSource) {
    $fontSourceFiles = @(Get-ChildItem $fontSource -Recurse -File |
        Where-Object { $_.Extension -match '^\.(ttf|otf|ttc)$' })
}
$fontSourceCount = $fontSourceFiles.Count
if (Test-Path $fontInstallDir) {
    $fontInstalledNames = @(Get-ChildItem $fontInstallDir -File |
        Select-Object -ExpandProperty Name)
    $fontInstalledCount = @($fontSourceFiles | Where-Object { $_.Name -in $fontInstalledNames }).Count
}

$results = @(
    [pscustomobject]@{ Item = "Microsoft Office"; Verified = (Test-ExecutableInPaths $officePaths); Evidence = "WINWORD.EXE" },
    [pscustomobject]@{ Item = "Google Chrome"; Verified = (Test-ExecutableInPaths $chromePaths); Evidence = "chrome.exe" },
    [pscustomobject]@{ Item = "AnyDesk"; Verified = (Test-ExecutableInPaths $anyDeskPaths); Evidence = "AnyDesk.exe" },
    [pscustomobject]@{ Item = "WinRAR"; Verified = (Test-ExecutableInPaths $winRarPaths); Evidence = "WinRAR.exe" },
    [pscustomobject]@{ Item = "Fonts"; Verified = ($fontSourceCount -gt 0 -and $fontInstalledCount -gt 0); Evidence = "$fontInstalledCount / $fontSourceCount archive font files found in current-user Fonts folder" },
    [pscustomobject]@{ Item = "Nepali Romanized"; Verified = ($null -ne $nepaliEntry); Evidence = if ($nepaliEntry) { $nepaliEntry.DisplayName } else { "No matching uninstall-registry entry detected" } }
)

Write-Host "`nFINAL VERIFICATION REPORT" -ForegroundColor Cyan
Write-Host "-------------------------" -ForegroundColor Cyan
foreach ($result in $results) {
    if ($result.Verified) {
        Write-Host ("[PASS] {0} — {1}" -f $result.Item, $result.Evidence) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] {0} — {1}" -f $result.Item, $result.Evidence) -ForegroundColor Red
    }
}

$passed = @($results | Where-Object Verified).Count
Write-Host "`nVerified: $passed / $($results.Count)" -ForegroundColor Cyan
if ($passed -ne $results.Count) {
    Write-Host "Some items could not be verified. Check installer logs and adjust the relevant detection rule if the software uses a different install location or registry name." -ForegroundColor Yellow
}
