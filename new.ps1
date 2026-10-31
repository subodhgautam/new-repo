# verify.ps1
# Optional independent verification script. Run after entry.ps1 finishes.
param([string]$Root = (Join-Path $env:TEMP "SubodhSetup"))

$pf86 = ${env:ProgramFiles(x86)}
$checks = @(
    [pscustomobject]@{
        Name = "Office"
        Paths = @(
            (Join-Path $env:ProgramFiles "Microsoft Office\root\Office16\WINWORD.EXE"),
            (Join-Path $pf86 "Microsoft Office\root\Office16\WINWORD.EXE"),
            (Join-Path $env:ProgramFiles "Microsoft Office\Office16\WINWORD.EXE"),
            (Join-Path $pf86 "Microsoft Office\Office16\WINWORD.EXE")
        )
    },
    [pscustomobject]@{
        Name = "Chrome"
        Paths = @(
            (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
            (Join-Path $pf86 "Google\Chrome\Application\chrome.exe"),
            (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
        )
    },
    [pscustomobject]@{
        Name = "AnyDesk"
        Paths = @(
            (Join-Path $env:ProgramFiles "AnyDesk\AnyDesk.exe"),
            (Join-Path $pf86 "AnyDesk\AnyDesk.exe")
        )
    },
    [pscustomobject]@{
        Name = "WinRAR"
        Paths = @(
            (Join-Path $env:ProgramFiles "WinRAR\WinRAR.exe"),
            (Join-Path $pf86 "WinRAR\WinRAR.exe")
        )
    }
)

Write-Host "`nINSTALLED APPLICATION CHECKS" -ForegroundColor Cyan
foreach ($check in $checks) {
    $found = $check.Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if ($found) {
        Write-Host "[FOUND] $($check.Name): $found" -ForegroundColor Green
    } else {
        Write-Host "[NOT FOUND] $($check.Name)" -ForegroundColor Red
    }
}

$fontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
$fontCount = if (Test-Path $fontDir) {
    @(Get-ChildItem $fontDir -File | Where-Object { $_.Extension -match '^\.(ttf|otf|ttc)$' }).Count
} else { 0 }
Write-Host "[$(if ($fontCount -gt 0) {'FOUND'} else {'NOT FOUND'})] User fonts: $fontCount files" `
    -ForegroundColor $(if ($fontCount -gt 0) {"Green"} else {"Red"})

$uninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$nepali = foreach ($rootPath in $uninstallRoots) {
    Get-ItemProperty -Path $rootPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '(?i)nepali.*roman|roman.*nepali' }
}
if ($nepali) {
    Write-Host "[FOUND] Nepali Romanized: $($nepali[0].DisplayName)" -ForegroundColor Green
} else {
    Write-Host "[NOT FOUND] Nepali Romanized registry entry (may need a different verification rule)" -ForegroundColor Yellow
}
