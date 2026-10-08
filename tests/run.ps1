#Requires -Version 5.1

$testScript = Join-Path $PSScriptRoot 'test_cjman.ps1'
& $testScript
if (-not $?) {
    exit 1
}

$metadataTest = Join-Path $PSScriptRoot 'test_formal_metadata.mjs'
$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
if ($null -eq $node) {
    Write-Error 'Node.js 18.1 or newer is required for metadata tests.'
    exit 1
}

$nodeVersion = & $node.Path --version 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error 'Could not query the Node.js version.'
    exit 1
}
$nodeVersionMatch = [regex]::Match(
    [string]$nodeVersion,
    '^v([0-9]+)\.([0-9]+)\.'
)
if (-not $nodeVersionMatch.Success) {
    Write-Error "Could not parse Node.js version '$nodeVersion'."
    exit 1
}
$nodeMajor = [int]$nodeVersionMatch.Groups[1].Value
$nodeMinor = [int]$nodeVersionMatch.Groups[2].Value
if ($nodeMajor -lt 18 -or ($nodeMajor -eq 18 -and $nodeMinor -lt 1)) {
    Write-Error 'Node.js 18.1 or newer is required for metadata tests.'
    exit 1
}

& $node.Path --test $metadataTest
exit $LASTEXITCODE
