# nentry.ps1
# Compatible with: irm https://subodhgautam.github.io/new-repo/newversions/nentry.ps1 | iex
# Thin launcher for the shared parallel engine in scripts/engine.ps1.

$BaseUrl = "https://subodhgautam.github.io/new-repo"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$engineUrl = "$BaseUrl/scripts/engine.ps1"
try {
    $engine = Invoke-RestMethod -Uri $engineUrl -UseBasicParsing
} catch {
    Write-Host "Could not download the installer engine: $($_.Exception.Message)" -ForegroundColor Red
    return
}

& ([scriptblock]::Create($engine)) -BaseUrl $BaseUrl -VerifyRelativeUrl "newversions/nverify.ps1" -VerifyFileName "nverify.ps1"
