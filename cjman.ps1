#Requires -Version 5.1

# cjman PowerShell frontend.
#
# Dot-source this file so that `cjman use` can update the current PowerShell
# process:
#
#   . "$HOME\.cjman\cjman.ps1"

$script:CjmanScriptRoot = $PSScriptRoot
$script:CjmanNightlyApiBase = 'https://api.gitcode.com/api/v5/repos/Cangjie/nightly_build/releases'
$script:CjmanStdxApiBase = 'https://api.gitcode.com/api/v5/repos/Cangjie/cangjie_stdx/releases'
$script:CjmanNightlyDownloadBase = 'https://gitcode.com/Cangjie/nightly_build/releases/download'
$script:CjmanStdxDownloadBase = 'https://gitcode.com/Cangjie/cangjie_stdx/releases/download'

function Get-CjmanHome {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:CJMAN_HOME)) {
        return [System.IO.Path]::GetFullPath($env:CJMAN_HOME)
    }

    return [System.IO.Path]::GetFullPath($script:CjmanScriptRoot)
}

function Get-CjmanBundlesDirectory {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:CANGJIE_BUNDLES)) {
        return [System.IO.Path]::GetFullPath($env:CANGJIE_BUNDLES)
    }

    return (Join-Path (Get-CjmanHome) 'bundles')
}

function Get-CjmanCacheDirectory {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-CjmanHome) 'cache')
}

function Enable-CjmanTls12 {
    [CmdletBinding()]
    param()

    try {
        $tls12 = [Net.SecurityProtocolType]::Tls12
        if (([Net.ServicePointManager]::SecurityProtocol -band $tls12) -eq 0) {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor $tls12
        }
    } catch {
        # PowerShell 7 uses HttpClient and does not require ServicePointManager.
        Write-Verbose 'ServicePointManager TLS configuration is not required in this runtime.'
    }
}

function Get-CjmanRawBaseUrl {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:CJMAN_BASE_URL)) {
        return $env:CJMAN_BASE_URL.TrimEnd('/')
    }

    $configPath = Join-Path (Get-CjmanHome) '.git\config'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction SilentlyContinue
        if ($config -match 'github\.com') {
            return 'https://raw.githubusercontent.com/ChaosJohn/cjman/master'
        }
    }

    return 'https://raw.gitcode.com/ChaosJohn/cjman/raw/master'
}

function Get-CjmanResourceText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $normalizedRelativePath = $RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $localCandidates = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($env:CJMAN_METADATA_ROOT)) {
        $localCandidates.Add((Join-Path $env:CJMAN_METADATA_ROOT $normalizedRelativePath))
    }

    if (-not [string]::IsNullOrWhiteSpace($script:CjmanScriptRoot)) {
        $localCandidates.Add((Join-Path $script:CjmanScriptRoot $normalizedRelativePath))
    }

    $localCandidates.Add((Join-Path (Get-CjmanHome) $normalizedRelativePath))

    foreach ($candidate in $localCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.File]::ReadAllText(
                $candidate,
                (New-Object System.Text.UTF8Encoding($false))
            )
        }
    }

    Enable-CjmanTls12
    $uri = '{0}/{1}' -f (Get-CjmanRawBaseUrl), $RelativePath.TrimStart('/')
    $oldProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -ErrorAction Stop
        return [string]$response.Content
    } finally {
        $ProgressPreference = $oldProgressPreference
    }
}

function ConvertFrom-CjmanTsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $lines = $Text -split "`r?`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#') }

    if (@($lines).Count -eq 0) {
        return @()
    }

    $normalized = $lines -join [Environment]::NewLine
    return @($normalized | ConvertFrom-Csv -Delimiter "`t")
}

function Get-CjmanCatalog {
    [CmdletBinding()]
    param()

    $text = Get-CjmanResourceText -RelativePath 'metadata/v2/catalog.tsv'
    $rows = @(ConvertFrom-CjmanTsv -Text $text)
    foreach ($row in $rows) {
        foreach ($property in @('version', 'channel', 'display_name', 'published_at')) {
            if ($null -eq $row.PSObject.Properties[$property]) {
                throw "catalog.tsv is missing required column '$property'."
            }
        }
    }

    return $rows
}

function Get-CjmanReleaseRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    Confirm-CjmanIdentifier -Value $Version -Label 'version'
    $text = Get-CjmanResourceText -RelativePath "metadata/v2/releases/$Version.tsv"
    $rows = @(ConvertFrom-CjmanTsv -Text $text)
    $requiredColumns = @(
        'component', 'host_os', 'host_arch', 'target_os', 'target_arch',
        'flavor', 'format', 'filename', 'url', 'sha256', 'size'
    )

    foreach ($row in $rows) {
        foreach ($property in $requiredColumns) {
            if ($null -eq $row.PSObject.Properties[$property]) {
                throw "Release metadata for $Version is missing required column '$property'."
            }
        }
    }

    return $rows
}

function Get-CjmanPublishedSortKey {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$PublishedAt
    )

    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($PublishedAt, [ref]$parsed)) {
        return $parsed.UtcDateTime.Ticks
    }

    return [long]0
}

function Get-CjmanApiJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    Enable-CjmanTls12
    $oldProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        return Invoke-RestMethod -Uri $Uri -Headers @{ Accept = 'application/json' } -ErrorAction Stop
    } finally {
        $ProgressPreference = $oldProgressPreference
    }
}

function Get-CjmanNightlyRelease {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Tag
    )

    if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -eq 'nightly') {
        $uri = "${script:CjmanNightlyApiBase}/latest"
    } else {
        Confirm-CjmanIdentifier -Value $Tag -Label 'nightly tag'
        $encodedTag = [Uri]::EscapeDataString($Tag)
        $uri = "${script:CjmanNightlyApiBase}/tags/$encodedTag"
    }

    $release = Get-CjmanApiJson -Uri $uri
    if ($null -eq $release -or [string]::IsNullOrWhiteSpace([string]$release.tag_name)) {
        throw "GitCode returned an invalid Nightly release for '$Tag'."
    }

    return $release
}

function Get-CjmanNightlyReleaseList {
    [CmdletBinding()]
    param()

    $allReleases = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le 100; $page++) {
        $uri = "${script:CjmanNightlyApiBase}?per_page=100&page=$page"
        $response = Get-CjmanApiJson -Uri $uri
        if ($response -is [System.Array]) {
            $pageItems = [object[]]$response
        } else {
            $pageItems = @($response)
        }
        if ($pageItems.Count -eq 0) {
            break
        }

        foreach ($release in $pageItems) {
            $allReleases.Add($release)
        }

        if ($pageItems.Count -lt 100) {
            break
        }
    }

    return @($allReleases)
}

function Resolve-CjmanVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedVersion
    )

    $requested = $RequestedVersion.Trim()
    if ([string]::IsNullOrWhiteSpace($requested)) {
        throw 'A version is required.'
    }

    if ($requested -eq 'nightly') {
        $nightly = Get-CjmanNightlyRelease
        return [PSCustomObject]@{
            Version = [string]$nightly.tag_name
            Channel = 'nightly'
            IsNightly = $true
            Release = $nightly
            CatalogRow = $null
        }
    }

    $catalog = @(Get-CjmanCatalog)
    $exact = @($catalog | Where-Object { $_.version -eq $requested })
    if ($exact.Count -eq 1) {
        return [PSCustomObject]@{
            Version = [string]$exact[0].version
            Channel = ([string]$exact[0].channel).ToLowerInvariant()
            IsNightly = $false
            Release = $null
            CatalogRow = $exact[0]
        }
    }

    if ($exact.Count -gt 1) {
        throw "Catalog contains duplicate version '$requested'."
    }

    if ($requested -in @('latest', 'lts', 'sts')) {
        if ($requested -eq 'latest') {
            $candidates = @($catalog | Where-Object { $_.channel -in @('lts', 'sts') })
        } else {
            $candidates = @($catalog | Where-Object { $_.channel -eq $requested })
        }

        if ($candidates.Count -eq 0) {
            throw "No $requested release exists in catalog.tsv."
        }

        $selected = $candidates |
            Sort-Object `
                @{ Expression = { Get-CjmanPublishedSortKey -PublishedAt $_.published_at } },
                @{ Expression = { $_.version } } |
            Select-Object -Last 1

        return [PSCustomObject]@{
            Version = [string]$selected.version
            Channel = ([string]$selected.channel).ToLowerInvariant()
            IsNightly = $false
            Release = $null
            CatalogRow = $selected
        }
    }

    Confirm-CjmanIdentifier -Value $requested -Label 'version'
    try {
        $nightly = Get-CjmanNightlyRelease -Tag $requested
        return [PSCustomObject]@{
            Version = [string]$nightly.tag_name
            Channel = 'nightly'
            IsNightly = $true
            Release = $nightly
            CatalogRow = $null
        }
    } catch {
        throw "Unknown Cangjie version or Nightly tag '$requested'."
    }
}

function ConvertTo-CjmanArchitecture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    switch ($Architecture.Trim().ToLowerInvariant()) {
        { $_ -in @('amd64', 'x64', 'x86_64') } { return 'x64' }
        { $_ -in @('arm64', 'aarch64') } { return 'aarch64' }
        { $_ -in @('arm', 'arm32', 'armv7', 'armv7l') } { return 'arm32' }
        default { throw "Unsupported architecture '$Architecture'." }
    }
}

function Get-CjmanWindowsArchitecture {
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') {
        throw 'cjman.ps1 installs native Windows SDK packages and must run on Windows.'
    }

    try {
        $runtimeInformationType = [Type]::GetType(
            'System.Runtime.InteropServices.RuntimeInformation, System.Runtime.InteropServices.RuntimeInformation',
            $false
        )
        if ($null -eq $runtimeInformationType) {
            $runtimeInformationType = [AppDomain]::CurrentDomain.GetAssemblies() |
                ForEach-Object {
                    $_.GetType('System.Runtime.InteropServices.RuntimeInformation', $false)
                } |
                Where-Object { $null -ne $_ } |
                Select-Object -First 1
        }

        if ($null -ne $runtimeInformationType) {
            $architectureProperty = $runtimeInformationType.GetProperty('OSArchitecture')
            if ($null -ne $architectureProperty) {
                $runtimeArchitecture = $architectureProperty.GetValue($null, $null)
                if ($null -ne $runtimeArchitecture) {
                    return (ConvertTo-CjmanArchitecture -Architecture $runtimeArchitecture.ToString())
                }
            }
        }
    } catch {
        # RuntimeInformation.OSArchitecture is not available on every .NET
        # Framework version used by Windows PowerShell 5.1.
        Write-Verbose 'Falling back to Windows processor environment variables.'
    }

    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }

    return (ConvertTo-CjmanArchitecture -Architecture $architecture)
}

function Confirm-CjmanIdentifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
        throw "Invalid $Label '$Value'."
    }
}

function Confirm-CjmanFilename {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filename
    )

    if ([string]::IsNullOrWhiteSpace($Filename) -or
        $Filename -match '[\\/:\x00-\x1f]' -or
        [System.IO.Path]::GetFileName($Filename) -ne $Filename) {
        throw "Unsafe release filename '$Filename'."
    }
}

function Resolve-CjmanTargetConfiguration {
    [CmdletBinding()]
    param(
        [string]$Target = 'native',
        [AllowEmptyString()]
        [string]$TargetArch,
        [AllowEmptyString()]
        [string]$HostArch
    )

    $normalizedTarget = $Target.Trim().ToLowerInvariant()
    if ($normalizedTarget -notin @('native', 'android', 'ohos', 'ios', 'ios-simulator')) {
        throw "Unsupported target '$Target'."
    }

    $hostArchWasOverridden = -not [string]::IsNullOrWhiteSpace($HostArch)
    if (-not $hostArchWasOverridden) {
        $normalizedHostArch = Get-CjmanWindowsArchitecture
    } else {
        $normalizedHostArch = ConvertTo-CjmanArchitecture -Architecture $HostArch
    }

    if ([string]::IsNullOrWhiteSpace($TargetArch)) {
        if ($normalizedTarget -in @('native', 'ios-simulator')) {
            $normalizedTargetArch = $normalizedHostArch
        } else {
            $normalizedTargetArch = 'aarch64'
        }
    } else {
        $normalizedTargetArch = ConvertTo-CjmanArchitecture -Architecture $TargetArch
    }

    if ($normalizedTarget -eq 'native' -and $normalizedTargetArch -ne $normalizedHostArch) {
        throw 'The native target architecture must match the Windows host architecture.'
    }

    return [PSCustomObject]@{
        HostOs = 'windows'
        HostArch = $normalizedHostArch
        Target = $normalizedTarget
        TargetArch = $normalizedTargetArch
        AllowLegacyFallback = -not $hostArchWasOverridden
    }
}

function ConvertFrom-CjmanInstallOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$AllowWithoutStdx
    )

    if ($Arguments.Count -eq 0 -or $Arguments[0].StartsWith('-')) {
        throw 'A version is required.'
    }

    $version = $Arguments[0]
    $target = 'native'
    $targetArch = ''
    $hostArch = ''
    $withoutStdx = $false

    for ($index = 1; $index -lt $Arguments.Count; $index++) {
        switch ($Arguments[$index]) {
            '--target' {
                $index++
                if ($index -ge $Arguments.Count) {
                    throw '--target requires a value.'
                }
                $target = $Arguments[$index]
            }
            '--target-arch' {
                $index++
                if ($index -ge $Arguments.Count) {
                    throw '--target-arch requires a value.'
                }
                $targetArch = $Arguments[$index]
            }
            '--host-arch' {
                $index++
                if ($index -ge $Arguments.Count) {
                    throw '--host-arch requires a value.'
                }
                $hostArch = $Arguments[$index]
            }
            '--without-stdx' {
                if (-not $AllowWithoutStdx) {
                    throw '--without-stdx is only valid for cjman install.'
                }
                $withoutStdx = $true
            }
            default {
                throw "Unknown option '$($Arguments[$index])'."
            }
        }
    }

    $configuration = Resolve-CjmanTargetConfiguration `
        -Target $target `
        -TargetArch $targetArch `
        -HostArch $hostArch

    return [PSCustomObject]@{
        Version = $version
        Configuration = $configuration
        WithoutStdx = $withoutStdx
    }
}

function Get-CjmanReleasePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    Confirm-CjmanIdentifier -Value $Version -Label 'version'
    $bundles = Get-CjmanBundlesDirectory
    $directoryName = 'cangjie-{0}-windows-{1}-{2}-{3}' -f `
        $Version, $Configuration.HostArch, $Configuration.Target, $Configuration.TargetArch

    return (Join-Path $bundles $directoryName)
}

function Resolve-CjmanReleasePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [object]$Configuration,

        [switch]$SuppressLegacyWarning
    )

    $primary = Get-CjmanReleasePath `
        -Version $Version `
        -Configuration $Configuration
    $allowLegacyFallback = $false
    $allowLegacyProperty = $Configuration.PSObject.Properties['AllowLegacyFallback']
    if ($null -ne $allowLegacyProperty) {
        $allowLegacyFallback = [bool]$allowLegacyProperty.Value
    }
    if ((Test-Path -LiteralPath $primary) -or
        $Configuration.Target -ne 'native' -or
        -not $allowLegacyFallback) {
        return $primary
    }

    $legacy = Join-Path (Get-CjmanBundlesDirectory) "cangjie-$Version"
    if (Test-CjmanInstalledSdk -ReleasePath $legacy) {
        if (-not $SuppressLegacyWarning) {
            Write-Warning "Using legacy native SDK directory '$legacy'."
        }
        return $legacy
    }

    return $primary
}

function Get-CjmanLogicalTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row
    )

    $targetOs = ([string]$Row.target_os).ToLowerInvariant()
    if ($targetOs -eq 'windows') {
        return 'native'
    }

    if ($targetOs -eq 'ios' -and ([string]$Row.flavor).ToLowerInvariant() -eq 'simulator') {
        return 'ios-simulator'
    }

    return $targetOs
}

function Select-CjmanFormalSdkAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    $rows = @(Get-CjmanReleaseRecord -Version $Version)
    $ranked = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        if (([string]$row.component).ToLowerInvariant() -ne 'sdk' -or
            ([string]$row.host_os).ToLowerInvariant() -ne 'windows' -or
            ([string]$row.host_arch).ToLowerInvariant() -ne $Configuration.HostArch -or
            ([string]$row.format).TrimStart('.').ToLowerInvariant() -ne 'zip' -or
            ([string]$row.flavor).ToLowerInvariant() -ne 'default' -or
            (Get-CjmanLogicalTarget -Row $row) -ne $Configuration.Target) {
            continue
        }

        $metadataTargetArch = ([string]$row.target_arch).ToLowerInvariant()
        if ($metadataTargetArch -eq $Configuration.TargetArch) {
            $score = 2
        } elseif ($metadataTargetArch -in @('', 'any', 'all')) {
            $score = 1
        } else {
            continue
        }

        $ranked.Add([PSCustomObject]@{ Score = $score; Row = $row })
    }

    if ($ranked.Count -eq 0) {
        throw ("No Windows $($Configuration.HostArch) SDK for target " +
            "$($Configuration.Target)/$($Configuration.TargetArch) exists in Cangjie $Version.")
    }

    $bestScore = ($ranked | Measure-Object -Property Score -Maximum).Maximum
    $best = @($ranked | Where-Object { $_.Score -eq $bestScore })
    if ($best.Count -ne 1) {
        throw "Release metadata for $Version contains ambiguous Windows SDK assets."
    }

    $row = $best[0].Row
    Confirm-CjmanFilename -Filename ([string]$row.filename)
    if ([string]::IsNullOrWhiteSpace([string]$row.sha256) -or
        ([string]$row.sha256) -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Formal SDK '$($row.filename)' has no valid SHA-256 checksum."
    }

    return [PSCustomObject]@{
        Version = $Version
        Tag = ''
        Channel = 'formal'
        Component = 'sdk'
        Filename = [string]$row.filename
        Url = [string]$row.url
        Sha256 = ([string]$row.sha256).ToLowerInvariant()
        Format = 'zip'
        ComponentVersion = $Version
    }
}

function ConvertTo-CjmanGitCodeAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryDownloadBase,

        [Parameter(Mandatory = $true)]
        [string]$Tag,

        [Parameter(Mandatory = $true)]
        [object]$Asset,

        [Parameter(Mandatory = $true)]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [string]$Channel,

        [Parameter(Mandatory = $true)]
        [string]$ComponentVersion,

        [ValidateSet('zip', 'exe')]
        [string]$Format = 'zip'
    )

    $filename = [string]$Asset.name
    Confirm-CjmanFilename -Filename $filename
    Confirm-CjmanIdentifier -Value $Tag -Label 'release tag'
    $encodedTag = [Uri]::EscapeDataString($Tag)
    $encodedFilename = [Uri]::EscapeDataString($filename)

    return [PSCustomObject]@{
        Version = $ComponentVersion
        Tag = $Tag
        Channel = $Channel
        Component = $Component
        Filename = $filename
        Url = "$RepositoryDownloadBase/$encodedTag/$encodedFilename"
        Sha256 = ''
        Format = $Format
        ComponentVersion = $ComponentVersion
    }
}

function ConvertFrom-CjmanNightlySdkFilename {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filename
    )

    $pattern = '^cangjie-sdk-windows-(?<host_arch>x64|aarch64)' +
        '(?:-(?<target>ios-simulator|android|ohos|ios)' +
        '(?:-(?<target_arch>x64|aarch64|arm32))?)?' +
        '-(?<version>[0-9][0-9A-Za-z.+-]*)\.(?<format>zip|exe)$'
    $match = [regex]::Match($Filename, $pattern)
    if (-not $match.Success) {
        return $null
    }

    if ($match.Groups['target'].Success) {
        $target = $match.Groups['target'].Value
    } else {
        $target = 'native'
    }

    if ($match.Groups['target_arch'].Success) {
        $targetArch = $match.Groups['target_arch'].Value
    } elseif ($target -eq 'native') {
        $targetArch = $match.Groups['host_arch'].Value
    } else {
        $targetArch = 'any'
    }

    return [PSCustomObject]@{
        HostArch = $match.Groups['host_arch'].Value
        Target = $target
        TargetArch = $targetArch
        Version = $match.Groups['version'].Value
        Format = $match.Groups['format'].Value
    }
}

function Select-CjmanNightlySdkAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release,

        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    $tag = [string]$Release.tag_name
    $ranked = [System.Collections.Generic.List[object]]::new()
    foreach ($asset in @($Release.assets)) {
        if ($asset.type -ne 'attach') {
            continue
        }

        $parsed = ConvertFrom-CjmanNightlySdkFilename -Filename ([string]$asset.name)
        if ($null -eq $parsed -or
            $parsed.HostArch -ne $Configuration.HostArch -or
            $parsed.Target -ne $Configuration.Target) {
            continue
        }

        if ($parsed.TargetArch -eq $Configuration.TargetArch) {
            $score = 20
        } elseif ($parsed.TargetArch -eq 'any') {
            $score = 10
        } else {
            continue
        }
        if ($parsed.Format -eq 'zip') {
            $score += 2
        } else {
            $score += 1
        }

        $ranked.Add([PSCustomObject]@{
            Score = $score
            Parsed = $parsed
            Asset = $asset
        })
    }

    if ($ranked.Count -eq 0) {
        throw ("Nightly $tag has no Windows $($Configuration.HostArch) SDK for target " +
            "$($Configuration.Target)/$($Configuration.TargetArch).")
    }

    $bestScore = ($ranked | Measure-Object -Property Score -Maximum).Maximum
    $best = @($ranked | Where-Object { $_.Score -eq $bestScore })
    if ($best.Count -ne 1) {
        throw "Nightly $tag contains ambiguous Windows SDK assets."
    }

    return ConvertTo-CjmanGitCodeAsset `
        -RepositoryDownloadBase $script:CjmanNightlyDownloadBase `
        -Tag $tag `
        -Asset $best[0].Asset `
        -Component 'sdk' `
        -Channel 'nightly' `
        -ComponentVersion $best[0].Parsed.Version `
        -Format $best[0].Parsed.Format
}

function Select-CjmanNightlyFrontendAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release,

        [Parameter(Mandatory = $true)]
        [object]$Configuration,

        [AllowEmptyString()]
        [string]$ExpectedBuildVersion
    )

    $tag = [string]$Release.tag_name
    $hostArch = [regex]::Escape($Configuration.HostArch)
    $pattern = "^cangjie-frontend-windows-$hostArch-" +
        '(?<version>[0-9][0-9A-Za-z.+-]*)\.zip$'
    $assetMatches = [System.Collections.Generic.List[object]]::new()
    foreach ($asset in @($Release.assets)) {
        if ($asset.type -ne 'attach') {
            continue
        }

        $match = [regex]::Match([string]$asset.name, $pattern)
        if ($match.Success -and
            ([string]::IsNullOrWhiteSpace($ExpectedBuildVersion) -or
             $match.Groups['version'].Value -eq $ExpectedBuildVersion)) {
            $assetMatches.Add([PSCustomObject]@{
                Version = $match.Groups['version'].Value
                Asset = $asset
            })
        }
    }

    if ($assetMatches.Count -eq 0) {
        Write-Warning ("Nightly $tag does not contain a Windows " +
            "$($Configuration.HostArch) frontend asset for build " +
            "'$ExpectedBuildVersion'; installing the SDK without frontend.")
        return $null
    }

    if ($assetMatches.Count -ne 1) {
        throw ("Nightly $tag does not contain exactly one Windows " +
            "$($Configuration.HostArch) frontend asset for build '$ExpectedBuildVersion'.")
    }

    return ConvertTo-CjmanGitCodeAsset `
        -RepositoryDownloadBase $script:CjmanNightlyDownloadBase `
        -Tag $tag `
        -Asset $assetMatches[0].Asset `
        -Component 'frontend' `
        -Channel 'nightly' `
        -ComponentVersion $assetMatches[0].Version
}

function Get-CjmanStdxTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    if ($Configuration.Target -eq 'native') {
        return "windows-$($Configuration.TargetArch)"
    }

    return "$($Configuration.Target)-$($Configuration.TargetArch)"
}

function Select-CjmanNightlyStdxAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release,

        [Parameter(Mandatory = $true)]
        [object]$Configuration,

        [AllowEmptyString()]
        [string]$ExpectedBuildVersion
    )

    $tag = [string]$Release.tag_name
    $stdxTarget = Get-CjmanStdxTarget -Configuration $Configuration
    $escapedTarget = [regex]::Escape($stdxTarget)
    $pattern = "^cangjie-stdx-$escapedTarget-" +
        '(?<version>[0-9][0-9A-Za-z.+-]*)\.(?<patch>[0-9]+)\.zip$'
    $assetMatches = [System.Collections.Generic.List[object]]::new()

    foreach ($asset in @($Release.assets)) {
        if ($asset.type -ne 'attach') {
            continue
        }
        $match = [regex]::Match([string]$asset.name, $pattern)
        if ($match.Success -and
            ([string]::IsNullOrWhiteSpace($ExpectedBuildVersion) -or
             $match.Groups['version'].Value -eq $ExpectedBuildVersion)) {
            $assetMatches.Add([PSCustomObject]@{
                Patch = [long]$match.Groups['patch'].Value
                Version = "$($match.Groups['version'].Value).$($match.Groups['patch'].Value)"
                Asset = $asset
            })
        }
    }

    if ($assetMatches.Count -eq 0) {
        return $null
    }

    $selected = $assetMatches | Sort-Object Patch | Select-Object -Last 1
    $result = ConvertTo-CjmanGitCodeAsset `
        -RepositoryDownloadBase $script:CjmanNightlyDownloadBase `
        -Tag $tag `
        -Asset $selected.Asset `
        -Component 'stdx' `
        -Channel 'nightly' `
        -ComponentVersion $selected.Version
    $result | Add-Member -NotePropertyName StdxTarget -NotePropertyValue $stdxTarget
    return $result
}

function Get-CjmanStdxReleaseList {
    [CmdletBinding()]
    param()

    $allReleases = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le 100; $page++) {
        $uri = "${script:CjmanStdxApiBase}?per_page=100&page=$page"
        $response = Get-CjmanApiJson -Uri $uri
        if ($response -is [System.Array]) {
            $pageItems = [object[]]$response
        } else {
            $pageItems = @($response)
        }
        if ($pageItems.Count -eq 0) {
            break
        }

        foreach ($release in $pageItems) {
            $allReleases.Add($release)
        }

        if ($pageItems.Count -lt 100) {
            break
        }
    }

    return @($allReleases)
}

function Select-CjmanFormalStdxAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SdkVersion,

        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    Confirm-CjmanIdentifier -Value $SdkVersion -Label 'SDK version'
    $stdxTarget = Get-CjmanStdxTarget -Configuration $Configuration
    $escapedTarget = [regex]::Escape($stdxTarget)
    $escapedSdkVersion = [regex]::Escape($SdkVersion)
    $pattern = "^cangjie-stdx-$escapedTarget-$escapedSdkVersion\.([0-9]+)\.zip$"
    $assetMatches = [System.Collections.Generic.List[object]]::new()

    foreach ($release in @(Get-CjmanStdxReleaseList)) {
        $tag = [string]$release.tag_name
        if ([string]::IsNullOrWhiteSpace($tag)) {
            continue
        }

        foreach ($asset in @($release.assets)) {
            if ($asset.type -ne 'attach') {
                continue
            }

            $match = [regex]::Match([string]$asset.name, $pattern)
            if ($match.Success) {
                $assetMatches.Add([PSCustomObject]@{
                    Patch = [long]$match.Groups[1].Value
                    Version = "$SdkVersion.$($match.Groups[1].Value)"
                    Tag = $tag
                    Asset = $asset
                })
            }
        }
    }

    if ($assetMatches.Count -eq 0) {
        return $null
    }

    $highestPatch = ($assetMatches | Measure-Object -Property Patch -Maximum).Maximum
    $highest = @($assetMatches | Where-Object { $_.Patch -eq $highestPatch })
    $uniqueNames = @($highest | ForEach-Object { [string]$_.Asset.name } | Select-Object -Unique)
    if ($uniqueNames.Count -ne 1) {
        throw "Multiple stdx assets match SDK $SdkVersion patch $highestPatch and target $stdxTarget."
    }

    $selected = $highest[0]
    $result = ConvertTo-CjmanGitCodeAsset `
        -RepositoryDownloadBase $script:CjmanStdxDownloadBase `
        -Tag $selected.Tag `
        -Asset $selected.Asset `
        -Component 'stdx' `
        -Channel 'formal' `
        -ComponentVersion $selected.Version
    $result | Add-Member -NotePropertyName StdxTarget -NotePropertyValue $stdxTarget
    return $result
}

function Get-CjmanStdxAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedVersion,

        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    if ($ResolvedVersion.IsNightly) {
        $sdkAsset = Select-CjmanNightlySdkAsset `
            -Release $ResolvedVersion.Release `
            -Configuration $Configuration
        return Select-CjmanNightlyStdxAsset `
            -Release $ResolvedVersion.Release `
            -Configuration $Configuration `
            -ExpectedBuildVersion $sdkAsset.ComponentVersion
    }

    return Select-CjmanFormalStdxAsset `
        -SdkVersion $ResolvedVersion.Version `
        -Configuration $Configuration
}

function Test-CjmanZipSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        if ($stream.Length -lt 4) {
            return $false
        }
        $bytes = New-Object byte[] 4
        [void]$stream.Read($bytes, 0, 4)
        return $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4b -and
            (($bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04) -or
             ($bytes[2] -eq 0x05 -and $bytes[3] -eq 0x06) -or
             ($bytes[2] -eq 0x07 -and $bytes[3] -eq 0x08))
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Test-CjmanPeSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        if ($stream.Length -lt 2) {
            return $false
        }
        $bytes = New-Object byte[] 2
        [void]$stream.Read($bytes, 0, 2)
        return $bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-CjmanSevenZipCommand {
    [CmdletBinding()]
    param()

    foreach ($name in @('7z.exe', '7za.exe', '7zz.exe', '7z', '7za', '7zz')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [string]$command.Source
        }
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates.Add((Join-Path $env:ProgramFiles '7-Zip\7z.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw ('7-Zip is required to unpack this EXE-only Windows Nightly SDK. ' +
        'Install 7-Zip and ensure 7z.exe is available.')
}

function Confirm-CjmanSafeInstallerExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [long]$MaximumExpandedBytes = 8589934592,
        [int]$MaximumEntries = 100000
    )

    if (-not (Test-CjmanPeSignature -Path $ArchivePath)) {
        throw "Installer '$ArchivePath' is not a Windows PE executable."
    }

    $sevenZip = Get-CjmanSevenZipCommand
    $testOutput = @(& $sevenZip 't' '-y' '--' $ArchivePath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("7-Zip could not validate installer '$ArchivePath': " +
            "$($testOutput -join [Environment]::NewLine)")
    }

    $listing = @(& $sevenZip 'l' '-slt' '--' $ArchivePath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip could not list installer '$ArchivePath'."
    }

    $root = [System.IO.Path]::GetFullPath($DestinationPath).
        TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::OrdinalIgnoreCase)
    $insideEntries = $false
    $entryCount = 0
    [long]$expandedBytes = 0

    foreach ($rawLine in $listing) {
        $line = [string]$rawLine
        if ($line -eq '----------') {
            $insideEntries = $true
            continue
        }
        if (-not $insideEntries) {
            continue
        }

        if ($line -match '^Size = ([0-9]+)$') {
            $entrySize = [long]$Matches[1]
            if ($entrySize -gt $MaximumExpandedBytes) {
                throw "Installer '$ArchivePath' contains an oversized entry."
            }
            $expandedBytes += $entrySize
            if ($expandedBytes -gt $MaximumExpandedBytes) {
                throw "Installer '$ArchivePath' expands beyond the configured size limit."
            }
            continue
        }
        if ($line -match '^Symbolic Link = .+$') {
            throw "Installer '$ArchivePath' contains a symbolic link."
        }
        if (-not $line.StartsWith('Path = ')) {
            continue
        }

        $entryCount++
        if ($entryCount -gt $MaximumEntries) {
            throw "Installer '$ArchivePath' contains too many entries."
        }
        $entryName = $line.Substring(7).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($entryName) -or
            $entryName.StartsWith('/') -or
            $entryName -match '^[A-Za-z]:' -or
            $entryName.StartsWith('//') -or
            $entryName -match '[\x00-\x1f]' -or
            $entryName.Contains(':')) {
            throw "Installer '$ArchivePath' contains unsafe path '$entryName'."
        }

        $segments = @($entryName.Split('/') | Where-Object { $_ -ne '' })
        foreach ($segment in $segments) {
            if ($segment -eq '..' -or $segment -eq '.') {
                throw "Installer '$ArchivePath' contains traversal path '$entryName'."
            }
            $trimmedSegment = $segment.TrimEnd(' ', '.')
            if ([string]::IsNullOrEmpty($trimmedSegment)) {
                throw "Installer '$ArchivePath' contains invalid Windows path '$entryName'."
            }
            $deviceStem = ($trimmedSegment -split '\.')[0]
            if ($deviceStem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
                throw "Installer '$ArchivePath' contains reserved Windows path '$entryName'."
            }
        }

        $normalizedEntry = $segments -join '/'
        if (-not $seen.Add($normalizedEntry)) {
            throw "Installer '$ArchivePath' contains duplicate path '$entryName'."
        }
        $destination = [System.IO.Path]::GetFullPath((Join-Path $root $entryName))
        if (-not $destination.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Installer '$ArchivePath' escapes its extraction directory through '$entryName'."
        }
    }

    if ($entryCount -eq 0) {
        throw "Installer '$ArchivePath' contains no extractable entries."
    }
}

function Test-CjmanFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowEmptyString()]
        [string]$ExpectedSha256
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        try {
            $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
            if ($extension -eq '.zip') {
                if (-not (Test-CjmanZipSignature -Path $Path)) {
                    return $false
                }
                $validationRoot = Join-Path `
                    ([System.IO.Path]::GetTempPath()) `
                    'cjman-zip-validation'
                Confirm-CjmanSafeZip `
                    -ArchivePath $Path `
                    -DestinationPath $validationRoot
            } elseif ($extension -eq '.exe') {
                $validationRoot = Join-Path `
                    ([System.IO.Path]::GetTempPath()) `
                    'cjman-exe-validation'
                Confirm-CjmanSafeInstallerExe `
                    -ArchivePath $Path `
                    -DestinationPath $validationRoot
            } else {
                return $false
            }
            return $true
        } catch {
            Write-Verbose "Archive validation failed for '$Path': $($_.Exception.Message)"
            return $false
        }
    }

    if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Invalid expected SHA-256 '$ExpectedSha256'."
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    return $actual.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)
}

function Save-CjmanAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Asset
    )

    Confirm-CjmanFilename -Filename $Asset.Filename
    $uri = $null
    if (-not [Uri]::TryCreate([string]$Asset.Url, [UriKind]::Absolute, [ref]$uri)) {
        throw "Invalid download URL for '$($Asset.Filename)'."
    }
    if ($uri.Scheme -ne 'https' -and $env:CJMAN_ALLOW_INSECURE_HTTP -ne '1') {
        throw "Refusing non-HTTPS download URL '$($Asset.Url)'."
    }

    $cacheDirectory = Get-CjmanCacheDirectory
    New-Item -ItemType Directory -Path $cacheDirectory -Force -ErrorAction Stop | Out-Null
    $destination = Join-Path $cacheDirectory $Asset.Filename
    $partPath = '{0}.{1}.{2}.part' -f `
        $destination, $PID, [Guid]::NewGuid().ToString('N')

    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        if (Test-CjmanFileHash -Path $destination -ExpectedSha256 $Asset.Sha256) {
            return $destination
        }
        Remove-Item -LiteralPath $destination -Force -ErrorAction Stop
    }

    Write-Information `
        -MessageData "Downloading $($Asset.Filename)..." `
        -InformationAction Continue
    Enable-CjmanTls12
    $oldProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest `
            -Uri $Asset.Url `
            -OutFile $partPath `
            -UseBasicParsing `
            -ErrorAction Stop

        Move-Item -LiteralPath $partPath -Destination $destination -Force -ErrorAction Stop

        if (-not (Test-CjmanFileHash -Path $destination -ExpectedSha256 $Asset.Sha256)) {
            throw "SHA-256 or ZIP validation failed for '$($Asset.Filename)'."
        }

        return $destination
    } catch {
        Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        $ProgressPreference = $oldProgressPreference
    }
}

function Confirm-CjmanSafeZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [long]$MaximumExpandedBytes = 8589934592,
        [int]$MaximumEntries = 100000
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

    $root = [System.IO.Path]::GetFullPath($DestinationPath).
        TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::OrdinalIgnoreCase)
    $archive = $null
    $entryCount = 0
    [long]$expandedBytes = 0

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        foreach ($entry in $archive.Entries) {
            $entryCount++
            if ($entryCount -gt $MaximumEntries) {
                throw "ZIP '$ArchivePath' contains too many entries."
            }

            $entryName = ([string]$entry.FullName).Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($entryName) -or
                $entryName.StartsWith('/') -or
                $entryName -match '^[A-Za-z]:' -or
                $entryName.StartsWith('//') -or
                $entryName -match '[\x00-\x1f]' -or
                $entryName.Contains(':')) {
                throw "ZIP '$ArchivePath' contains unsafe path '$entryName'."
            }

            $segments = @($entryName.Split('/') | Where-Object { $_ -ne '' })
            foreach ($segment in $segments) {
                if ($segment -eq '..' -or $segment -eq '.') {
                    throw "ZIP '$ArchivePath' contains traversal path '$entryName'."
                }

                $trimmedSegment = $segment.TrimEnd(' ', '.')
                if ([string]::IsNullOrEmpty($trimmedSegment)) {
                    throw "ZIP '$ArchivePath' contains invalid Windows path '$entryName'."
                }
                $deviceStem = ($trimmedSegment -split '\.')[0]
                if ($deviceStem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
                    throw "ZIP '$ArchivePath' contains reserved Windows path '$entryName'."
                }
            }

            $normalizedEntry = $segments -join '/'
            if (-not $seen.Add($normalizedEntry)) {
                throw "ZIP '$ArchivePath' contains duplicate path '$entryName'."
            }

            $destination = [System.IO.Path]::GetFullPath((Join-Path $root $entryName))
            if (-not $destination.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "ZIP '$ArchivePath' escapes its extraction directory through '$entryName'."
            }

            $unixFileType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            $isReparsePoint = ($entry.ExternalAttributes -band
                [int][System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($unixFileType -eq 0xA000 -or $isReparsePoint) {
                throw "ZIP '$ArchivePath' contains a symbolic link or reparse point '$entryName'."
            }

            if ($entry.Length -lt 0 -or $entry.Length -gt $MaximumExpandedBytes) {
                throw "ZIP '$ArchivePath' contains an oversized entry '$entryName'."
            }
            $expandedBytes += $entry.Length
            if ($expandedBytes -gt $MaximumExpandedBytes) {
                throw "ZIP '$ArchivePath' expands beyond the configured size limit."
            }
        }
    } finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Expand-CjmanZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Confirm-CjmanSafeZip -ArchivePath $ArchivePath -DestinationPath $DestinationPath
    New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
    Expand-Archive `
        -LiteralPath $ArchivePath `
        -DestinationPath $DestinationPath `
        -Force `
        -ErrorAction Stop
}

function Expand-CjmanInstallerExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Confirm-CjmanSafeInstallerExe `
        -ArchivePath $ArchivePath `
        -DestinationPath $DestinationPath
    New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
    $sevenZip = Get-CjmanSevenZipCommand
    $output = @(& $sevenZip 'x' '-y' "-o$DestinationPath" `
        '-x!$PLUGINSDIR/*' '-x!uninstall.exe' '--' $ArchivePath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("7-Zip could not extract installer '$ArchivePath': " +
            "$($output -join [Environment]::NewLine)")
    }
}

function Expand-CjmanSdkArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Asset,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if ($Asset.Format -eq 'zip') {
        Expand-CjmanZip -ArchivePath $ArchivePath -DestinationPath $DestinationPath
    } elseif ($Asset.Format -eq 'exe') {
        Expand-CjmanInstallerExe -ArchivePath $ArchivePath -DestinationPath $DestinationPath
    } else {
        throw "Unsupported Windows SDK archive format '$($Asset.Format)'."
    }
}

function Get-CjmanSdkRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExtractionPath
    )

    $namedRoots = @(Get-ChildItem -LiteralPath $ExtractionPath -Directory -Force |
        Where-Object { $_.Name -ieq 'cangjie' })
    if ($namedRoots.Count -eq 1) {
        return $namedRoots[0].FullName
    }

    if (Test-Path -LiteralPath (Join-Path $ExtractionPath 'envsetup.ps1') -PathType Leaf) {
        return $ExtractionPath
    }

    throw "SDK archive does not contain one cangjie root with envsetup.ps1."
}

function Get-CjmanOverlayRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExtractionPath
    )

    $namedRoots = @(Get-ChildItem -LiteralPath $ExtractionPath -Directory -Force |
        Where-Object { $_.Name -ieq 'cangjie' })
    if ($namedRoots.Count -eq 1) {
        return $namedRoots[0].FullName
    }

    $children = @(Get-ChildItem -LiteralPath $ExtractionPath -Force)
    $directories = @($children | Where-Object { $_.PSIsContainer })
    $files = @($children | Where-Object { -not $_.PSIsContainer })
    if ($directories.Count -eq 1 -and $files.Count -eq 0) {
        return $directories[0].FullName
    }

    return $ExtractionPath
}

function Copy-CjmanDirectoryContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $SourcePath -Force)) {
        Copy-Item `
            -LiteralPath $item.FullName `
            -Destination $DestinationPath `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }
}

function Test-CjmanInstalledSdk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleasePath
    )

    return (Test-Path -LiteralPath (Join-Path $ReleasePath 'envsetup.ps1') -PathType Leaf)
}

function Get-CjmanInstallMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleasePath
    )

    $values = @{}
    $markerPath = Join-Path $ReleasePath '.cjman-install.tsv'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $values
    }

    foreach ($line in @(Get-Content -LiteralPath $markerPath -ErrorAction Stop)) {
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($parts[0])) {
            $key = $parts[0].TrimStart([char]0xFEFF)
            $values[$key] = $parts[1]
        }
    }

    return $values
}

function Set-CjmanInstallMarker {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleasePath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    $existing = Get-CjmanInstallMarker -ReleasePath $ReleasePath
    foreach ($key in $Values.Keys) {
        $existing[$key] = $Values[$key]
    }

    if (-not $existing.ContainsKey('installed_at')) {
        $existing['installed_at'] = [DateTimeOffset]::UtcNow.ToString('o')
    }

    $orderedKeys = @(
        'version', 'channel', 'host_os', 'host_arch', 'target_os', 'target_arch',
        'sdk_filename', 'frontend_filename', 'stdx_version', 'stdx_target', 'installed_at'
    )
    $extraKeys = @($existing.Keys | Where-Object { $_ -notin $orderedKeys } | Sort-Object)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($orderedKeys + $extraKeys)) {
        if (-not $existing.ContainsKey($key)) {
            continue
        }

        $value = [string]$existing[$key]
        $value = $value.Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ')
        $lines.Add("$key`t$value")
    }

    $markerPath = Join-Path $ReleasePath '.cjman-install.tsv'
    if (-not $PSCmdlet.ShouldProcess($markerPath, 'Write cjman installation marker')) {
        return
    }

    $partPath = "$markerPath.part"
    try {
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($partPath, [string[]]$lines, $utf8WithoutBom)
        Move-Item -LiteralPath $partPath -Destination $markerPath -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-CjmanMarkerValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedVersion,

        [Parameter(Mandatory = $true)]
        [object]$Configuration,

        [AllowEmptyString()]
        [string]$SdkFilename,

        [AllowEmptyString()]
        [string]$FrontendFilename,

        [AllowEmptyString()]
        [string]$StdxVersion,

        [AllowEmptyString()]
        [string]$StdxTarget
    )

    return @{
        version = $ResolvedVersion.Version
        channel = $ResolvedVersion.Channel
        host_os = 'windows'
        host_arch = $Configuration.HostArch
        target_os = $Configuration.Target
        target_arch = $Configuration.TargetArch
        sdk_filename = $SdkFilename
        frontend_filename = $FrontendFilename
        stdx_version = $StdxVersion
        stdx_target = $StdxTarget
        installed_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Add-CjmanStdxToPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$PayloadPath
    )

    $stdxPath = Join-Path $PayloadPath 'stdx'
    if (Test-Path -LiteralPath $stdxPath) {
        throw "Staging payload already contains '$stdxPath'."
    }

    New-Item -ItemType Directory -Path $stdxPath -ErrorAction Stop | Out-Null
    try {
        Expand-CjmanZip -ArchivePath $ArchivePath -DestinationPath $stdxPath
        if (@(Get-ChildItem -LiteralPath $stdxPath -Force).Count -eq 0) {
            throw 'stdx archive is empty.'
        }
    } catch {
        Remove-Item -LiteralPath $stdxPath -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Install-CjmanStdxIntoExisting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedVersion,

        [Parameter(Mandatory = $true)]
        [object]$Configuration,

        [Parameter(Mandatory = $true)]
        [string]$ReleasePath,

        [switch]$Explicit
    )

    if (-not (Test-CjmanInstalledSdk -ReleasePath $ReleasePath)) {
        throw "Cangjie SDK is not installed at '$ReleasePath'."
    }

    $asset = Get-CjmanStdxAsset `
        -ResolvedVersion $ResolvedVersion `
        -Configuration $Configuration
    if ($null -eq $asset) {
        if ($Explicit) {
            throw ("No stdx release matches Cangjie $($ResolvedVersion.Version) and " +
                "$(Get-CjmanStdxTarget -Configuration $Configuration).")
        }
        Write-Warning "No matching stdx asset was found; the SDK remains installed."
        return $null
    }

    $marker = Get-CjmanInstallMarker -ReleasePath $ReleasePath
    $stdxPath = Join-Path $ReleasePath 'stdx'
    if ((Test-Path -LiteralPath $stdxPath -PathType Container) -and
        $marker.ContainsKey('stdx_version') -and
        $marker['stdx_version'] -eq $asset.ComponentVersion) {
        return $asset
    }

    $archivePath = Save-CjmanAsset -Asset $asset
    $parent = Split-Path -Parent $ReleasePath
    $stagePath = Join-Path $parent ('.stdx-staging-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagePath -ErrorAction Stop | Out-Null
    $newStdxPath = Join-Path $stagePath 'stdx'
    New-Item -ItemType Directory -Path $newStdxPath -ErrorAction Stop | Out-Null

    try {
        Expand-CjmanZip -ArchivePath $archivePath -DestinationPath $newStdxPath
        if (@(Get-ChildItem -LiteralPath $newStdxPath -Force).Count -eq 0) {
            throw 'stdx archive is empty.'
        }

        $backupPath = $null
        if (Test-Path -LiteralPath $stdxPath) {
            $backupPath = Join-Path $ReleasePath ('.stdx-backup-' + [Guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $stdxPath -Destination $backupPath -ErrorAction Stop
        }

        try {
            Move-Item -LiteralPath $newStdxPath -Destination $stdxPath -ErrorAction Stop
            Set-CjmanInstallMarker -ReleasePath $ReleasePath -Values @{
                stdx_version = $asset.ComponentVersion
                stdx_target = $asset.StdxTarget
            }
        } catch {
            $installFailure = $_
            $rollbackFailures = [System.Collections.Generic.List[string]]::new()

            if (Test-Path -LiteralPath $stdxPath) {
                try {
                    Remove-Item `
                        -LiteralPath $stdxPath `
                        -Recurse `
                        -Force `
                        -ErrorAction Stop
                } catch {
                    $rollbackFailures.Add(
                        "could not remove the failed stdx directory: $($_.Exception.Message)"
                    )
                }
            }

            if ($null -ne $backupPath) {
                if (Test-Path -LiteralPath $backupPath) {
                    try {
                        Move-Item `
                            -LiteralPath $backupPath `
                            -Destination $stdxPath `
                            -ErrorAction Stop
                    } catch {
                        $rollbackFailures.Add(
                            "could not restore '$backupPath': $($_.Exception.Message)"
                        )
                    }
                } else {
                    $rollbackFailures.Add(
                        "the previous stdx backup '$backupPath' is missing"
                    )
                }
            }

            if ($rollbackFailures.Count -ne 0) {
                throw ("stdx upgrade failed: $($installFailure.Exception.Message); " +
                    "rollback was incomplete: $($rollbackFailures -join '; ')")
            }

            throw $installFailure
        }

        if ($null -ne $backupPath) {
            Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        return $asset
    } finally {
        Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-CjmanSdk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedVersion,

        [Parameter(Mandatory = $true)]
        [object]$Configuration,

        [switch]$WithoutStdx
    )

    $bundles = Get-CjmanBundlesDirectory
    New-Item -ItemType Directory -Path $bundles -Force -ErrorAction Stop | Out-Null
    $releasePath = Resolve-CjmanReleasePath `
        -Version $ResolvedVersion.Version `
        -Configuration $Configuration
    $lockPath = "$releasePath.lock"
    $lockAcquired = $false

    try {
        try {
            New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
            $lockAcquired = $true
        } catch {
            throw "Another cjman operation is using '$releasePath'."
        }

        if (Test-Path -LiteralPath $releasePath) {
            if (-not (Test-CjmanInstalledSdk -ReleasePath $releasePath)) {
                throw "Existing release directory '$releasePath' is incomplete; it was not overwritten."
            }

            if ($ResolvedVersion.IsNightly) {
                $existingSdkAsset = Select-CjmanNightlySdkAsset `
                    -Release $ResolvedVersion.Release `
                    -Configuration $Configuration
                $existingFrontendAsset = Select-CjmanNightlyFrontendAsset `
                    -Release $ResolvedVersion.Release `
                    -Configuration $Configuration `
                    -ExpectedBuildVersion $existingSdkAsset.ComponentVersion
                if ($null -ne $existingFrontendAsset) {
                    $existingFrontendFilename = $existingFrontendAsset.Filename
                } else {
                    $existingFrontendFilename = ''
                }
            } else {
                $existingSdkAsset = Select-CjmanFormalSdkAsset `
                    -Version $ResolvedVersion.Version `
                    -Configuration $Configuration
                $existingFrontendFilename = ''
            }

            $existingMarker = Get-CjmanInstallMarker -ReleasePath $releasePath
            if ($existingMarker.ContainsKey('stdx_version')) {
                $existingStdxVersion = $existingMarker['stdx_version']
            } else {
                $existingStdxVersion = ''
            }
            if ($existingMarker.ContainsKey('stdx_target')) {
                $existingStdxTarget = $existingMarker['stdx_target']
            } else {
                $existingStdxTarget = ''
            }

            $existingMarkerValues = Get-CjmanMarkerValue `
                -ResolvedVersion $ResolvedVersion `
                -Configuration $Configuration `
                -SdkFilename $existingSdkAsset.Filename `
                -FrontendFilename $existingFrontendFilename `
                -StdxVersion $existingStdxVersion `
                -StdxTarget $existingStdxTarget
            if ($existingMarker.ContainsKey('installed_at')) {
                [void]$existingMarkerValues.Remove('installed_at')
            }
            Set-CjmanInstallMarker `
                -ReleasePath $releasePath `
                -Values $existingMarkerValues

            if (-not $WithoutStdx) {
                try {
                    [void](Install-CjmanStdxIntoExisting `
                        -ResolvedVersion $ResolvedVersion `
                        -Configuration $Configuration `
                        -ReleasePath $releasePath)
                } catch {
                    Write-Warning "stdx installation failed: $($_.Exception.Message)"
                }
            }

            Write-Information `
                -MessageData "Cangjie $($ResolvedVersion.Version) is already installed at $releasePath" `
                -InformationAction Continue
            return $releasePath
        }

        if ($ResolvedVersion.IsNightly) {
            $sdkAsset = Select-CjmanNightlySdkAsset `
                -Release $ResolvedVersion.Release `
                -Configuration $Configuration
            $frontendAsset = Select-CjmanNightlyFrontendAsset `
                -Release $ResolvedVersion.Release `
                -Configuration $Configuration `
                -ExpectedBuildVersion $sdkAsset.ComponentVersion
        } else {
            $sdkAsset = Select-CjmanFormalSdkAsset `
                -Version $ResolvedVersion.Version `
                -Configuration $Configuration
            $frontendAsset = $null
        }

        if ($sdkAsset.Format -eq 'exe') {
            [void](Get-CjmanSevenZipCommand)
        }
        $sdkArchive = Save-CjmanAsset -Asset $sdkAsset
        if ($null -ne $frontendAsset) {
            $frontendArchive = Save-CjmanAsset -Asset $frontendAsset
        } else {
            $frontendArchive = $null
        }

        $stagePath = Join-Path $bundles ('.install-staging-' + [Guid]::NewGuid().ToString('N'))
        $sdkExtractionPath = Join-Path $stagePath 'sdk'
        New-Item -ItemType Directory -Path $sdkExtractionPath -Force -ErrorAction Stop | Out-Null
        try {
            Expand-CjmanSdkArchive `
                -Asset $sdkAsset `
                -ArchivePath $sdkArchive `
                -DestinationPath $sdkExtractionPath
            $sdkRoot = Get-CjmanSdkRoot -ExtractionPath $sdkExtractionPath
            $payloadPath = Join-Path $stagePath 'payload'

            if ($sdkRoot -eq $sdkExtractionPath) {
                New-Item -ItemType Directory -Path $payloadPath -ErrorAction Stop | Out-Null
                Copy-CjmanDirectoryContent `
                    -SourcePath $sdkExtractionPath `
                    -DestinationPath $payloadPath
            } else {
                Move-Item -LiteralPath $sdkRoot -Destination $payloadPath -ErrorAction Stop
            }

            if ($null -ne $frontendArchive) {
                $frontendExtractionPath = Join-Path $stagePath 'frontend'
                New-Item -ItemType Directory -Path $frontendExtractionPath -ErrorAction Stop | Out-Null
                Expand-CjmanZip `
                    -ArchivePath $frontendArchive `
                    -DestinationPath $frontendExtractionPath
                $frontendRoot = Get-CjmanOverlayRoot -ExtractionPath $frontendExtractionPath
                Copy-CjmanDirectoryContent `
                    -SourcePath $frontendRoot `
                    -DestinationPath $payloadPath
            }

            if (-not (Test-CjmanInstalledSdk -ReleasePath $payloadPath)) {
                throw "Extracted SDK does not contain envsetup.ps1."
            }

            $stdxAsset = $null
            if (-not $WithoutStdx) {
                try {
                    $stdxAsset = Get-CjmanStdxAsset `
                        -ResolvedVersion $ResolvedVersion `
                        -Configuration $Configuration
                    if ($null -eq $stdxAsset) {
                        Write-Warning "No matching stdx asset was found; installing SDK without stdx."
                    } else {
                        $stdxArchive = Save-CjmanAsset -Asset $stdxAsset
                        Add-CjmanStdxToPayload `
                            -ArchivePath $stdxArchive `
                            -PayloadPath $payloadPath
                    }
                } catch {
                    $stdxAsset = $null
                    Write-Warning "stdx installation failed; installing SDK only: $($_.Exception.Message)"
                }
            }

            if ($null -ne $stdxAsset) {
                $stdxVersion = $stdxAsset.ComponentVersion
                $stdxTarget = $stdxAsset.StdxTarget
            } else {
                $stdxVersion = ''
                $stdxTarget = ''
            }

            if ($null -ne $frontendAsset) {
                $frontendFilename = $frontendAsset.Filename
            } else {
                $frontendFilename = ''
            }

            $markerValues = Get-CjmanMarkerValue `
                -ResolvedVersion $ResolvedVersion `
                -Configuration $Configuration `
                -SdkFilename $sdkAsset.Filename `
                -FrontendFilename $frontendFilename `
                -StdxVersion $stdxVersion `
                -StdxTarget $stdxTarget
            Set-CjmanInstallMarker -ReleasePath $payloadPath -Values $markerValues

            if (Test-Path -LiteralPath $releasePath) {
                throw "Release path '$releasePath' appeared during installation."
            }
            Move-Item -LiteralPath $payloadPath -Destination $releasePath -ErrorAction Stop
        } finally {
            Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Information `
            -MessageData "Cangjie $($ResolvedVersion.Version) installed at $releasePath" `
            -InformationAction Continue
        Write-Information `
            -MessageData "Activate it with: cjman use $($ResolvedVersion.Version)" `
            -InformationAction Continue
        return $releasePath
    } finally {
        if ($lockAcquired) {
            Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-CjmanStdx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedVersion,

        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    $releasePath = Resolve-CjmanReleasePath `
        -Version $ResolvedVersion.Version `
        -Configuration $Configuration
    if (-not (Test-CjmanInstalledSdk -ReleasePath $releasePath)) {
        throw "Cangjie SDK is not installed at '$releasePath'."
    }

    $lockPath = "$releasePath.lock"
    $lockAcquired = $false

    try {
        try {
            New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
            $lockAcquired = $true
        } catch {
            throw "Another cjman operation is using '$releasePath'."
        }

        $asset = Install-CjmanStdxIntoExisting `
            -ResolvedVersion $ResolvedVersion `
            -Configuration $Configuration `
            -ReleasePath $releasePath `
            -Explicit
        Write-Information `
            -MessageData "stdx $($asset.ComponentVersion) installed under $releasePath\stdx" `
            -InformationAction Continue
        return (Join-Path $releasePath 'stdx')
    } finally {
        if ($lockAcquired) {
            Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-CjmanRootFromPathValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Value,

        [AllowEmptyString()]
        [string]$Root
    )

    if ([string]::IsNullOrEmpty($Value) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $Value
    }

    $separator = [string][System.IO.Path]::PathSeparator
    $comparison = [StringComparison]::OrdinalIgnoreCase
    try {
        $normalizedRoot = [System.IO.Path]::GetFullPath($Root).
            TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar
            )
    } catch {
        $normalizedRoot = $Root.TrimEnd('\', '/')
    }
    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    $kept = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($Value -split [regex]::Escape($separator))) {
        $normalizedEntry = $entry
        if (-not [string]::IsNullOrWhiteSpace($entry)) {
            try {
                $normalizedEntry = [System.IO.Path]::GetFullPath($entry).
                    TrimEnd(
                        [System.IO.Path]::DirectorySeparatorChar,
                        [System.IO.Path]::AltDirectorySeparatorChar
                    )
            } catch {
                $normalizedEntry = $entry.TrimEnd('\', '/')
            }
        }

        $insideRoot = $normalizedEntry.Equals($normalizedRoot, $comparison) -or
            $normalizedEntry.StartsWith($rootPrefix, $comparison)
        if (-not $insideRoot) {
            $kept.Add($entry)
        }
    }

    return ($kept -join $separator)
}

function Enable-CjmanEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentSetupPath,

        [Parameter(Mandatory = $true)]
        [string]$StdxPath,

        [Parameter(Mandatory = $true)]
        [string]$ReleasePath
    )

    $originalEnvironment =
        [System.Collections.Generic.Dictionary[string, string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    $processTarget = [EnvironmentVariableTarget]::Process
    $processEnvironment = [Environment]::GetEnvironmentVariables($processTarget)
    foreach ($name in $processEnvironment.Keys) {
        $originalEnvironment[[string]$name] = [string]$processEnvironment[$name]
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($env:CJMAN_ACTIVE_ROOT)) {
            foreach ($pathVariable in @('PATH', 'LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH')) {
                $oldValue = [Environment]::GetEnvironmentVariable($pathVariable, $processTarget)
                if ($null -ne $oldValue) {
                    $cleanValue = Remove-CjmanRootFromPathValue `
                        -Value $oldValue `
                        -Root $env:CJMAN_ACTIVE_ROOT
                    [Environment]::SetEnvironmentVariable(
                        $pathVariable,
                        $cleanValue,
                        $processTarget
                    )
                }
            }
        }

        . $EnvironmentSetupPath

        if ($null -ne $env:PATH) {
            $pathSeparator = [string][System.IO.Path]::PathSeparator
            $seenPathEntries = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            $uniquePathEntries = [System.Collections.Generic.List[string]]::new()
            foreach ($pathEntry in @($env:PATH -split [regex]::Escape($pathSeparator))) {
                if ($seenPathEntries.Add($pathEntry)) {
                    $uniquePathEntries.Add($pathEntry)
                }
            }
            $env:PATH = $uniquePathEntries -join $pathSeparator
        }

        if (Test-Path -LiteralPath $StdxPath -PathType Container) {
            $env:CJMAN_STDX_ROOT = $StdxPath
        } else {
            Remove-Item Env:CJMAN_STDX_ROOT -ErrorAction SilentlyContinue
        }
        $env:CJMAN_ACTIVE_ROOT = $ReleasePath
    } catch {
        $activationError = $_
        $currentEnvironment = [Environment]::GetEnvironmentVariables($processTarget)
        foreach ($name in @($currentEnvironment.Keys)) {
            if (-not $originalEnvironment.ContainsKey([string]$name)) {
                [Environment]::SetEnvironmentVariable(
                    [string]$name,
                    $null,
                    $processTarget
                )
            }
        }
        foreach ($entry in $originalEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable(
                $entry.Key,
                $entry.Value,
                $processTarget
            )
        }
        throw $activationError
    }
}

function Enable-CjmanSdk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedVersion,

        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    $releasePath = Resolve-CjmanReleasePath `
        -Version $ResolvedVersion.Version `
        -Configuration $Configuration
    $envSetup = Join-Path $releasePath 'envsetup.ps1'
    if (-not (Test-Path -LiteralPath $envSetup -PathType Leaf)) {
        throw ("Cangjie $($ResolvedVersion.Version) is not installed for target " +
            "$($Configuration.Target)/$($Configuration.TargetArch).")
    }

    $stdxPath = Join-Path $releasePath 'stdx'
    Enable-CjmanEnvironment `
        -EnvironmentSetupPath $envSetup `
        -StdxPath $stdxPath `
        -ReleasePath $releasePath

    Write-Information `
        -MessageData "Cangjie $($ResolvedVersion.Version) activated." `
        -InformationAction Continue
}

function Get-CjmanFormalTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $rows = @(Get-CjmanReleaseRecord -Version $Version)
    foreach ($row in $rows) {
        if (([string]$row.component).ToLowerInvariant() -ne 'sdk' -or
            ([string]$row.host_os).ToLowerInvariant() -ne 'windows' -or
            ([string]$row.format).TrimStart('.').ToLowerInvariant() -ne 'zip' -or
            ([string]$row.flavor).ToLowerInvariant() -ne 'default') {
            continue
        }

        [PSCustomObject]@{
            version = $Version
            host_arch = ([string]$row.host_arch).ToLowerInvariant()
            target = Get-CjmanLogicalTarget -Row $row
            target_arch = ([string]$row.target_arch).ToLowerInvariant()
            format = 'zip'
        }
    }
}

function Get-CjmanNightlyTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release
    )

    foreach ($asset in @($Release.assets)) {
        if ($asset.type -ne 'attach') {
            continue
        }

        $parsed = ConvertFrom-CjmanNightlySdkFilename -Filename ([string]$asset.name)
        if ($null -eq $parsed) {
            continue
        }

        [PSCustomObject]@{
            version = [string]$Release.tag_name
            asset_version = $parsed.Version
            host_arch = $parsed.HostArch
            target = $parsed.Target
            target_arch = $parsed.TargetArch
            format = $parsed.Format
        }
    }
}

function Show-CjmanList {
    [CmdletBinding()]
    param(
        [switch]$IncludeNightly
    )

    foreach ($row in @(Get-CjmanCatalog)) {
        [PSCustomObject]@{
            version = $row.version
            channel = $row.channel
            name = $row.display_name
            published_at = $row.published_at
        }
    }

    if ($IncludeNightly) {
        foreach ($release in @(Get-CjmanNightlyReleaseList |
            Sort-Object @{ Expression = { $_.created_at } } -Descending)) {
            [PSCustomObject]@{
                version = $release.tag_name
                channel = 'nightly'
                name = $release.name
                published_at = $release.created_at
            }
        }
    }
}

function Show-CjmanTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedVersion
    )

    if ($ResolvedVersion.IsNightly) {
        Get-CjmanNightlyTarget -Release $ResolvedVersion.Release |
            Sort-Object host_arch, target, target_arch -Unique
    } else {
        Get-CjmanFormalTarget -Version $ResolvedVersion.Version |
            Sort-Object host_arch, target, target_arch -Unique
    }
}

function Update-Cjman {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param()

    $homePath = Get-CjmanHome
    if (-not (Test-Path -LiteralPath (Join-Path $homePath '.git') -PathType Container)) {
        throw "cjman home '$homePath' is not a Git checkout."
    }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required to update cjman.'
    }
    if (-not $PSCmdlet.ShouldProcess($homePath, 'Pull the latest cjman Git revision')) {
        return
    }

    & git -C $homePath pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        throw "git pull failed with exit code $LASTEXITCODE."
    }

    Write-Information `
        -MessageData 'cjman updated. Reopen PowerShell or dot-source cjman.ps1 again to load it.' `
        -InformationAction Continue
}

function Show-CjmanUsage {
    [CmdletBinding()]
    param()

    @'
Usage: cjman <command> [arguments]

Commands:
  list [--nightly]
  targets VERSION
  install VERSION|latest|lts|sts|nightly [--target TARGET]
          [--target-arch ARCH] [--host-arch ARCH] [--without-stdx]
  install-stdx VERSION [--target TARGET] [--target-arch ARCH]
          [--host-arch ARCH]
  use VERSION [--target TARGET] [--target-arch ARCH] [--host-arch ARCH]
  update

Targets: native, android, ohos, ios, ios-simulator
Architectures: x64, aarch64, arm32
'@
}

function Invoke-CjmanCli {
    [CmdletBinding()]
    param(
        [string[]]$Arguments = @()
    )

    if ($Arguments.Count -eq 0) {
        Show-CjmanUsage
        return
    }

    $command = $Arguments[0].ToLowerInvariant()
    $remaining = @()
    if ($Arguments.Count -gt 1) {
        $remaining = @($Arguments[1..($Arguments.Count - 1)])
    }

    switch ($command) {
        'list' {
            if ($remaining.Count -eq 0) {
                Show-CjmanList
            } elseif ($remaining.Count -eq 1 -and $remaining[0] -eq '--nightly') {
                Show-CjmanList -IncludeNightly
            } else {
                throw 'Usage: cjman list [--nightly]'
            }
        }
        'targets' {
            if ($remaining.Count -ne 1) {
                throw 'Usage: cjman targets VERSION'
            }
            $resolved = Resolve-CjmanVersion -RequestedVersion $remaining[0]
            Show-CjmanTarget -ResolvedVersion $resolved
        }
        'install' {
            $parsed = ConvertFrom-CjmanInstallOption `
                -Arguments $remaining `
                -AllowWithoutStdx
            $resolved = Resolve-CjmanVersion -RequestedVersion $parsed.Version
            [void](Install-CjmanSdk `
                -ResolvedVersion $resolved `
                -Configuration $parsed.Configuration `
                -WithoutStdx:$parsed.WithoutStdx)
        }
        'install-stdx' {
            $parsed = ConvertFrom-CjmanInstallOption -Arguments $remaining
            $resolved = Resolve-CjmanVersion -RequestedVersion $parsed.Version
            [void](Install-CjmanStdx `
                -ResolvedVersion $resolved `
                -Configuration $parsed.Configuration)
        }
        'use' {
            $parsed = ConvertFrom-CjmanInstallOption -Arguments $remaining
            $resolved = Resolve-CjmanVersion -RequestedVersion $parsed.Version
            Enable-CjmanSdk `
                -ResolvedVersion $resolved `
                -Configuration $parsed.Configuration
        }
        'update' {
            if ($remaining.Count -ne 0) {
                throw 'Usage: cjman update'
            }
            Update-Cjman
        }
        { $_ -in @('help', '--help', '-h') } {
            Show-CjmanUsage
        }
        default {
            throw "Unknown cjman command '$command'."
        }
    }
}

function cjman {
    Invoke-CjmanCli -Arguments @($args)
}
