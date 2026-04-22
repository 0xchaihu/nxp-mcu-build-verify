[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$Config,
    [string]$Type,
    [switch]$DryRun,
    [switch]$FullToolOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue
    if ($nativePreferenceVariable) {
        $previousNativePreference = [bool]$nativePreferenceVariable.Value
        $global:PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        return & $Body
    }
    finally {
        if ($nativePreferenceVariable) {
            $global:PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }
}

function New-TemporaryDirectory {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("{0}-{1}" -f $Prefix, [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

$TypePriority = @{
    IAR = 1
    Keil = 2
    MCUXpressoIDE = 3
    MCUXpressoVSCode = 4
}

function Resolve-ForcedType {
    param([string]$RequestedType)

    if ([string]::IsNullOrWhiteSpace($RequestedType)) {
        return $null
    }

    $normalized = $RequestedType.Trim().ToLowerInvariant()
    $aliases = @{
        "iar"                = "IAR"
        "keil"               = "Keil"
        "mcuxpressoide"      = "MCUXpressoIDE"
        "mcux-ide"           = "MCUXpressoIDE"
        "ide"                = "MCUXpressoIDE"
        "mcuxpressovscode"   = "MCUXpressoVSCode"
        "mcux-vscode"        = "MCUXpressoVSCode"
        "vscode"             = "MCUXpressoVSCode"
        "cmake"              = "MCUXpressoVSCode"
    }

    if ($aliases.ContainsKey($normalized)) {
        return $aliases[$normalized]
    }

    throw "Unsupported -Type value '$RequestedType'. Supported values: IAR, Keil, MCUXpressoIDE, MCUXpressoVSCode (aliases: ide, vscode)."
}


function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-RelativeDepth {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $normalizedRoot = (Get-NormalizedPath -Path $Root).TrimEnd("\\")
    $normalizedChild = (Get-NormalizedPath -Path $Child).TrimEnd("\\")

    if ($normalizedChild -ieq $normalizedRoot) {
        return 0
    }

    if (-not $normalizedChild.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [int]::MaxValue
    }

    $relative = $normalizedChild.Substring($normalizedRoot.Length).TrimStart("\\")
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return 0
    }

    return ($relative -split "[\\/]").Count
}

function Get-ConfigAttempts {
    param(
        [string]$ExplicitConfig,
        [string[]]$Available
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitConfig)) {
        return @($ExplicitConfig)
    }

    $attempts = @()

    if ($Available -and $Available.Count -gt 0) {
        $debugMatch = $Available | Where-Object { $_ -match "(?i)debug" } | Select-Object -First 1
        $releaseMatch = $Available | Where-Object { $_ -match "(?i)release" } | Select-Object -First 1

        if ($debugMatch) {
            $attempts += $debugMatch
        }
        if ($releaseMatch -and $releaseMatch -ne $debugMatch) {
            $attempts += $releaseMatch
        }

        foreach ($item in $Available) {
            if ($attempts -notcontains $item) {
                $attempts += $item
            }
        }
    }

    if ($attempts.Count -eq 0) {
        $attempts = @("Debug", "Release")
    }

    return $attempts
}

function Get-MarkerCandidatesInDirectory {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $results = @()

    $iarProjects = @(Get-ChildItem -LiteralPath $Directory -Filter "*.ewp*" -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq ".ewp" } | Sort-Object Name)
    foreach ($project in $iarProjects) {
        $results += [PSCustomObject]@{
            Type            = "IAR"
            MarkerFile      = $project.FullName
            MarkerDirectory = $Directory
        }
    }

    $keilProjects = @(Get-ChildItem -LiteralPath $Directory -Filter "*.uvprojx*" -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq ".uvprojx" } | Sort-Object Name)
    foreach ($project in $keilProjects) {
        $results += [PSCustomObject]@{
            Type            = "Keil"
            MarkerFile      = $project.FullName
            MarkerDirectory = $Directory
        }
    }

    $presetPath = Join-Path -Path $Directory -ChildPath "CMakePresets.json"
    $workspaceFiles = @(Get-ChildItem -LiteralPath $Directory -Filter "*.code-workspace" -File -ErrorAction SilentlyContinue)
    $tasksPath = Join-Path -Path $Directory -ChildPath ".vscode\\tasks.json"

    $hasPreset = Test-Path -LiteralPath $presetPath
    $hasWorkspaceAndTasks = ($workspaceFiles.Count -gt 0) -and (Test-Path -LiteralPath $tasksPath)

    if ($hasPreset -or $hasWorkspaceAndTasks) {
        $marker = if ($hasPreset) { $presetPath } else { $tasksPath }
        $results += [PSCustomObject]@{
            Type            = "MCUXpressoVSCode"
            MarkerFile      = $marker
            MarkerDirectory = $Directory
        }
    }

    $projectPath = Join-Path -Path $Directory -ChildPath ".project"
    $cprojectPath = Join-Path -Path $Directory -ChildPath ".cproject"
    $hasIdePair = (Test-Path -LiteralPath $projectPath) -and (Test-Path -LiteralPath $cprojectPath)

    if ($hasIdePair -and -not ($hasPreset -or $hasWorkspaceAndTasks)) {
        $results += [PSCustomObject]@{
            Type            = "MCUXpressoIDE"
            MarkerFile      = $projectPath
            MarkerDirectory = $Directory
        }
    }

    return $results
}

function Select-BestCandidate {
    param(
        [Parameter(Mandatory = $true)][object[]]$Candidates,
        [Parameter(Mandatory = $true)][string]$ReferenceRoot
    )

    if ($Candidates.Count -eq 0) {
        throw "No project markers were found."
    }

    $grouped = $Candidates | Group-Object -Property MarkerDirectory
    foreach ($group in $grouped) {
        if ($group.Count -gt 1) {
            $distinctTypes = @($group.Group.Type | Select-Object -Unique)
            if ($distinctTypes.Count -gt 1) {
                $types = $distinctTypes | Sort-Object { $TypePriority[$_] }
                Write-Warning ("Multiple project types found in '{0}'. Priority will decide: {1}" -f $group.Name, ($types -join ", "))
            }
        }
    }

    $ranked = foreach ($candidate in $Candidates) {
        [PSCustomObject]@{
            Candidate = $candidate
            Depth     = Get-RelativeDepth -Root $ReferenceRoot -Child $candidate.MarkerDirectory
            Priority  = $TypePriority[$candidate.Type]
        }
    }

    return ($ranked | Sort-Object Depth, Priority | Select-Object -First 1).Candidate
}

function Resolve-ProjectType {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$ForcedType
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path

    # Pass 1: nearest marker while walking up from current location.
    $cursor = $resolvedRoot
    while ($true) {
        $localCandidates = @(Get-MarkerCandidatesInDirectory -Directory $cursor)
        if (-not [string]::IsNullOrWhiteSpace($ForcedType)) {
            $localCandidates = @($localCandidates | Where-Object { $_.Type -eq $ForcedType })
        }

        if ($localCandidates.Count -gt 0) {
            $chosen = Select-BestCandidate -Candidates $localCandidates -ReferenceRoot $cursor
            return $chosen
        }

        $parent = Split-Path -Path $cursor -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) {
            break
        }

        $cursor = $parent
    }

    # Pass 2: recursive scan inside provided root.
    $allCandidates = @()
    $scanDirectories = @($resolvedRoot)
    $scanDirectories += Get-ChildItem -LiteralPath $resolvedRoot -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }

    foreach ($directory in $scanDirectories) {
        $allCandidates += Get-MarkerCandidatesInDirectory -Directory $directory
    }

    if (-not [string]::IsNullOrWhiteSpace($ForcedType)) {
        $allCandidates = @($allCandidates | Where-Object { $_.Type -eq $ForcedType })
    }

    if ($allCandidates.Count -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($ForcedType)) {
            throw ("Cannot detect requested project type '{0}' under '{1}'." -f $ForcedType, $resolvedRoot)
        }

        throw ("Cannot detect supported project markers under '{0}'. Supported markers: *.ewp, *.uvprojx, .project+.cproject, CMakePresets.json, *.code-workspace + .vscode/tasks.json" -f $resolvedRoot)
    }

    $best = Select-BestCandidate -Candidates $allCandidates -ReferenceRoot $resolvedRoot
    return $best
}

function Resolve-ToolFromStandardPaths {
    param([string[]]$Patterns)

    foreach ($pattern in $Patterns) {
        $matches = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        if ($matches -and $matches.Count -gt 0) {
            return $matches[0].FullName
        }
    }

    return $null
}

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory = $true)][string[]]$CommandNames,
        [Parameter(Mandatory = $true)][string[]]$StandardPathPatterns,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )

    foreach ($name in $CommandNames) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }

    $standardTool = Resolve-ToolFromStandardPaths -Patterns $StandardPathPatterns
    if ($standardTool) {
        return $standardTool
    }

    $examples = ($StandardPathPatterns | Select-Object -First 3) -join "; "
    throw ("Required tool '{0}' is not found. Check PATH or install location. Typical paths: {1}" -f $FriendlyName, $examples)
}

function Quote-CommandPart {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -match '[\s"]') {
        $escaped = $Value -replace '"', '\\"'
        return ('"{0}"' -f $escaped)
    }

    return $Value
}

function Format-Command {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    $parts = @((Quote-CommandPart -Value $Exe))
    $parts += $Args | ForEach-Object { Quote-CommandPart -Value $_ }
    return ($parts -join " ")
}

function New-LogToken {
    param([Parameter(Mandatory = $true)][string]$Value)

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sanitizedChars = foreach ($char in $Value.ToCharArray()) {
        if ($invalid -contains $char -or [char]::IsWhiteSpace($char)) {
            '-'
        }
        else {
            [string]$char
        }
    }

    $sanitized = (-join $sanitizedChars).Trim('-')
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return 'build'
    }

    return $sanitized
}

function New-ToolLogPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Exe
    )

    $baseLogDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'nxp-mcu-build-verify-logs'
    $rootToken = New-LogToken -Value (Split-Path -Path $Root -Leaf)
    $logDir = Join-Path -Path $baseLogDir -ChildPath $rootToken
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $exeName = New-LogToken -Value ([System.IO.Path]::GetFileNameWithoutExtension($Exe))
    $unique = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    return Join-Path -Path $logDir -ChildPath ('{0}-{1}-{2}.log' -f $stamp, $exeName, $unique)
}

function Write-ToolLogSummary {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )

    # First, try to find the final MCUXpresso IDE build status line (Build Finished/Build Failed with timestamp)
    # This pattern matches lines like "12:38:01 Build Finished. 0 errors, 0 warnings. (took 9s.568ms)"
    $mcuxFinalPattern = '^\d{2}:\d{2}:\d{2}\s+Build\s+(Finished|Failed)\.'
    $mcuxStatusLines = @(
        Select-String -Path $LogPath -Pattern $mcuxFinalPattern -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Line
    )

    if ($mcuxStatusLines.Count -gt 0) {
        # Only output the LAST build status line (final result), ignoring intermediate clean/rebuild steps
        $finalLine = $mcuxStatusLines[-1].Trim()
        Write-Host ('tool_summary={0}' -f $finalLine)
        return
    }

    $summaryPatterns = @(
        'Total number of errors',
        'Total number of warnings',
        'Build succeeded',
        'Build failed'
    )
    $summaryLines = @(
        Select-String -Path $LogPath -Pattern $summaryPatterns -SimpleMatch -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Line -Unique
    )

    if ($summaryLines.Count -gt 0) {
        foreach ($line in $summaryLines | Select-Object -Last 8) {
            Write-Host ('tool_summary={0}' -f $line.Trim())
        }
        return
    }

    $tailCount = if ($ExitCode -eq 0) { 12 } else { 40 }
    $tailLines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue | Select-Object -Last $tailCount)
    foreach ($line in $tailLines) {
        Write-Host ('tool_tail={0}' -f $line)
    }
}

function Invoke-CommandOrDryRun {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args,
        [switch]$DryRunMode,
        [System.Collections.IDictionary]$EnvironmentOverrides
    )

    $normalizedArgs = @($Args | Where-Object { $null -ne $_ })
    $formatted = Format-Command -Exe $Exe -Args $normalizedArgs
    Write-Host ("selected_command={0}" -f $formatted)
    if ($EnvironmentOverrides -and $EnvironmentOverrides.Count -gt 0) {
        Write-Host ("selected_environment_keys={0}" -f (($EnvironmentOverrides.Keys | Sort-Object) -join ","))
    }

    if ($DryRunMode) {
        return 0
    }

    $invokeWithEnvironment = {
        param([scriptblock]$Body)

        if (-not $EnvironmentOverrides -or $EnvironmentOverrides.Count -eq 0) {
            return & $Body
        }

        $previousValues = @{}
        foreach ($key in $EnvironmentOverrides.Keys) {
            $envPath = "Env:{0}" -f $key
            $exists = Test-Path -LiteralPath $envPath
            $previousValues[$key] = [PSCustomObject]@{
                Exists = $exists
                Value  = if ($exists) { (Get-Item -LiteralPath $envPath).Value } else { $null }
            }

            $nextValue = $EnvironmentOverrides[$key]
            if ($null -eq $nextValue) {
                Remove-Item -LiteralPath $envPath -ErrorAction SilentlyContinue
            }
            else {
                Set-Item -LiteralPath $envPath -Value ([string]$nextValue)
            }
        }

        try {
            return & $Body
        }
        finally {
            foreach ($key in $EnvironmentOverrides.Keys) {
                $envPath = "Env:{0}" -f $key
                $previous = $previousValues[$key]
                if ($previous.Exists) {
                    Set-Item -LiteralPath $envPath -Value ([string]$previous.Value)
                }
                else {
                    Remove-Item -LiteralPath $envPath -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($FullToolOutput) {
        Write-Host 'tool_output_mode=full'
        $exitCode = Invoke-NativeCommand -Body {
            & $invokeWithEnvironment {
                & $Exe @normalizedArgs | Out-Host
                return [int]$LASTEXITCODE
            }
        }
        return $exitCode
    }

    $logPath = New-ToolLogPath -Root $resolvedRoot -Exe $Exe
    $stderrLogPath = [System.IO.Path]::ChangeExtension($logPath, '.stderr.log')
    Write-Host 'tool_output_mode=compact'
    Write-Host ('tool_log={0}' -f $logPath)

    $exitCode = Invoke-NativeCommand -Body {
        & $invokeWithEnvironment {
            $process = Start-Process -FilePath $Exe `
                -ArgumentList $normalizedArgs `
                -WorkingDirectory $resolvedRoot `
                -RedirectStandardOutput $logPath `
                -RedirectStandardError $stderrLogPath `
                -Wait `
                -PassThru `
                -WindowStyle Hidden
            return [int]$process.ExitCode
        }
    }

    if (-not (Test-Path -LiteralPath $logPath)) {
        New-Item -ItemType File -Path $logPath -Force | Out-Null
    }

    if (Test-Path -LiteralPath $stderrLogPath) {
        $stderrLines = @(Get-Content -LiteralPath $stderrLogPath -ErrorAction SilentlyContinue)
        if ($stderrLines.Count -gt 0) {
            Add-Content -LiteralPath $logPath -Value $stderrLines
        }
        Remove-Item -LiteralPath $stderrLogPath -Force -ErrorAction SilentlyContinue
    }

    Write-ToolLogSummary -LogPath $logPath -ExitCode $exitCode
    return $exitCode
}
function Get-IarConfigDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$EwpPath,
        [Parameter(Mandatory = $true)][string]$ConfigName
    )

    $projectDir = Split-Path -Path $EwpPath -Parent
    return Join-Path -Path $projectDir -ChildPath $ConfigName
}

function Get-IarSuccessfulArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigDirectory,
        [Parameter(Mandatory = $true)][datetime]$AttemptStarted
    )

    $candidatePatterns = @(
        "Exe\*.srec",
        "Exe\*.out",
        "List\*.map"
    )

    $freshArtifacts = @()

    foreach ($pattern in $candidatePatterns) {
        $freshArtifacts += Get-ChildItem -Path (Join-Path -Path $ConfigDirectory -ChildPath $pattern) -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $AttemptStarted.AddSeconds(-2) }
    }

    return $freshArtifacts | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-IarConfigs {
    param([Parameter(Mandatory = $true)][string]$EwpPath)

    try {
        [xml]$xml = Get-Content -LiteralPath $EwpPath
        $configs = @()

        foreach ($configuration in @($xml.project.configuration)) {
            if ($configuration.name) {
                $configs += [string]$configuration.name
            }
        }

        return $configs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    }
    catch {
        Write-Warning "Cannot parse IAR configurations from .ewp; fallback to Debug/Release guesses."
        return @()
    }
}


function Test-IsLikelySandboxedUserProfile {
    $username = [Environment]::UserName
    $userProfile = [Environment]::GetFolderPath('UserProfile')
    return ($username -match '(?i)sandbox') -or ($userProfile -match '(?i)sandbox')
}

function Test-IsLikelyCodexAgentEnvironment {
    return (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CODEX_THREAD_ID'))) -or
        (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CODEX_SANDBOX_NETWORK_DISABLED')))
}

function Convert-ToPowerShellSingleQuotedString {
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function Format-PowerShellInvocation {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    $quotedArgs = @($Args | Where-Object { $null -ne $_ } | ForEach-Object { Quote-CommandPart -Value $_ })
    return ('& {0}{1}' -f (Convert-ToPowerShellSingleQuotedString -Value $Exe), (' ' + ($quotedArgs -join ' ')).TrimEnd())
}

function Format-PowerShellEnvironmentAssignments {
    param([System.Collections.IDictionary]$EnvironmentOverrides)

    if (-not $EnvironmentOverrides -or $EnvironmentOverrides.Count -eq 0) {
        return @()
    }

    $segments = @()
    $currentPath = [Environment]::GetEnvironmentVariable('PATH')

    foreach ($key in ($EnvironmentOverrides.Keys | Sort-Object)) {
        $value = [string]$EnvironmentOverrides[$key]
        if ($key -eq 'PATH' -and -not [string]::IsNullOrWhiteSpace($currentPath)) {
            if ($value.Length -ge $currentPath.Length -and $value.EndsWith($currentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $prefix = $value.Substring(0, $value.Length - $currentPath.Length)
                $prefix = $prefix.TrimEnd(';')
                if (-not [string]::IsNullOrWhiteSpace($prefix)) {
                    $segments += ('$env:PATH={0} + '';'' + $env:PATH' -f (Convert-ToPowerShellSingleQuotedString -Value $prefix))
                    continue
                }
                if ($value.Length -eq $currentPath.Length) {
                    continue
                }
            }
        }

        $segments += ('$env:{0}={1}' -f $key, (Convert-ToPowerShellSingleQuotedString -Value $value))
    }

    return $segments
}

function Format-PowerShellCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args,
        [System.Collections.IDictionary]$EnvironmentOverrides
    )

    $segments = @(Format-PowerShellEnvironmentAssignments -EnvironmentOverrides $EnvironmentOverrides)
    $segments += Format-PowerShellInvocation -Exe $Exe -Args $Args
    return ($segments -join '; ')
}

function Format-PowerShellCommandSequence {
    param(
        [System.Collections.IDictionary]$EnvironmentOverrides,
        [Parameter(Mandatory = $true)][object[]]$Commands
    )

    $segments = @(Format-PowerShellEnvironmentAssignments -EnvironmentOverrides $EnvironmentOverrides)
    foreach ($command in $Commands) {
        $segments += Format-PowerShellInvocation -Exe $command.Exe -Args $command.Args
    }

    return ($segments -join '; ')
}

function Get-KeilInstallRoot {
    param([Parameter(Mandatory = $true)][string]$ToolPath)

    $toolDir = Split-Path -Path $ToolPath -Parent
    $parent = Split-Path -Path $toolDir -Parent
    if ([System.IO.Path]::GetFileName($parent) -ieq 'ARM') {
        return Split-Path -Path $parent -Parent
    }

    return $parent
}

function Test-KeilToolsIni {
    param([Parameter(Mandatory = $true)][string]$ToolPath)

    $installRoot = Get-KeilInstallRoot -ToolPath $ToolPath
    $toolsIniPath = Join-Path -Path $installRoot -ChildPath 'TOOLS.INI'
    $result = [PSCustomObject]@{
        InstallRoot = $installRoot
        ToolPath    = $ToolPath
        ToolsIni    = $toolsIniPath
        IsValid     = $false
        Reason      = ''
    }

    if (-not (Test-Path -LiteralPath $toolsIniPath)) {
        $result.Reason = 'missing TOOLS.INI'
        return $result
    }

    $content = @(Get-Content -LiteralPath $toolsIniPath -ErrorAction SilentlyContinue)
    if ($content.Count -eq 0) {
        $result.Reason = 'cannot read TOOLS.INI'
        return $result
    }

    $hasRtePath = $false
    $inArm = $false
    $hasArmPath = $false

    foreach ($line in $content) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^RTEPATH\s*=') {
            $hasRtePath = $true
        }
        if ($trimmed -match '^\[(.+)\]$') {
            $inArm = ($matches[1] -ieq 'ARM')
            continue
        }
        if ($inArm -and $trimmed -match '^PATH\s*=') {
            $hasArmPath = $true
        }
    }

    if (-not $hasArmPath) {
        $result.Reason = 'missing [ARM] PATH entry'
        return $result
    }

    if (-not $hasRtePath) {
        $result.Reason = 'missing RTEPATH entry'
        return $result
    }

    $result.IsValid = $true
    $result.Reason = 'ok'
    return $result
}


function Write-KeilToolsIniDiagnostics {
    param([Parameter(Mandatory = $true)][object[]]$Reports)

    foreach ($report in $Reports) {
        Write-Host ("keil_tools_ini={0}" -f $report.ToolsIni)
        Write-Host ("keil_tools_ini_issue={0}" -f $report.Reason)
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Write-Host ("keil_tools_ini_backup_hint=Copy-Item -LiteralPath '{0}' -Destination '{0}.bak.{1}'" -f $report.ToolsIni, $stamp)
        Write-Host ("keil_tools_ini_repair_hint=Do not auto-edit TOOLS.INI in this shared skill. Confirm with the user, back it up, then restore missing [ARM] PATH or RTEPATH from a known-good local Keil install.")
    }
}

function Resolve-KeilToolPath {
    $candidatePatterns = @(
        'C:\Users\*\AppData\Local\Keil_v5\UV4\uVision.com',
        'C:\Keil_v5\UV4\uVision.com',
        'C:\Program Files (x86)\Keil_v5\UV4\uVision.com',
        'C:\Users\*\AppData\Local\Keil_v5\UV4\UV4.exe',
        'C:\Keil_v5\UV4\UV4.exe',
        'C:\Keil_v5\ARM\UV4\UV4.exe',
        'C:\Program Files (x86)\Keil_v5\UV4\UV4.exe'
    )

    $reports = @()
    foreach ($pattern in $candidatePatterns) {
        $matches = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object FullName)
        foreach ($match in $matches) {
            $report = Test-KeilToolsIni -ToolPath $match.FullName
            $reports += $report
            if ($report.IsValid) {
                Write-Host ("keil_tools_ini={0}" -f $report.ToolsIni)
                return $report.ToolPath
            }
        }
    }

    if ($reports.Count -gt 0) {
        Write-KeilToolsIniDiagnostics -Reports $reports
        $summary = $reports | ForEach-Object { "{0} [{1}]" -f $_.ToolPath, $_.Reason }
        throw ("Keil tool(s) were found, but no installation has a usable TOOLS.INI. {0}. Do not auto-edit TOOLS.INI in this shared skill; confirm with the user, back it up, then repair it from a known-good local Keil install." -f ($summary -join '; '))
    }

    throw "Required tool 'Keil command line' is not found. Check PATH or install location."
}

function Invoke-KeilCommandOrDryRun {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args,
        [switch]$DryRunMode
    )

    $normalizedArgs = @($Args | Where-Object { $null -ne $_ })
    $formatted = Format-Command -Exe $Exe -Args $normalizedArgs
    Write-Host ("selected_command={0}" -f $formatted)

    if ($DryRunMode) {
        return 0
    }

    if ([System.IO.Path]::GetExtension($Exe).Equals('.com', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($FullToolOutput) {
            Write-Host 'tool_output_mode=full'
            $exitCode = Invoke-NativeCommand -Body {
                & $Exe @normalizedArgs | Out-Host
                return [int]$LASTEXITCODE
            }
            return $exitCode
        }

        $logPath = New-ToolLogPath -Root $resolvedRoot -Exe $Exe
        Write-Host 'tool_output_mode=compact'
        Write-Host ('tool_log={0}' -f $logPath)

        # uVision.com can crash under all-stream redirection, so capture first and write the log after.
        $capturedOutput = $null
        $exitCode = Invoke-NativeCommand -Body {
            $script:keilCompactOutput = @(& $Exe @normalizedArgs 2>&1)
            return [int]$LASTEXITCODE
        }
        $capturedOutput = $script:keilCompactOutput
        Remove-Variable -Name keilCompactOutput -Scope Script -ErrorAction SilentlyContinue
        if ($capturedOutput -and $capturedOutput.Count -gt 0) {
            $capturedOutput | Set-Content -LiteralPath $logPath
        }
        else {
            New-Item -ItemType File -Path $logPath -Force | Out-Null
        }
        Write-ToolLogSummary -LogPath $logPath -ExitCode $exitCode
        return $exitCode
    }


    if ($FullToolOutput) {
        Write-Host 'tool_output_mode=full'
        $process = Start-Process -FilePath $Exe -ArgumentList $Args -Wait -PassThru `
                -WindowStyle Hidden
        return [int]$process.ExitCode
    }

    $logPath = New-ToolLogPath -Root $resolvedRoot -Exe $Exe
    Write-Host 'tool_output_mode=compact'
    Write-Host ('tool_log={0}' -f $logPath)

    $stdoutPath = [System.IO.Path]::ChangeExtension($logPath, '.stdout.log')
    $stderrPath = [System.IO.Path]::ChangeExtension($logPath, '.stderr.log')
    $process = Start-Process -FilePath $Exe -ArgumentList $Args -Wait -PassThru `
                -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (Test-Path -LiteralPath $stdoutPath) {
        Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue | Set-Content -LiteralPath $logPath
    }
    if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue | Add-Content -LiteralPath $logPath
    }
    if (-not (Test-Path -LiteralPath $logPath)) {
        New-Item -ItemType File -Path $logPath -Force | Out-Null
    }
    Write-ToolLogSummary -LogPath $logPath -ExitCode $process.ExitCode
    return [int]$process.ExitCode
}

function Get-KeilTargets {
    param([Parameter(Mandatory = $true)][string]$UvprojxPath)

    try {
        [xml]$xml = Get-Content -LiteralPath $UvprojxPath
        $targets = @()

        foreach ($target in $xml.Project.Targets.Target) {
            if ($target.TargetName) {
                $targets += [string]$target.TargetName
            }
        }

        return $targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    }
    catch {
        Write-Warning "Cannot parse Keil targets from .uvprojx; fallback to Debug/Release guesses."
        return @()
    }
}

function Get-McuxIdeWorkspaceRoot {
    param([Parameter(Mandatory = $true)][string]$ProjectDirectory)

    $parent = Split-Path -Path $ProjectDirectory -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $metadataPath = Join-Path -Path $parent -ChildPath '.metadata'
        if (Test-Path -LiteralPath $metadataPath) {
            return $parent
        }
    }

    return $null
}

function Resolve-McuxIdeProjectDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDirectory,
        [Parameter(Mandatory = $true)][string]$ProjectName
    )

    $directWorkspace = Get-McuxIdeWorkspaceRoot -ProjectDirectory $ProjectDirectory
    if ($directWorkspace) {
        return $ProjectDirectory
    }

    $dirName = Split-Path -Path $ProjectDirectory -Leaf
    $searchPatterns = @(
        (Join-Path -Path $HOME -ChildPath ("Documents\MCUXpressoIDE_*\workspace\{0}" -f $dirName)),
        (Join-Path -Path $HOME -ChildPath ("Documents\workspace\{0}" -f $dirName)),
        (Join-Path -Path $HOME -ChildPath ("workspace\{0}" -f $dirName))
    )

    foreach ($pattern in $searchPatterns) {
        $matches = @(Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue | Sort-Object FullName)
        foreach ($match in $matches) {
            $projectFile = Join-Path -Path $match.FullName -ChildPath '.project'
            $cprojectFile = Join-Path -Path $match.FullName -ChildPath '.cproject'
            if (-not ((Test-Path -LiteralPath $projectFile) -and (Test-Path -LiteralPath $cprojectFile))) {
                continue
            }

            $matchedName = Get-McuxIdeProjectName -ProjectFile $projectFile
            if ($matchedName -eq $ProjectName) {
                return $match.FullName
            }
        }
    }

    return $ProjectDirectory
}

function Get-McuxIdeProjectName {
    param([Parameter(Mandatory = $true)][string]$ProjectFile)

    try {
        [xml]$xml = Get-Content -LiteralPath $ProjectFile
        if ($xml.projectDescription.name) {
            return [string]$xml.projectDescription.name
        }
    }
    catch {
        Write-Warning "Cannot parse .project file for project name; fallback to directory name."
    }

    return Split-Path -Path (Split-Path -Path $ProjectFile -Parent) -Leaf
}

function Get-McuxIdeConfigs {
    param([Parameter(Mandatory = $true)][string]$CprojectFile)

    try {
        [xml]$xml = Get-Content -LiteralPath $CprojectFile
        $nodes = $xml.SelectNodes("//configuration[@name]")
        $configs = [System.Collections.Generic.List[string]]::new()

        foreach ($node in $nodes) {
            $name = [string]$node.name
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $normalized = ($name -split "\|")[-1]
                if (-not [string]::IsNullOrWhiteSpace($normalized) -and -not $configs.Contains($normalized)) {
                    $configs.Add($normalized)
                }
            }
        }

        return ,$configs.ToArray()
    }
    catch {
        Write-Warning "Cannot parse .cproject for build configs; fallback to Debug/Release guesses."
        return @()
    }
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-OptionalProperty -Object $Object -Name $Name
    if ($null -ne $value) {
        return [string]$value
    }

    return $null
}

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Convert-ToArray {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        return @($Value)
    }

    return @($Value)
}

function Convert-ToDictionary {
    param([AllowNull()][object]$Object)

    $dictionary = [ordered]@{}
    if ($null -eq $Object) {
        return $dictionary
    }

    foreach ($property in $Object.PSObject.Properties) {
        $dictionary[$property.Name] = $property.Value
    }

    return $dictionary
}

function Convert-ToCMakeString {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return "TRUE"
        }

        return "FALSE"
    }

    return [string]$Value
}

function Merge-Dictionary {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Target,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Source
    )

    foreach ($key in $Source.Keys) {
        $Target[$key] = $Source[$key]
    }
}

function Get-PresetInherits {
    param([Parameter(Mandatory = $true)][object]$Preset)

    $inherits = Get-OptionalProperty -Object $Preset -Name "inherits"
    if ($null -eq $inherits) {
        return @()
    }

    return @(
        (Convert-ToArray -Value $inherits) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Add-CMakePresetDocument {
    param(
        [Parameter(Mandatory = $true)][string]$PresetFile,
        [Parameter(Mandatory = $true)][hashtable]$Visited,
        [Parameter(Mandatory = $true)][object]$Documents
    )

    $resolvedFile = (Resolve-Path -LiteralPath $PresetFile).Path
    if ($Visited.ContainsKey($resolvedFile)) {
        return
    }

    $Visited[$resolvedFile] = $true
    $directory = Split-Path -Path $resolvedFile -Parent
    $json = (Get-Content -LiteralPath $resolvedFile -Raw) | ConvertFrom-Json

    foreach ($includeEntry in (Convert-ToArray -Value (Get-OptionalProperty -Object $json -Name "include"))) {
        if ([string]::IsNullOrWhiteSpace([string]$includeEntry)) {
            continue
        }

        $includePath = [string]$includeEntry
        if (-not [System.IO.Path]::IsPathRooted($includePath)) {
            $includePath = Join-Path -Path $directory -ChildPath $includePath
        }

        if (-not (Test-Path -LiteralPath $includePath)) {
            throw ("CMake preset include file does not exist: {0}" -f $includePath)
        }

        Add-CMakePresetDocument -PresetFile $includePath -Visited $Visited -Documents $Documents
    }

    [void]$Documents.Add([PSCustomObject]@{
        Path      = $resolvedFile
        Directory = $directory
        Json      = $json
    })
}

function Get-CMakePresetDefinitions {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Documents,
        [Parameter(Mandatory = $true)][string]$CollectionName
    )

    $definitions = @{}

    foreach ($document in $Documents) {
        foreach ($item in (Convert-ToArray -Value (Get-OptionalProperty -Object $document.Json -Name $CollectionName))) {
            if ($null -eq $item) {
                continue
            }

            $name = Get-OptionalPropertyValue -Object $item -Name "name"
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            $definitions[$name] = [PSCustomObject]@{
                Name      = $name
                Directory = $document.Directory
                File      = $document.Path
                Data      = $item
            }
        }
    }

    return $definitions
}

function Resolve-CMakePresetString {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][hashtable]$CurrentEnvironment,
        [Parameter(Mandatory = $true)][hashtable]$ParentEnvironment
    )

    $resolved = Convert-ToCMakeString -Value $Value
    if ($null -eq $resolved) {
        return $null
    }

    $pathListSep = [System.IO.Path]::PathSeparator

    for ($index = 0; $index -lt 10; $index++) {
        $previous = $resolved

        $resolved = [regex]::Replace($resolved, '\$\{([^}]+)\}', {
            param($match)

            switch ($match.Groups[1].Value) {
                "sourceDir" { return [string]$Context.SourceDir }
                "sourceParentDir" { return [string]$Context.SourceParentDir }
                "fileDir" { return [string]$Context.FileDir }
                "presetName" { return [string]$Context.PresetName }
                "pathListSep" { return [string]$pathListSep }
                default { return $match.Value }
            }
        })

        $resolved = [regex]::Replace($resolved, '\$env\{([^}]+)\}', {
            param($match)

            $name = $match.Groups[1].Value
            if ($CurrentEnvironment.ContainsKey($name)) {
                return Convert-ToCMakeString -Value $CurrentEnvironment[$name]
            }

            if ($ParentEnvironment.ContainsKey($name)) {
                return Convert-ToCMakeString -Value $ParentEnvironment[$name]
            }

            return ""
        })

        $resolved = [regex]::Replace($resolved, '\$penv\{([^}]+)\}', {
            param($match)

            $name = $match.Groups[1].Value
            if ($ParentEnvironment.ContainsKey($name)) {
                return Convert-ToCMakeString -Value $ParentEnvironment[$name]
            }

            return ""
        })

        if ($resolved -ceq $previous) {
            break
        }
    }

    return $resolved
}

function Resolve-ConfigurePresetDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$PresetName,
        [Parameter(Mandatory = $true)][hashtable]$PresetDefinitions,
        [Parameter(Mandatory = $true)][hashtable]$ResolvedCache,
        [string[]]$ResolutionStack = @()
    )

    if ($ResolvedCache.ContainsKey($PresetName)) {
        return $ResolvedCache[$PresetName]
    }

    if ($ResolutionStack -contains $PresetName) {
        throw ("Circular configurePreset inheritance detected: {0}" -f (($ResolutionStack + $PresetName) -join " -> "))
    }

    if (-not $PresetDefinitions.ContainsKey($PresetName)) {
        throw ("Referenced configurePreset '{0}' was not found in the loaded CMake preset files." -f $PresetName)
    }

    $definition = $PresetDefinitions[$PresetName]
    $preset = $definition.Data
    $mergedEnvironment = [ordered]@{}
    $mergedCacheVariables = [ordered]@{}
    $generator = $null
    $binaryDir = $null
    $toolchainFile = $null
    $configuration = $null

    foreach ($parentName in (Get-PresetInherits -Preset $preset)) {
        $parent = Resolve-ConfigurePresetDefinition -PresetName $parentName -PresetDefinitions $PresetDefinitions -ResolvedCache $ResolvedCache -ResolutionStack ($ResolutionStack + $PresetName)
        if (-not [string]::IsNullOrWhiteSpace($parent.Generator)) {
            $generator = $parent.Generator
        }
        if (-not [string]::IsNullOrWhiteSpace($parent.BinaryDir)) {
            $binaryDir = $parent.BinaryDir
        }
        if (-not [string]::IsNullOrWhiteSpace($parent.ToolchainFile)) {
            $toolchainFile = $parent.ToolchainFile
        }
        if (-not [string]::IsNullOrWhiteSpace($parent.Configuration)) {
            $configuration = $parent.Configuration
        }

        Merge-Dictionary -Target $mergedEnvironment -Source $parent.Environment
        Merge-Dictionary -Target $mergedCacheVariables -Source $parent.CacheVariables
    }

    $ownGenerator = Get-OptionalPropertyValue -Object $preset -Name "generator"
    if (-not [string]::IsNullOrWhiteSpace($ownGenerator)) {
        $generator = $ownGenerator
    }

    $ownBinaryDir = Get-OptionalPropertyValue -Object $preset -Name "binaryDir"
    if (-not [string]::IsNullOrWhiteSpace($ownBinaryDir)) {
        $binaryDir = $ownBinaryDir
    }

    $ownToolchainFile = Get-OptionalPropertyValue -Object $preset -Name "toolchainFile"
    if (-not [string]::IsNullOrWhiteSpace($ownToolchainFile)) {
        $toolchainFile = $ownToolchainFile
    }

    $ownConfiguration = Get-OptionalPropertyValue -Object $preset -Name "configuration"
    if (-not [string]::IsNullOrWhiteSpace($ownConfiguration)) {
        $configuration = $ownConfiguration
    }

    Merge-Dictionary -Target $mergedEnvironment -Source (Convert-ToDictionary -Object (Get-OptionalProperty -Object $preset -Name "environment"))
    Merge-Dictionary -Target $mergedCacheVariables -Source (Convert-ToDictionary -Object (Get-OptionalProperty -Object $preset -Name "cacheVariables"))

    $resolved = [PSCustomObject]@{
        Name           = $PresetName
        Directory      = $definition.Directory
        File           = $definition.File
        Generator      = $generator
        BinaryDir      = $binaryDir
        ToolchainFile  = $toolchainFile
        Configuration  = $configuration
        Environment    = $mergedEnvironment
        CacheVariables = $mergedCacheVariables
    }

    $ResolvedCache[$PresetName] = $resolved
    return $resolved
}

function Resolve-ToolIfPresent {
    param(
        [Parameter(Mandatory = $true)][string[]]$CommandNames,
        [string[]]$StandardPathPatterns = @()
    )

    foreach ($pattern in $StandardPathPatterns) {
        $matches = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
        if ($matches.Count -gt 0) {
            return $matches[0].FullName
        }
    }

    foreach ($commandName in $CommandNames) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }

    return $null
}

function Resolve-PreferredFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string[]]$BaseDirectories
    )

    if ([System.IO.Path]::IsPathRooted($Candidate)) {
        return $Candidate
    }

    foreach ($baseDirectory in $BaseDirectories) {
        if ([string]::IsNullOrWhiteSpace($baseDirectory)) {
            continue
        }

        $combined = Join-Path -Path $baseDirectory -ChildPath $Candidate
        if (Test-Path -LiteralPath $combined) {
            return $combined
        }
    }

    return (Join-Path -Path $BaseDirectories[0] -ChildPath $Candidate)
}

function Get-CMakeConfigurePlan {
    param(
        [Parameter(Mandatory = $true)][string]$PresetFile,
        [Parameter(Mandatory = $true)][string]$ProjectDirectory,
        [string]$ExplicitConfig
    )

    $documents = New-Object System.Collections.ArrayList
    Add-CMakePresetDocument -PresetFile $PresetFile -Visited @{} -Documents $documents
    $configureDefinitions = Get-CMakePresetDefinitions -Documents $documents -CollectionName "configurePresets"
    $configurePresets = @($configureDefinitions.Values | ForEach-Object { $_.Data })

    if ($configurePresets.Count -eq 0) {
        throw "CMakePresets.json has no configurePresets."
    }

    $allPresetNames = @($configurePresets | ForEach-Object { Get-OptionalPropertyValue -Object $_ -Name "name" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Write-Host ("detected_configs={0}" -f ($allPresetNames -join ','))

    if (-not [string]::IsNullOrWhiteSpace($ExplicitConfig)) {
        $desiredConfigs = @($ExplicitConfig)
        $selectedConfigurePresets = @()

        foreach ($desired in $desiredConfigs) {
            $match = $configurePresets | Where-Object {
                $presetName = Get-OptionalPropertyValue -Object $_ -Name "name"
                $presetConfig = Get-OptionalPropertyValue -Object $_ -Name "configuration"
                ($presetName -eq $desired) -or
                (($presetName) -and ($presetName -match [regex]::Escape($desired))) -or
                ($presetConfig -eq $desired)
            } | Select-Object -First 1

            if ($match) {
                $matchName = Get-OptionalPropertyValue -Object $match -Name "name"
                $exists = $selectedConfigurePresets | Where-Object {
                    (Get-OptionalPropertyValue -Object $_ -Name "name") -eq $matchName
                }
                if (-not $exists) {
                    $selectedConfigurePresets += $match
                }
            }
        }

        if ($selectedConfigurePresets.Count -eq 0) {
            throw ("No CMake configure preset matches requested config '{0}'. Available presets: {1}" -f $ExplicitConfig, ($allPresetNames -join ', '))
        }
    }
    else {
        $orderedNames = Get-ConfigAttempts -ExplicitConfig $null -Available $allPresetNames
        $selectedConfigurePresets = @()
        foreach ($name in $orderedNames) {
            $preset = $configurePresets | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name "name") -eq $name } | Select-Object -First 1
            if ($preset -and -not ($selectedConfigurePresets | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name "name") -eq $name })) {
                $selectedConfigurePresets += $preset
            }
        }
    }

    $resolvedPresets = @{}
    $plans = @()
    $parentEnvironment = @{}
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $parentEnvironment[[string]$entry.Key] = Convert-ToCMakeString -Value $entry.Value
    }

    $projectParentDirectory = Split-Path -Path $ProjectDirectory -Parent

    foreach ($configurePreset in $selectedConfigurePresets) {
        $configureName = Get-OptionalPropertyValue -Object $configurePreset -Name "name"
        $resolvedPreset = Resolve-ConfigurePresetDefinition -PresetName $configureName -PresetDefinitions $configureDefinitions -ResolvedCache $resolvedPresets
        $context = @{
            SourceDir       = $ProjectDirectory
            SourceParentDir = $projectParentDirectory
            FileDir         = $resolvedPreset.Directory
            PresetName      = $configureName
        }

        $environment = [ordered]@{}
        foreach ($key in $resolvedPreset.Environment.Keys) {
            $environment[$key] = Resolve-CMakePresetString -Value $resolvedPreset.Environment[$key] -Context $context -CurrentEnvironment $environment -ParentEnvironment $parentEnvironment
        }

        $binaryDir = Resolve-CMakePresetString -Value $resolvedPreset.BinaryDir -Context $context -CurrentEnvironment $environment -ParentEnvironment $parentEnvironment
        if ([string]::IsNullOrWhiteSpace($binaryDir)) {
            $binaryDir = Join-Path -Path $ProjectDirectory -ChildPath ("build\\{0}" -f $configureName)
        }
        elseif (-not [System.IO.Path]::IsPathRooted($binaryDir)) {
            $binaryDir = Join-Path -Path $ProjectDirectory -ChildPath $binaryDir
        }

        $toolchainFile = Resolve-CMakePresetString -Value $resolvedPreset.ToolchainFile -Context $context -CurrentEnvironment $environment -ParentEnvironment $parentEnvironment
        if (-not [string]::IsNullOrWhiteSpace($toolchainFile)) {
            $toolchainFile = Resolve-PreferredFilePath -Candidate $toolchainFile -BaseDirectories @($resolvedPreset.Directory, $ProjectDirectory)
        }

        $cacheVariables = [ordered]@{}
        foreach ($key in $resolvedPreset.CacheVariables.Keys) {
            $rawValue = $resolvedPreset.CacheVariables[$key]
            if ($null -ne $rawValue -and $rawValue.PSObject.Properties['value']) {
                $rawValue = $rawValue.value
            }
            $cacheVariables[$key] = Resolve-CMakePresetString -Value $rawValue -Context $context -CurrentEnvironment $environment -ParentEnvironment $parentEnvironment
        }

        $generator = Resolve-CMakePresetString -Value $resolvedPreset.Generator -Context $context -CurrentEnvironment $environment -ParentEnvironment $parentEnvironment
        $configureConfig = Get-OptionalPropertyValue -Object $configurePreset -Name "configuration"
        if ([string]::IsNullOrWhiteSpace($configureConfig)) {
            $configureConfig = Resolve-CMakePresetString -Value $resolvedPreset.Configuration -Context $context -CurrentEnvironment $environment -ParentEnvironment $parentEnvironment
        }
        if ([string]::IsNullOrWhiteSpace($configureConfig) -and $cacheVariables.Contains("CMAKE_BUILD_TYPE")) {
            $configureConfig = Convert-ToCMakeString -Value $cacheVariables["CMAKE_BUILD_TYPE"]
        }

        if (-not [string]::IsNullOrWhiteSpace($generator) -and $generator -match "^Ninja") {
            $ninjaPath = Resolve-ToolIfPresent -CommandNames @("ninja.exe", "ninja") -StandardPathPatterns @(
                (Join-Path -Path $HOME -ChildPath '.mcuxpressotools\\ninja\\ninja.exe'),
                "C:\\NXP\\MCUXpressoIDE_*\\ide\\tools\\bin\\ninja.exe"
            )
            if (-not [string]::IsNullOrWhiteSpace($ninjaPath) -and -not $cacheVariables.Contains("CMAKE_MAKE_PROGRAM")) {
                $cacheVariables["CMAKE_MAKE_PROGRAM"] = $ninjaPath
            }
        }

        $plans += [PSCustomObject]@{
            ConfigurePreset = [string]$configureName
            BinaryDir       = $binaryDir
            Config          = $configureConfig
            Generator       = $generator
            ToolchainFile   = $toolchainFile
            CacheVariables  = $cacheVariables
            Environment     = $environment
        }
    }

    return $plans
}
function Invoke-BuildWithAttempts {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$AttemptBlock,
        [Parameter(Mandatory = $true)][string[]]$AttemptLabels
    )

    $lastExit = 1

    for ($index = 0; $index -lt $AttemptLabels.Count; $index++) {
        $label = $AttemptLabels[$index]
        Write-Host ("attempt={0}" -f $label)
        $code = & $AttemptBlock $label

        if ($code -eq 0) {
            return 0
        }

        $lastExit = $code
        Write-Warning ("Attempt failed for '{0}' with exit code {1}" -f $label, $code)
    }

    return $lastExit
}

try {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        throw ("ProjectRoot does not exist: {0}" -f $ProjectRoot)
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $forcedType = Resolve-ForcedType -RequestedType $Type
    $candidate = Resolve-ProjectType -Root $resolvedRoot -ForcedType $forcedType

    if (-not [string]::IsNullOrWhiteSpace($forcedType)) {
        Write-Host ("forced_type={0}" -f $forcedType)
    }

    Write-Host ("project_type={0}" -f $candidate.Type)
    Write-Host ("detected_file={0}" -f $candidate.MarkerFile)

    switch ($candidate.Type) {
        "IAR" {
            $toolPath = Resolve-ToolPath -CommandNames @("IarBuild.exe", "iarbuild") -StandardPathPatterns @(
                "C:\iar\ewarm-*\common\bin\iarbuild.exe",
                "C:\IAR\ewarm-*\common\bin\iarbuild.exe",
                "C:\Program Files\IAR Systems\Embedded Workbench *\common\bin\IarBuild.exe",
                "C:\Program Files (x86)\IAR Systems\Embedded Workbench *\common\bin\IarBuild.exe"
            ) -FriendlyName "IAR Build"

            Write-Host ("tool_path={0}" -f $toolPath)
            Write-Host "recommended_timeout_ms=1200000"
            Write-Host "preferred_execution_mode=host_or_unsandboxed"
            Write-Host "execution_hint=IAR real builds must run on the host or in an unsandboxed shell. In sandboxed or agent-run environments, emit host_execution_command, print sandbox_execution_refused=true, and refuse the in-place build. Once running on the host, allow at least 20 minutes before timing out."
            Write-Host "artifact_check_hint=If the command is interrupted, check <Config>\.ninja_log and <Config>\Exe\*.srec or *.out before treating it as failed."

            $iarConfigs = Get-IarConfigs -EwpPath $candidate.MarkerFile
            Write-Host ("detected_configs={0}" -f ($iarConfigs -join ','))
            $attempts = Get-ConfigAttempts -ExplicitConfig $Config -Available $iarConfigs
            $result = 1

            foreach ($label in $attempts) {
                Write-Host ("attempt={0}" -f $label)
                $attemptStarted = Get-Date
                $args = @($candidate.MarkerFile, "-make", $label, "-log", "all")
                $hostCommand = Format-Command -Exe $toolPath -Args $args
                Write-Host ("host_execution_command={0}" -f $hostCommand)

                if (((Test-IsLikelySandboxedUserProfile) -or (Test-IsLikelyCodexAgentEnvironment)) -and -not $DryRun) {
                    Write-Host "sandbox_execution_refused=true"
                    throw "Refusing to run IAR real builds inside the sandboxed/agent harness. Re-run the emitted host_execution_command on the host or in an unsandboxed shell."
                }

                $code = Invoke-CommandOrDryRun -Exe $toolPath -Args $args -DryRunMode:$DryRun

                if ($code -eq 0) {
                    $result = 0
                    break
                }

                if (-not $DryRun) {
                    $configDirectory = Get-IarConfigDirectory -EwpPath $candidate.MarkerFile -ConfigName $label
                    $artifact = Get-IarSuccessfulArtifact -ConfigDirectory $configDirectory -AttemptStarted $attemptStarted
                    if ($artifact) {
                        Write-Warning ("IAR returned exit code {0} but fresh build artifacts were produced; treating attempt '{1}' as successful." -f $code, $label)
                        Write-Host ("build_evidence={0}" -f $artifact.FullName)
                        Write-Host ("build_evidence_timestamp={0}" -f $artifact.LastWriteTime.ToString("s"))
                        $result = 0
                        break
                    }
                }

                $result = $code
                Write-Warning ("Attempt failed for '{0}' with exit code {1}" -f $label, $code)
            }

            if ($result -ne 0) {
                throw ("IAR build failed for all attempted configurations. Last exit code: {0}" -f $result)
            }
        }

        "Keil" {
            $toolPath = Resolve-KeilToolPath

            Write-Host ("tool_path={0}" -f $toolPath)
            Write-Host "preferred_execution_mode=host_or_unsandboxed"
            Write-Host "execution_hint=Keil real builds must run on the host or in an unsandboxed shell. In sandboxed or agent-run environments, emit host_execution_command, print sandbox_execution_refused=true, and refuse the in-place build. Prefer the real Windows user environment because sandbox usernames can invalidate user-based licenses. Prefer uVision.com over UV4.exe."

            $targets = Get-KeilTargets -UvprojxPath $candidate.MarkerFile
            Write-Host ("detected_configs={0}" -f ($targets -join ','))
            $attempts = Get-ConfigAttempts -ExplicitConfig $Config -Available $targets
            $result = Invoke-BuildWithAttempts -AttemptLabels $attempts -AttemptBlock {
                param($label)
                $args = @("-b", $candidate.MarkerFile, "-t", $label, "-j0")
                $hostCommand = Format-Command -Exe $toolPath -Args $args
                Write-Host ("host_execution_command={0}" -f $hostCommand)

                if (((Test-IsLikelySandboxedUserProfile) -or (Test-IsLikelyCodexAgentEnvironment)) -and -not $DryRun) {
                    Write-Host "sandbox_execution_refused=true"
                    throw "Refusing to run Keil real builds inside the sandboxed/agent harness. Re-run the emitted host_execution_command on the host or in an unsandboxed shell."
                }

                Invoke-KeilCommandOrDryRun -Exe $toolPath -Args $args -DryRunMode:$DryRun
            }

            if ($result -ne 0) {
                throw ("Keil build failed for all attempted targets. Last exit code: {0}" -f $result)
            }
        }

        "MCUXpressoIDE" {
            $toolPath = Resolve-ToolPath -CommandNames @("mcuxpressoidec.exe") -StandardPathPatterns @(
                "C:\nxp\MCUXpressoIDE_*\ide\mcuxpressoidec.exe",
                "C:\NXP\MCUXpressoIDE_*\ide\mcuxpressoidec.exe",
                "C:\Program Files\NXP\MCUXpressoIDE_*\ide\mcuxpressoidec.exe"
            ) -FriendlyName "MCUXpresso IDE Command Line"

            Write-Host ("tool_path={0}" -f $toolPath)
            Write-Host "preferred_execution_mode=host_or_unsandboxed"
            Write-Host "recommended_timeout_ms=1200000"
            Write-Host "execution_hint=Use mcuxpressoidec.exe with -nosplash --launcher.suppressErrors -application org.eclipse.cdt.managedbuilder.core.headlessbuild -data <workspace-or-temp-workspace> -build <project/config>. Prefer the real parent workspace when .metadata exists; otherwise use a temporary workspace plus -import. In sandboxed or agent-run environments, emit host_execution_command, print sandbox_execution_refused=true, refuse the in-place build, and never launch mcuxpressoide.exe."

            $projectDir = $candidate.MarkerDirectory
            $projectName = Get-McuxIdeProjectName -ProjectFile (Join-Path -Path $projectDir -ChildPath ".project")
            $projectDir = Resolve-McuxIdeProjectDirectory -ProjectDirectory $projectDir -ProjectName $projectName
            $ideConfigs = Get-McuxIdeConfigs -CprojectFile (Join-Path -Path $projectDir -ChildPath ".cproject")
            Write-Host ("detected_configs={0}" -f ($ideConfigs -join ','))
            $workspaceRoot = Get-McuxIdeWorkspaceRoot -ProjectDirectory $projectDir
            $attempts = Get-ConfigAttempts -ExplicitConfig $Config -Available $ideConfigs

            $result = Invoke-BuildWithAttempts -AttemptLabels $attempts -AttemptBlock {
                param($label)

                $hostCommandArgs = @(
                    "-nosplash",
                    "--launcher.suppressErrors",
                    "-configuration", "<writable-temp-configuration-dir>",
                    "-application", "org.eclipse.cdt.managedbuilder.core.headlessbuild",
                    "-data", $(if ($workspaceRoot) { $workspaceRoot } else { "<workspace-or-temp-workspace>" }),
                    "-build", ("{0}/{1}" -f $projectName, $label)
                )
                if (-not $workspaceRoot) {
                    $hostCommandArgs += @("-import", $projectDir)
                }
                $hostCommand = Format-Command -Exe $toolPath -Args $hostCommandArgs
                Write-Host ("host_execution_command={0}" -f $hostCommand)

                if (((Test-IsLikelySandboxedUserProfile) -or (Test-IsLikelyCodexAgentEnvironment)) -and -not $DryRun) {
                    Write-Host "sandbox_execution_refused=true"
                    throw "Refusing to run MCUXpresso IDE real builds inside the sandboxed/agent harness. Re-run the emitted host_execution_command on the host or in an unsandboxed shell, and never launch mcuxpressoide.exe."
                }

                $workspace = if ($workspaceRoot) {
                    $workspaceRoot
                }
                elseif ($DryRun) {
                    Join-Path -Path $env:TEMP -ChildPath "nxp-mcu-build-verify-DRYRUN"
                }
                else {
                    New-TemporaryDirectory -Prefix "nxp-mcu-build-verify-workspace"
                }

                $configurationDir = if ($DryRun) {
                    Join-Path -Path $env:TEMP -ChildPath "nxp-mcu-build-verify-CONFIG-DRYRUN"
                }
                else {
                    New-TemporaryDirectory -Prefix "nxp-mcu-build-verify-configuration"
                }

                Write-Host ("eclipse_configuration_dir={0}" -f $configurationDir)

                $args = @(
                    "-nosplash",
                    "--launcher.suppressErrors",
                    "-configuration", $configurationDir,
                    "-application", "org.eclipse.cdt.managedbuilder.core.headlessbuild",
                    "-data", $workspace,
                    "-build", ("{0}/{1}" -f $projectName, $label)
                )

                $usedTemporaryWorkspace = $false
                if (-not $workspaceRoot) {
                    $args += @( "-import", $projectDir )
                    $usedTemporaryWorkspace = -not $DryRun
                }

                try {
                    return Invoke-CommandOrDryRun -Exe $toolPath -Args $args -DryRunMode:$DryRun
                }
                finally {
                    if ($usedTemporaryWorkspace -and (Test-Path -LiteralPath $workspace)) {
                        Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    if (-not $DryRun -and (Test-Path -LiteralPath $configurationDir)) {
                        Remove-Item -LiteralPath $configurationDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            if ($result -ne 0) {
                throw ("MCUXpresso IDE build failed for all attempted configs. Last exit code: {0}" -f $result)
            }
        }

        "MCUXpressoVSCode" {
            $toolPath = Resolve-ToolPath -CommandNames @("cmake.exe", "cmake") -StandardPathPatterns @(
                "C:\Program Files\CMake\bin\cmake.exe"
            ) -FriendlyName "CMake"

            Write-Host ("tool_path={0}" -f $toolPath)
            Write-Host "preferred_execution_mode=host_or_unsandboxed"
            Write-Host "recommended_timeout_ms=1200000"
            Write-Host "execution_hint=For MCUXpresso VS Code real builds, translate presets to explicit cmake configure/build commands and run them directly in the host shell. In sandboxed or agent-run environments, do not execute the build in-place; re-run the emitted host_execution_command on the host."

            $projectDir = $candidate.MarkerDirectory
            $presetFile = Join-Path -Path $projectDir -ChildPath "CMakePresets.json"

            if (Test-Path -LiteralPath $presetFile) {
                $plans = Get-CMakeConfigurePlan -PresetFile $presetFile -ProjectDirectory $projectDir -ExplicitConfig $Config
                $labels = $plans | ForEach-Object { $_.ConfigurePreset }

                $result = Invoke-BuildWithAttempts -AttemptLabels $labels -AttemptBlock {
                    param($label)
                    $plan = $plans | Where-Object { $_.ConfigurePreset -eq $label } | Select-Object -First 1

                    $configureArgs = @("-S", $projectDir, "-B", $plan.BinaryDir)
                    if (-not [string]::IsNullOrWhiteSpace($plan.Generator)) {
                        $configureArgs += @("-G", $plan.Generator)
                    }
                    if (-not [string]::IsNullOrWhiteSpace($plan.ToolchainFile) -and -not $plan.CacheVariables.Contains("CMAKE_TOOLCHAIN_FILE")) {
                        $configureArgs += ("-DCMAKE_TOOLCHAIN_FILE={0}" -f $plan.ToolchainFile)
                    }
                    foreach ($key in $plan.CacheVariables.Keys) {
                        $configureArgs += ("-D{0}={1}" -f $key, (Convert-ToCMakeString -Value $plan.CacheVariables[$key]))
                    }

                    $buildArgs = @("--build", $plan.BinaryDir)
                    if (-not [string]::IsNullOrWhiteSpace($Config)) {
                        $buildArgs += @("--config", $Config)
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($plan.Config)) {
                        $buildArgs += @("--config", $plan.Config)
                    }

                    $hostCommand = Format-PowerShellCommandSequence -EnvironmentOverrides $plan.Environment -Commands @([PSCustomObject]@{ Exe = $toolPath; Args = $configureArgs }, [PSCustomObject]@{ Exe = $toolPath; Args = $buildArgs })
                    Write-Host ("host_execution_command={0}" -f $hostCommand)

                    if (((Test-IsLikelySandboxedUserProfile) -or (Test-IsLikelyCodexAgentEnvironment)) -and -not $DryRun) {
                        Write-Host "sandbox_execution_refused=true"
                        throw "Refusing to run MCUXpresso VS Code real builds inside the sandboxed/agent harness. Re-run the emitted host_execution_command on the host."
                    }

                    $configureCode = Invoke-CommandOrDryRun -Exe $toolPath -Args $configureArgs -DryRunMode:$DryRun -EnvironmentOverrides $plan.Environment
                    if ($configureCode -ne 0) {
                        return $configureCode
                    }

                    return Invoke-CommandOrDryRun -Exe $toolPath -Args $buildArgs -DryRunMode:$DryRun -EnvironmentOverrides $plan.Environment
                }

                if ($result -ne 0) {
                    throw ("MCUXpresso VS Code (translated configure/build mode) build failed. Last exit code: {0}" -f $result)
                }
            }
            else {
                $attempts = Get-ConfigAttempts -ExplicitConfig $Config -Available @()

                $result = Invoke-BuildWithAttempts -AttemptLabels $attempts -AttemptBlock {
                    param($label)

                    $buildDir = Join-Path -Path $projectDir -ChildPath ("build\{0}" -f $label)
                    $configureArgs = @("-S", $projectDir, "-B", $buildDir, ("-DCMAKE_BUILD_TYPE={0}" -f $label))
                    $buildArgs = @("--build", $buildDir, "--config", $label)
                    $hostCommand = Format-PowerShellCommandSequence -EnvironmentOverrides $null -Commands @([PSCustomObject]@{ Exe = $toolPath; Args = $configureArgs }, [PSCustomObject]@{ Exe = $toolPath; Args = $buildArgs })
                    Write-Host ("host_execution_command={0}" -f $hostCommand)

                    if (((Test-IsLikelySandboxedUserProfile) -or (Test-IsLikelyCodexAgentEnvironment)) -and -not $DryRun) {
                        Write-Host "sandbox_execution_refused=true"
                        throw "Refusing to run MCUXpresso VS Code real builds inside the sandboxed/agent harness. Re-run the emitted host_execution_command on the host."
                    }

                    $configureCode = Invoke-CommandOrDryRun -Exe $toolPath -Args $configureArgs -DryRunMode:$DryRun
                    if ($configureCode -ne 0) {
                        return $configureCode
                    }

                    return Invoke-CommandOrDryRun -Exe $toolPath -Args $buildArgs -DryRunMode:$DryRun
                }

                if ($result -ne 0) {
                    throw ("MCUXpresso VS Code (cmake -S/-B mode) build failed. Last exit code: {0}" -f $result)
                }
            }
        }
        default {
            throw ("Unsupported project type: {0}" -f $candidate.Type)
        }
    }

    Write-Host "build_status=success"
    exit 0
}
catch {
    Write-Error $_
    Write-Host "build_status=failed"
    exit 1
}













