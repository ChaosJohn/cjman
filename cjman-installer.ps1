#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$GitProvider,
    [string]$ProfilePath,
    [switch]$SkipProfile
)

function Get-CjmanInstallerDefaultRoot {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:CJMAN_HOME)) {
        return [System.IO.Path]::GetFullPath($env:CJMAN_HOME)
    }

    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return (Join-Path $userProfile '.cjman')
}

function Get-CjmanInstallerProfilePath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return [System.IO.Path]::GetFullPath($Override)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$PROFILE.CurrentUserAllHosts)) {
        return [string]$PROFILE.CurrentUserAllHosts
    }

    return [string]$PROFILE
}

function Add-CjmanProfileEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfilePath,

        [Parameter(Mandatory = $true)]
        [string]$CjmanScriptPath
    )

    $profileDirectory = Split-Path -Parent $ProfilePath
    if (-not [string]::IsNullOrWhiteSpace($profileDirectory)) {
        New-Item `
            -ItemType Directory `
            -Path $profileDirectory `
            -Force `
            -ErrorAction Stop | Out-Null
    }

    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
        New-Item -ItemType File -Path $ProfilePath -Force -ErrorAction Stop | Out-Null
    }

    $escapedPath = $CjmanScriptPath.Replace("'", "''")
    $profileLine = ". '$escapedPath'"
    $existingLines = @(Get-Content -LiteralPath $ProfilePath -ErrorAction Stop)
    if ($existingLines -contains $profileLine) {
        return $false
    }

    $existingText = Get-Content `
        -LiteralPath $ProfilePath `
        -Raw `
        -ErrorAction Stop
    if ($null -eq $existingText) {
        $existingText = ''
    }
    if ($existingText.Length -ne 0 -and
        -not $existingText.EndsWith("`n") -and
        -not $existingText.EndsWith("`r")) {
        Add-Content `
            -LiteralPath $ProfilePath `
            -Value '' `
            -ErrorAction Stop
    }

    Add-Content `
        -LiteralPath $ProfilePath `
        -Value $profileLine `
        -ErrorAction Stop
    return $true
}

function Install-CjmanPowerShell {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Destination,

        [AllowEmptyString()]
        [string]$Provider,

        [AllowEmptyString()]
        [string]$ProfileOverride,

        [switch]$DoNotModifyProfile
    )

    if ([string]::IsNullOrWhiteSpace($Destination)) {
        $Destination = Get-CjmanInstallerDefaultRoot
    } else {
        $Destination = [System.IO.Path]::GetFullPath($Destination)
    }

    if ([string]::IsNullOrWhiteSpace($Provider)) {
        if (-not [string]::IsNullOrWhiteSpace($env:GIT_PROVIDER)) {
            $Provider = $env:GIT_PROVIDER
        } else {
            $Provider = 'gitcode.com'
        }
    }

    if ($Provider -notmatch '^[A-Za-z0-9.-]+$') {
        throw "Invalid Git provider '$Provider'."
    }
    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required to install cjman.'
    }

    $repositoryUrl = "https://$Provider/ChaosJohn/cjman.git"
    $cjmanScriptPath = Join-Path $Destination 'cjman.ps1'
    $destinationWasAbsent = -not (Test-Path -LiteralPath $Destination)

    if (-not $destinationWasAbsent) {
        if (-not (Test-Path -LiteralPath $cjmanScriptPath -PathType Leaf)) {
            $gitDirectory = Join-Path $Destination '.git'
            if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
                throw "Install root '$Destination' already exists but does not contain cjman.ps1."
            }

            & git -C $Destination pull --ff-only
            if ($LASTEXITCODE -ne 0) {
                throw "Could not update existing cjman checkout at '$Destination'."
            }
            if (-not (Test-Path -LiteralPath $cjmanScriptPath -PathType Leaf)) {
                throw "Updated cjman checkout still does not contain '$cjmanScriptPath'."
            }
        }
        Write-Information `
            -MessageData "Using existing cjman installation at $Destination" `
            -InformationAction Continue
    } else {
        $parentDirectory = Split-Path -Parent $Destination
        if (-not [string]::IsNullOrWhiteSpace($parentDirectory)) {
            New-Item `
                -ItemType Directory `
                -Path $parentDirectory `
                -Force `
                -ErrorAction Stop | Out-Null
        }

        try {
            & git clone --quiet -- $repositoryUrl $Destination
            if ($LASTEXITCODE -ne 0) {
                throw "git clone failed with exit code $LASTEXITCODE."
            }

            if (-not (Test-Path -LiteralPath $cjmanScriptPath -PathType Leaf)) {
                throw "The cloned repository does not contain '$cjmanScriptPath'."
            }
        } catch {
            if ($destinationWasAbsent -and (Test-Path -LiteralPath $Destination)) {
                Remove-Item `
                    -LiteralPath $Destination `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
            throw
        }
    }

    if (-not $DoNotModifyProfile) {
        $profilePath = Get-CjmanInstallerProfilePath -Override $ProfileOverride
        $added = Add-CjmanProfileEntry `
            -ProfilePath $profilePath `
            -CjmanScriptPath $cjmanScriptPath
        if ($added) {
            Write-Information `
                -MessageData "Added cjman to PowerShell profile: $profilePath" `
                -InformationAction Continue
        } else {
            Write-Information `
                -MessageData "PowerShell profile already loads cjman: $profilePath" `
                -InformationAction Continue
        }
    }

    Write-Information -MessageData 'cjman installed successfully.' -InformationAction Continue
    Write-Information -MessageData 'Load it in this session with:' -InformationAction Continue
    Write-Information `
        -MessageData ". '$($cjmanScriptPath.Replace("'", "''"))'" `
        -InformationAction Continue
}

Install-CjmanPowerShell `
    -Destination $InstallRoot `
    -Provider $GitProvider `
    -ProfileOverride $ProfilePath `
    -DoNotModifyProfile:$SkipProfile
