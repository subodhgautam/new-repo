
param(
    [Parameter(Mandatory = $true)]
    [string]$FontDirectory
)

$ErrorActionPreference = "Stop"

Write-Host "`n==================================" -ForegroundColor Cyan
Write-Host "       FONT INSTALLATION" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan

# Check administrator privileges
$isAdmin = (
    [Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    throw "Font installation requires administrator privileges."
}

# Validate source directory
if (-not (Test-Path $FontDirectory -PathType Container)) {
    throw "Font directory not found: $FontDirectory"
}

# Windows font directory
$windowsFontDirectory = Join-Path $env:WINDIR "Fonts"

# Registry location for installed fonts
$fontRegistry = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

# Supported font formats
$fontFiles = @(
    Get-ChildItem -Path $FontDirectory -Recurse -File |
        Where-Object {
            $_.Extension -match '^\.(ttf|otf|ttc)$'
        }
)

if ($fontFiles.Count -eq 0) {
    throw "No supported font files found."
}

Write-Host "`nFound $($fontFiles.Count) font files." -ForegroundColor Cyan

$installed = 0
$skipped = 0
$failed = 0

foreach ($font in $fontFiles) {

    try {

        $destination = Join-Path $windowsFontDirectory $font.Name

        # Check whether the font is already registered.
        $existingRegistryEntry = Get-ItemProperty `
            -Path $fontRegistry `
            -ErrorAction SilentlyContinue

        $alreadyInstalled = $false

        if (Test-Path $destination) {
            $alreadyInstalled = $true
        }

        if ($alreadyInstalled) {

            Write-Host "[ALREADY INSTALLED] $($font.Name)" `
                -ForegroundColor DarkGray

            $skipped++
            continue
        }

        # Copy font file
        Copy-Item `
            -Path $font.FullName `
            -Destination $destination `
            -Force

        # Determine font display name
        $fontName = [System.IO.Path]::GetFileNameWithoutExtension(
            $font.Name
        )

        $registryName = "$fontName (TrueType)"

        if ($font.Extension -eq ".otf") {
            $registryName = "$fontName (OpenType)"
        }

        # Register font with Windows
        New-ItemProperty `
            -Path $fontRegistry `
            -Name $registryName `
            -Value $font.Name `
            -PropertyType String `
            -Force | Out-Null

        Write-Host "[INSTALLED] $($font.Name)" -ForegroundColor Green

        $installed++

    }
    catch {

        Write-Host "[FAILED] $($font.Name): $($_.Exception.Message)" `
            -ForegroundColor Red

        $failed++
    }
}

# Notify Windows that fonts have changed
if ($installed -gt 0) {

    Add-Type @"
using System;
using System.Runtime.InteropServices;

public class FontNotification {
    [DllImport("gdi32.dll", EntryPoint="AddFontResourceW",
        CharSet=CharSet.Unicode)]
    public static extern int AddFontResource(string fileName);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        UIntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult
    );
}
"@

    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_FONTCHANGE = 0x001D
    $result = [UIntPtr]::Zero

    [FontNotification]::SendMessageTimeout(
        $HWND_BROADCAST,
        $WM_FONTCHANGE,
        [UIntPtr]::Zero,
        $null,
        2,
        1000,
        [ref]$result
    ) | Out-Null
}

# Final report
Write-Host "`n==================================" -ForegroundColor Cyan
Write-Host "       FONT INSTALLATION REPORT" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan

Write-Host "Total found: $($fontFiles.Count)"
Write-Host "Installed:   $installed" -ForegroundColor Green
Write-Host "Skipped:     $skipped" -ForegroundColor Yellow
Write-Host "Failed:      $failed" -ForegroundColor Red

if ($failed -gt 0) {
    throw "$failed font installations failed."
}

Write-Host "`nFont installation completed." -ForegroundColor Green
