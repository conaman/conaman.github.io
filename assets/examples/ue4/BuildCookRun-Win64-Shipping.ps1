param(
    [Parameter(Mandatory = $true)]
    [string]$EngineRoot,

    [Parameter(Mandatory = $true)]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [string]$ArchiveDir,

    [string]$Platform = "Win64",
    [string]$ClientConfig = "Shipping",
    [string]$Map = "",
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runUat = Join-Path $EngineRoot "Engine\Build\BatchFiles\RunUAT.bat"

if (-not (Test-Path $runUat)) {
    throw "RunUAT.bat not found: $runUat"
}

if (-not (Test-Path $Project)) {
    throw "Project file not found: $Project"
}

$uatArgs = @(
    "BuildCookRun"
    "-project=""$Project"""
    "-targetplatform=$Platform"
    "-clientconfig=$ClientConfig"
    "-build"
    "-cook"
    "-stage"
    "-pak"
    "-archive"
    "-archivedirectory=""$ArchiveDir"""
    "-prereqs"
    "-utf8output"
    "-unattended"
    "-NoP4"
)

if ($Map) {
    $uatArgs += "-map=$Map"
}

if ($Clean) {
    $uatArgs += "-clean"
}

Write-Host "Running: $runUat $($uatArgs -join ' ')"
& $runUat @uatArgs

if ($LASTEXITCODE -ne 0) {
    throw "BuildCookRun failed with exit code $LASTEXITCODE"
}

Write-Host "BuildCookRun completed successfully."
