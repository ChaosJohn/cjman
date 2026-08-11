#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$TestDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $TestDirectory
$TestRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ('cjman-powershell-tests-' + [Guid]::NewGuid().ToString('N'))

$TestsRun = 0
$TestsFailed = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Actual,

        [string]$Message = 'values differ'
    )

    if ([string]$Expected -cne [string]$Actual) {
        throw "$Message; expected <$Expected>, actual <$Actual>"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [string]$Message = 'condition is false'
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Test {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )

    $script:TestsRun++
    try {
        & $Body
        Write-Host "ok $script:TestsRun - $Name"
    } catch {
        $script:TestsFailed++
        Write-Host "not ok $script:TestsRun - $Name"
        Write-Host "    $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Path $TestRoot -ErrorAction Stop | Out-Null
$env:CJMAN_HOME = $ProjectRoot
$env:CJMAN_METADATA_ROOT = $ProjectRoot
$env:CANGJIE_BUNDLES = Join-Path $TestRoot 'bundles'

. (Join-Path $ProjectRoot 'cjman.ps1')

Write-Host 'TAP version 13'

Invoke-Test 'PowerShell entrypoints parse without errors' {
    foreach ($relativePath in @('cjman.ps1', 'cjman-installer.ps1')) {
        $tokens = $null
        $errors = $null
        $path = Join-Path $ProjectRoot $relativePath
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$tokens,
            [ref]$errors
        )
        Assert-Equal 0 $errors.Count "$relativePath has parser errors"
    }
}

Invoke-Test 'formal aliases resolve from the local v2 catalog' {
    Assert-Equal '1.1.3' `
        (Resolve-CjmanVersion -RequestedVersion latest).Version
    Assert-Equal '1.0.5' `
        (Resolve-CjmanVersion -RequestedVersion lts).Version
    Assert-Equal '1.1.3' `
        (Resolve-CjmanVersion -RequestedVersion sts).Version
}

Invoke-Test 'Windows formal selection chooses ZIP, never EXE' {
    $configuration = Resolve-CjmanTargetConfiguration `
        -Target native `
        -HostArch x64
    $asset = Select-CjmanFormalSdkAsset `
        -Version 1.1.3 `
        -Configuration $configuration
    Assert-Equal 'zip' $asset.Format
    Assert-Equal 'cangjie-sdk-windows-x64-1.1.3.zip' $asset.Filename
}

Invoke-Test 'native target architecture must match the host' {
    $threw = $false
    try {
        [void](Resolve-CjmanTargetConfiguration `
            -Target native `
            -TargetArch arm32 `
            -HostArch x64)
    } catch {
        $threw = $true
    }
    Assert-True $threw 'native arm32 was accepted for an x64 host'
}

Invoke-Test 'native install paths isolate Windows host architectures' {
    $x64 = Resolve-CjmanTargetConfiguration -Target native -HostArch x64
    $aarch64 = Resolve-CjmanTargetConfiguration -Target native -HostArch aarch64
    $x64Path = Get-CjmanReleasePath -Version 1.1.3 -Configuration $x64
    $aarch64Path = Get-CjmanReleasePath -Version 1.1.3 -Configuration $aarch64

    Assert-True ($x64Path -ne $aarch64Path) `
        'native x64 and aarch64 installations share one directory'
    Assert-True $x64Path.EndsWith('cangjie-1.1.3-windows-x64-native-x64') `
        'native x64 installation path lost host identity'
    Assert-True $aarch64Path.EndsWith('cangjie-1.1.3-windows-aarch64-native-aarch64') `
        'native aarch64 installation path lost host identity'
}

Invoke-Test 'legacy native layout remains discoverable without cross-target reuse' {
    $version = '9.8.7'
    $legacy = Join-Path $env:CANGJIE_BUNDLES "cangjie-$version"
    New-Item -ItemType Directory -Path $legacy -Force -ErrorAction Stop | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $legacy 'envsetup.ps1') `
        -Value '# legacy SDK' `
        -Encoding UTF8

    $native = Resolve-CjmanTargetConfiguration -Target native -HostArch x64
    $resolved = Resolve-CjmanReleasePath `
        -Version $version `
        -Configuration $native `
        -SuppressLegacyWarning
    Assert-True ($resolved -ne $legacy) `
        'explicit host override reused a legacy native SDK'

    $native.AllowLegacyFallback = $true
    $resolved = Resolve-CjmanReleasePath `
        -Version $version `
        -Configuration $native `
        -SuppressLegacyWarning
    Assert-Equal $legacy $resolved 'legacy native SDK is no longer discoverable'

    $android = Resolve-CjmanTargetConfiguration `
        -Target android `
        -TargetArch aarch64 `
        -HostArch x64
    $resolved = Resolve-CjmanReleasePath `
        -Version $version `
        -Configuration $android `
        -SuppressLegacyWarning
    Assert-True ($resolved -ne $legacy) `
        'legacy native SDK leaked into a cross-target lookup'
}

Invoke-Test 'historical Nightly assets use their actual build version' {
    $tag = '1.1.0-lalpha.20251225171128'
    $build = '1.1.0-alpha.20251225171128'
    $release = [PSCustomObject]@{
        tag_name = $tag
        assets = @(
            [PSCustomObject]@{
                type = 'attach'
                name = "cangjie-sdk-windows-x64-$build.zip"
            },
            [PSCustomObject]@{
                type = 'attach'
                name = "cangjie-frontend-windows-x64-$build.zip"
            },
            [PSCustomObject]@{
                type = 'attach'
                name = "cangjie-stdx-windows-x64-$build.1.zip"
            }
        )
    }
    $configuration = Resolve-CjmanTargetConfiguration `
        -Target native `
        -HostArch x64
    $sdk = Select-CjmanNightlySdkAsset `
        -Release $release `
        -Configuration $configuration
    $frontend = Select-CjmanNightlyFrontendAsset `
        -Release $release `
        -Configuration $configuration `
        -ExpectedBuildVersion $sdk.ComponentVersion
    $stdx = Select-CjmanNightlyStdxAsset `
        -Release $release `
        -Configuration $configuration `
        -ExpectedBuildVersion $sdk.ComponentVersion

    Assert-Equal $build $sdk.ComponentVersion
    Assert-Equal "cangjie-frontend-windows-x64-$build.zip" $frontend.Filename
    Assert-Equal "cangjie-stdx-windows-x64-$build.1.zip" $stdx.Filename
    Assert-True `
        ($sdk.Url.Contains("/$tag/cangjie-sdk-windows-x64-$build.zip")) `
        'Nightly URL did not combine the release tag with the actual asset name'
}

Invoke-Test 'EXE-only Windows Nightly is supported while ZIP remains preferred' {
    $build = '1.1.0-alpha.20260510010057'
    $configuration = Resolve-CjmanTargetConfiguration `
        -Target native `
        -HostArch x64
    $release = [PSCustomObject]@{
        tag_name = $build
        assets = @(
            [PSCustomObject]@{
                type = 'attach'
                name = "cangjie-sdk-windows-x64-$build.exe"
            }
        )
    }
    $selected = Select-CjmanNightlySdkAsset `
        -Release $release `
        -Configuration $configuration
    Assert-Equal 'exe' $selected.Format
    Assert-Equal "cangjie-sdk-windows-x64-$build.exe" $selected.Filename

    $release.assets += [PSCustomObject]@{
        type = 'attach'
        name = "cangjie-sdk-windows-x64-$build.zip"
    }
    $selected = Select-CjmanNightlySdkAsset `
        -Release $release `
        -Configuration $configuration
    Assert-Equal 'zip' $selected.Format
    Assert-Equal "cangjie-sdk-windows-x64-$build.zip" $selected.Filename
}

Invoke-Test 'Nightly installation tolerates a missing frontend asset' {
    $build = '1.2.0-alpha.20260625020029'
    $release = [PSCustomObject]@{
        tag_name = $build
        assets = @(
            [PSCustomObject]@{
                type = 'attach'
                name = "cangjie-sdk-windows-x64-$build.zip"
            },
            [PSCustomObject]@{
                type = 'attach'
                name = "cangjie-stdx-windows-x64-$build.1.zip"
            }
        )
    }
    $configuration = Resolve-CjmanTargetConfiguration `
        -Target native `
        -HostArch x64
    $sdk = Select-CjmanNightlySdkAsset `
        -Release $release `
        -Configuration $configuration
    $frontend = Select-CjmanNightlyFrontendAsset `
        -Release $release `
        -Configuration $configuration `
        -ExpectedBuildVersion $sdk.ComponentVersion `
        -WarningAction SilentlyContinue

    Assert-Equal $null $frontend
}

Invoke-Test 'formal stdx patch selection is numeric' {
    function Get-CjmanStdxReleaseList {
        [PSCustomObject]@{
            tag_name = 'v1.0.1'
            assets = @(
                [PSCustomObject]@{
                    type = 'attach'
                    name = 'cangjie-stdx-windows-x64-1.0.1.1.zip'
                },
                [PSCustomObject]@{
                    type = 'attach'
                    name = 'cangjie-stdx-windows-x64-1.0.1.2.zip'
                },
                [PSCustomObject]@{
                    type = 'attach'
                    name = 'cangjie-stdx-windows-x64-1.0.1.10.zip'
                },
                [PSCustomObject]@{
                    type = 'attach'
                    name = 'cangjie-stdx-windows-x64-1.0.10.99.zip'
                }
            )
        }
    }

    $configuration = Resolve-CjmanTargetConfiguration `
        -Target native `
        -HostArch x64
    $asset = Select-CjmanFormalStdxAsset `
        -SdkVersion 1.0.1 `
        -Configuration $configuration
    Assert-Equal '1.0.1.10' $asset.ComponentVersion
    Assert-Equal 'cangjie-stdx-windows-x64-1.0.1.10.zip' $asset.Filename
}

Invoke-Test 'unchecksummed ZIP validation rejects truncated cache files' {
    $zipRoot = Join-Path $TestRoot 'zip-validation'
    New-Item -ItemType Directory -Path $zipRoot -ErrorAction Stop | Out-Null
    $badZip = Join-Path $zipRoot 'bad.zip'
    [System.IO.File]::WriteAllBytes(
        $badZip,
        [byte[]](0x50, 0x4b, 0x03, 0x04, 0x00)
    )
    $payload = Join-Path $zipRoot 'payload.txt'
    Set-Content -LiteralPath $payload -Value 'ok' -Encoding ASCII
    $goodZip = Join-Path $zipRoot 'good.zip'
    Compress-Archive -LiteralPath $payload -DestinationPath $goodZip

    Assert-True `
        (-not (Test-CjmanFileHash -Path $badZip -ExpectedSha256 '')) `
        'truncated ZIP passed cache validation'
    Assert-True `
        (Test-CjmanFileHash -Path $goodZip -ExpectedSha256 '') `
        'valid ZIP failed cache validation'
}

Invoke-Test 'activation removes old SDK paths and rolls back on failure' {
    $environmentRoot = Join-Path $TestRoot 'environment'
    $oldRoot = Join-Path $environmentRoot 'old'
    $newRoot = Join-Path $environmentRoot 'new'
    $stdxRoot = Join-Path $newRoot 'stdx'
    New-Item `
        -ItemType Directory `
        -Path $oldRoot, $newRoot, $stdxRoot `
        -ErrorAction Stop | Out-Null
    $separator = [string][System.IO.Path]::PathSeparator
    $newBin = (Join-Path $newRoot 'bin').Replace("'", "''")
    $cjpmBin = (Join-Path $TestRoot '.cjpm/bin').Replace("'", "''")
    $escapedNewRoot = $newRoot.Replace("'", "''")
    $setupPath = Join-Path $newRoot 'envsetup.ps1'
    @(
        "`$env:PATH = '$newBin$separator' + `$env:PATH + '$separator$cjpmBin$separator$cjpmBin'"
        "`$env:CANGJIE_HOME = '$escapedNewRoot'"
    ) | Set-Content -LiteralPath $setupPath -Encoding UTF8

    $oldBin = Join-Path $oldRoot 'bin'
    $env:PATH = "$oldBin$separator/usr/bin"
    $env:CJMAN_ACTIVE_ROOT = $oldRoot
    Enable-CjmanEnvironment `
        -EnvironmentSetupPath $setupPath `
        -StdxPath $stdxRoot `
        -ReleasePath $newRoot

    $entries = @($env:PATH -split [regex]::Escape($separator))
    Assert-True (-not ($entries -contains $oldBin)) 'old SDK path remained active'
    Assert-Equal 1 @($entries | Where-Object { $_ -eq $cjpmBin }).Count `
        '.cjpm/bin was not deduplicated'
    Assert-Equal $newRoot $env:CJMAN_ACTIVE_ROOT
    Assert-Equal $stdxRoot $env:CJMAN_STDX_ROOT

    $pathBeforeFailure = $env:PATH
    $badSetup = Join-Path $environmentRoot 'bad.ps1'
    @(
        "`$env:PATH = '/broken'"
        "throw 'activation failed'"
    ) | Set-Content -LiteralPath $badSetup -Encoding UTF8
    $threw = $false
    try {
        Enable-CjmanEnvironment `
            -EnvironmentSetupPath $badSetup `
            -StdxPath $stdxRoot `
            -ReleasePath '/broken'
    } catch {
        $threw = $true
    }
    Assert-True $threw 'failing envsetup.ps1 unexpectedly succeeded'
    Assert-Equal $pathBeforeFailure $env:PATH 'failed activation did not restore PATH'
    Assert-Equal $newRoot $env:CJMAN_ACTIVE_ROOT `
        'failed activation did not restore CJMAN_ACTIVE_ROOT'
}

Invoke-Test 'PowerShell home defaults to the checkout containing cjman.ps1' {
    $savedHome = $env:CJMAN_HOME
    $savedScriptRoot = $script:CjmanScriptRoot
    $customRoot = Join-Path $TestRoot 'custom-install-root'
    try {
        Remove-Item Env:CJMAN_HOME -ErrorAction SilentlyContinue
        $script:CjmanScriptRoot = $customRoot
        Assert-Equal `
            ([System.IO.Path]::GetFullPath($customRoot)) `
            (Get-CjmanHome)
    } finally {
        $script:CjmanScriptRoot = $savedScriptRoot
        $env:CJMAN_HOME = $savedHome
    }
}

Invoke-Test 'installer separates and deduplicates a profile entry' {
    $profileCases = @(
        [PSCustomObject]@{
            Name = 'utf8'
            Encoding = New-Object System.Text.UTF8Encoding($false)
        },
        [PSCustomObject]@{
            Name = 'utf16le'
            Encoding = [System.Text.Encoding]::Unicode
        }
    )
    $installerPath = Join-Path $ProjectRoot 'cjman-installer.ps1'
    $profileLine = ". '$((Join-Path $ProjectRoot 'cjman.ps1').Replace("'", "''"))'"

    foreach ($profileCase in $profileCases) {
        $profilePath = Join-Path `
            $TestRoot `
            "profile-without-newline-$($profileCase.Name).ps1"
        [System.IO.File]::WriteAllText(
            $profilePath,
            'Set-StrictMode -Version Latest',
            $profileCase.Encoding
        )

        & $installerPath `
            -InstallRoot $ProjectRoot `
            -ProfilePath $profilePath `
            -SkipProfile:$false `
            -InformationAction SilentlyContinue
        & $installerPath `
            -InstallRoot $ProjectRoot `
            -ProfilePath $profilePath `
            -SkipProfile:$false `
            -InformationAction SilentlyContinue

        $profileText = Get-Content -LiteralPath $profilePath -Raw
        Assert-True `
            ($profileText -match ('Latest\r?\n' + [regex]::Escape($profileLine))) `
            "installer glued the loader to a $($profileCase.Name) profile statement"
        Assert-Equal 1 `
            @($profileText -split '\r?\n' | Where-Object { $_ -eq $profileLine }).Count `
            "installer duplicated the $($profileCase.Name) profile entry"

        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $profilePath,
            [ref]$tokens,
            [ref]$errors
        )
        Assert-Equal 0 $errors.Count `
            "$($profileCase.Name) profile has parser errors"
    }
}

Write-Host "1..$TestsRun"
if ($TestsFailed -ne 0) {
    Write-Host "# $TestsFailed of $TestsRun tests failed"
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "# all $TestsRun tests passed"
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
