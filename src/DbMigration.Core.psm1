Set-StrictMode -Version Latest

function Import-MigrationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    $configuration = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($requiredProperty in @('SourceTargets', 'OutputPath', 'ThrottleLimit', 'LinkedServersCsv')) {
        if (-not $configuration.Contains($requiredProperty)) {
            throw "Configuration is missing required property '$requiredProperty'."
        }
    }
    if (-not $configuration.SourceTargets -or $configuration.SourceTargets.Count -eq 0) {
        throw 'Configuration must contain at least one source/target pair.'
    }

    foreach ($pair in $configuration.SourceTargets) {
        foreach ($property in @('Source', 'Target', 'BackupPath')) {
            if ([string]::IsNullOrWhiteSpace([string]$pair[$property])) {
                throw "Each SourceTargets entry must define '$property'."
            }
        }
        if (-not $pair.Contains('MigrationMode')) {
            $pair.MigrationMode = 'Full'
        }
        if ([string]$pair.MigrationMode -notin @('Full', 'SchemaOnly')) {
            throw "MigrationMode must be 'Full' or 'SchemaOnly'."
        }
    }
    if ([int]$configuration.ThrottleLimit -lt 1 -or [int]$configuration.ThrottleLimit -gt 128) {
        throw 'ThrottleLimit must be an integer from 1 through 128.'
    }
    if (-not $configuration.Contains('ExcludeDatabases')) {
        $configuration.ExcludeDatabases = @()
    }
    if (-not $configuration.Contains('UpdateStatistics')) {
        $configuration.UpdateStatistics = $true
    }
    if (-not $configuration.Contains('RestoreSpaceBufferPercent')) {
        $configuration.RestoreSpaceBufferPercent = 20
    }
    if ($configuration.RestoreSpaceBufferPercent -isnot [byte] -and
        $configuration.RestoreSpaceBufferPercent -isnot [int] -and
        $configuration.RestoreSpaceBufferPercent -isnot [long] -and
        $configuration.RestoreSpaceBufferPercent -isnot [double] -and
        $configuration.RestoreSpaceBufferPercent -isnot [decimal]) {
        throw 'RestoreSpaceBufferPercent must be a number.'
    }
    if ([double]$configuration.RestoreSpaceBufferPercent -lt 0 -or [double]$configuration.RestoreSpaceBufferPercent -gt 100) {
        throw 'RestoreSpaceBufferPercent must be between 0 and 100.'
    }
    if (-not $configuration.Contains('BackupFileCount')) {
        $configuration.BackupFileCount = 4
    }
    if ($configuration.BackupFileCount -isnot [byte] -and
        $configuration.BackupFileCount -isnot [int] -and
        $configuration.BackupFileCount -isnot [long]) {
        throw 'BackupFileCount must be an integer.'
    }
    if ([int]$configuration.BackupFileCount -lt 1 -or [int]$configuration.BackupFileCount -gt 32) {
        throw 'BackupFileCount must be between 1 and 32.'
    }
    if (-not $configuration.Contains('AllowTargetReplace')) {
        $configuration.AllowTargetReplace = $false
    }
    if ($configuration.AllowTargetReplace -isnot [bool]) {
        throw 'AllowTargetReplace must be true or false.'
    }
    foreach ($property in @('OverwriteExistingDatabases', 'SkipExistingDatabases')) {
        if (-not $configuration.Contains($property)) {
            $configuration[$property] = @()
        }
        $databaseNames = @($configuration[$property])
        if (@($databaseNames | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
            throw "$property must contain only non-empty database names."
        }
        $configuration[$property] = @($databaseNames | ForEach-Object { [string]$_ })
    }
    foreach ($property in @('MigrateLogins', 'MigrateAgentJobs', 'MigrateAgentOperators', 'ConfigureLinkedServers', 'RepairOrphanUsers')) {
        if (-not $configuration.Contains($property)) {
            $configuration[$property] = $true
        }
    }
    foreach ($property in @('OutputPath', 'LinkedServersCsv')) {
        if ([string]::IsNullOrWhiteSpace([string]$configuration[$property])) {
            throw "Configuration property '$property' must not be empty."
        }
    }

    return $configuration
}

function Get-MigrationTargetDatabaseDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][bool] $TargetExists,
        [Parameter()][string] $StateStatus,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration
    )

    if (-not $TargetExists) {
        return 'Migrate'
    }
    if ($Database -in @($Configuration.SkipExistingDatabases)) {
        return 'SkipRequested'
    }
    if ($Configuration.AllowTargetReplace -or $Database -in @($Configuration.OverwriteExistingDatabases)) {
        return 'Overwrite'
    }
    if ($StateStatus -eq 'Completed') {
        return 'SkipCompleted'
    }
    return 'Blocked'
}

function Test-MigrationServerWorkEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Options,
        [Parameter()][ValidateSet('Full', 'SchemaOnly')][string] $MigrationMode = 'Full'
    )

    if ($MigrationMode -eq 'SchemaOnly') {
        return $false
    }

    $configureLinkedServers = $Options.Contains('ConfigureLinkedServers') -and [bool]$Options.ConfigureLinkedServers
    $skipLinkedServers = $Options.Contains('SkipLinkedServers') -and [bool]$Options.SkipLinkedServers
    [bool](
        ($Options.Contains('MigrateLogins') -and [bool]$Options.MigrateLogins) -or
        ($Options.Contains('MigrateAgentJobs') -and [bool]$Options.MigrateAgentJobs) -or
        ($Options.Contains('MigrateAgentOperators') -and [bool]$Options.MigrateAgentOperators) -or
        ($configureLinkedServers -and -not $skipLinkedServers)
    )
}

function Get-MigrationDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SqlInstance,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Configuration
    )

    $excluded = @('master', 'model', 'msdb', 'tempdb') + @($Configuration.ExcludeDatabases)
    $databases = @(Get-DbaDatabase -SqlInstance $SqlInstance -ErrorAction Stop |
        Where-Object { -not $_.IsSystemObject -and $_.Name -notin $excluded })
    if ($Configuration.Contains('IncludeDatabases')) {
        $included = @($Configuration.IncludeDatabases)
        $databases = @($databases | Where-Object Name -In $included)
    }
    $databases
}

function Test-MigrationDatabaseExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SqlInstance,

        [Parameter(Mandatory)]
        [string] $Database
    )

    $matchingDatabases = @(Get-DbaDatabase -SqlInstance $SqlInstance -Database $Database -ErrorAction Stop |
        Where-Object Name -eq $Database)
    if ($matchingDatabases.Count -eq 0) {
        return $false
    }
    if (@($matchingDatabases | Where-Object { $_.Status -eq 'Normal' -and $_.IsAccessible }).Count -eq 0) {
        throw "Database '$Database' exists on '$SqlInstance' but is not online and accessible; refusing to treat it as missing."
    }
    return $true
}

function Get-MigrationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ Version = 1; Databases = @{} }
    }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $state.Contains('Databases')) {
        throw "Migration state file has an invalid format: $Path"
    }
    return $state
}

function Get-MigrationStateKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Database
    )

    $identity = [string]::Join([char]0, @($Source.ToLowerInvariant(), $Target.ToLowerInvariant(), $Database.ToLowerInvariant()))
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
        [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-MigrationBackupPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Database
    )

    $safeName = [regex]::Replace($Database, '[^A-Za-z0-9._-]', '_').TrimEnd([char[]]@('.', ' '))
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = 'database'
    }
    $key = Get-MigrationStateKey -Source $Source -Target $Target -Database $Database
    Join-Path $Directory "$safeName-$($key.Substring(0, 12)).bak"
}

function Get-MigrationRunBackupDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RootDirectory,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][guid] $RunId
    )

    $safeSource = [regex]::Replace($Source, '[^A-Za-z0-9._-]', '_').TrimEnd([char[]]@('.', ' '))
    $safeTarget = [regex]::Replace($Target, '[^A-Za-z0-9._-]', '_').TrimEnd([char[]]@('.', ' '))
    if ([string]::IsNullOrWhiteSpace($safeSource)) { $safeSource = 'source' }
    if ([string]::IsNullOrWhiteSpace($safeTarget)) { $safeTarget = 'target' }
    Join-Path $RootDirectory "migration-$safeSource-to-$safeTarget-$($RunId.ToString('N'))"
}

function Get-MigrationDatabaseBackupDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RunDirectory,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Database
    )

    $key = Get-MigrationStateKey -Source $Source -Target $Target -Database $Database
    Join-Path $RunDirectory "database-$($key.Substring(0, 16))"
}

function Get-MigrationBackupStripeFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][ValidateRange(1, 32)][int] $FileCount
    )

    $backupFiles = @(Get-ChildItem -LiteralPath $Directory -Filter '*.bak' -File -ErrorAction Stop)
    if ($backupFiles.Count -ne $FileCount) {
        return @()
    }

    $escapedDatabase = [regex]::Escape($Database)
    $pattern = "^$escapedDatabase`_.*-(?<Stripe>\d+)-of-$FileCount\.bak$"
    $indexedFiles = @(
        foreach ($file in $backupFiles) {
            $match = [regex]::Match($file.Name, $pattern)
            if ($match.Success) {
                [pscustomobject]@{
                    Stripe = [int]$match.Groups['Stripe'].Value
                    File = $file
                }
            }
        }
    )
    $expectedStripes = @(1..$FileCount)
    $actualStripes = @($indexedFiles | ForEach-Object Stripe | Sort-Object -Unique)
    if ($indexedFiles.Count -ne $FileCount -or
        [string]::Join(',', $actualStripes) -ne [string]::Join(',', $expectedStripes)) {
        return @()
    }

    @($indexedFiles | Sort-Object Stripe | ForEach-Object { $_.File })
}

function Write-MigrationProgressEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProgressPath,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Source,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Target,
        [Parameter()][string] $Database = '',
        [Parameter(Mandatory)][string] $Stage,
        [Parameter(Mandatory)][ValidateSet('Started', 'InProgress', 'Completed', 'Skipped', 'Failed', 'Paused', 'Stopped')][string] $Status,
        [Parameter()][ValidateRange(-1, 100)][int] $PercentComplete = -1,
        [Parameter()][string] $Message = ''
    )

    if ($PercentComplete -lt 0) {
        $PercentComplete = switch ($Status) {
            'Started' { 0 }
            { $_ -in @('Completed', 'Skipped') } { 100 }
            default { -1 }
        }
    }
    $null = New-Item -ItemType Directory -Path $ProgressPath -Force -ErrorAction Stop
    $event = [ordered]@{
        Timestamp = [DateTime]::UtcNow.ToString('o')
        Source = $Source
        Target = $Target
        Database = $Database
        Stage = $Stage
        Status = $Status
        PercentComplete = if ($PercentComplete -ge 0) { $PercentComplete } else { $null }
        Message = $Message
    }
    $suffix = [guid]::NewGuid().ToString('N')
    $baseName = "$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfffffff'))-$suffix"
    $temporaryPath = Join-Path $ProgressPath "$baseName.tmp"
    $eventPath = Join-Path $ProgressPath "$baseName.json"
    try {
        $json = ConvertTo-Json -InputObject $event -Compress
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporaryPath, $eventPath)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
        }
    }
}

function Wait-MigrationControl {
    [CmdletBinding()]
    param(
        [Parameter()][string] $ControlPath = '',
        [Parameter()][string] $ProgressPath = '',
        [Parameter()][string] $Source = '',
        [Parameter()][string] $Target = '',
        [Parameter()][string] $Database = '',
        [Parameter()][switch] $HonorStop
    )

    if (-not $ControlPath) {
        return $true
    }
    $readControl = {
        if (-not (Test-Path -LiteralPath $ControlPath -PathType Leaf)) {
            return 'Run'
        }
        $control = Get-Content -LiteralPath $ControlPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if (-not $control.Contains('Action') -or $control.Action -notin @('Run', 'Pause', 'Resume', 'Stop')) {
            throw "Migration control file has an invalid action: $ControlPath"
        }
        [string]$control.Action
    }

    $action = & $readControl
    if ($action -eq 'Stop' -and $HonorStop) {
        if ($ProgressPath) {
            Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $Source -Target $Target `
                -Database $Database -Stage 'RunControl' -Status 'Stopped' -Message 'Stop requested; no further database work will start.'
        }
        return $false
    }
    if ($action -ne 'Pause') {
        return $true
    }

    if ($ProgressPath) {
        Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $Source -Target $Target `
            -Database $Database -Stage 'RunControl' -Status 'Paused' -Message 'Migration paused at a safe stage boundary.'
    }
    while ($action -eq 'Pause') {
        Start-Sleep -Seconds 1
        $action = & $readControl
    }
    if ($action -eq 'Stop' -and $HonorStop) {
        if ($ProgressPath) {
            Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $Source -Target $Target `
                -Database $Database -Stage 'RunControl' -Status 'Stopped' -Message 'Stop requested while paused; no further database work will start.'
        }
        return $false
    }
    if ($action -eq 'Stop') {
        if ($ProgressPath) {
            Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $Source -Target $Target `
                -Database $Database -Stage 'RunControl' -Status 'InProgress' `
                -Message 'Stop requested; finishing the active database or server-object stage safely.'
        }
        return $true
    }
    if ($ProgressPath) {
        Write-MigrationProgressEvent -ProgressPath $ProgressPath -Source $Source -Target $Target `
            -Database $Database -Stage 'RunControl' -Status 'InProgress' -Message 'Migration resumed.'
    }
    return $true
}

function Remove-MigrationRunBackupDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $RootDirectory,
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Target
    )

    $safeSource = [regex]::Replace($Source, '[^A-Za-z0-9._-]', '_').TrimEnd([char[]]@('.', ' '))
    $safeTarget = [regex]::Replace($Target, '[^A-Za-z0-9._-]', '_').TrimEnd([char[]]@('.', ' '))
    if ([string]::IsNullOrWhiteSpace($safeSource)) { $safeSource = 'source' }
    if ([string]::IsNullOrWhiteSpace($safeTarget)) { $safeTarget = 'target' }

    $root = [System.IO.Path]::GetFullPath($RootDirectory).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath($Directory)
    $candidateParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $candidate)).TrimEnd('\')
    $expectedPrefix = "migration-$safeSource-to-$safeTarget-"
    $leaf = Split-Path -Leaf $candidate
    if ($candidateParent -ne $root -or
        -not $leaf.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^migration-.+-to-.+-[a-f0-9]{32}$') {
        throw "Refusing to remove backup path outside the expected per-run folder: $Directory"
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        return $false
    }
    if ($PSCmdlet.ShouldProcess($candidate, 'Delete completed migration backup folder')) {
        Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction Stop
        return $true
    }
    return $false
}

function Set-MigrationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][ValidateSet('BackupCompleted', 'Completed', 'Failed')][string] $Status,
        [string] $BackupPath,
        [string] $ErrorMessage
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $lockPath = "$Path.lock"
    $lock = $null
    for ($attempt = 0; $attempt -lt 100 -and -not $lock; $attempt++) {
        try {
            $lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $lock) {
        throw "Could not acquire migration state lock: $lockPath"
    }

    try {
        $state = Get-MigrationState -Path $Path
        $key = Get-MigrationStateKey -Source $Source -Target $Target -Database $Database
        $state.Databases[$key] = @{
            Source = $Source
            Target = $Target
            Database = $Database
            Status = $Status
            BackupPath = $BackupPath
            Error = $ErrorMessage
            UpdatedAt = [DateTime]::UtcNow.ToString('o')
        }
        $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            $json = ConvertTo-Json -InputObject $state -Depth 10
            [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
            $null = Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
    }
    finally {
        $lock.Dispose()
    }
}

function Write-MigrationReports {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows,
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][string] $Name
    )

    $null = New-Item -ItemType Directory -Path $OutputPath -Force
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $runSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $baseName = "$Name-$timestamp-$runSuffix"
    $csvPath = Join-Path $OutputPath "$baseName.csv"
    $htmlPath = Join-Path $OutputPath "$baseName.html"
    if ($Rows.Count -gt 0) {
        $Rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
        $html = $Rows | ConvertTo-Html -Title "$Name report" -PreContent "<h1>$Name report</h1><p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>" | Out-String
    }
    else {
        @('"Message"', '"No records"') | Set-Content -LiteralPath $csvPath -Encoding utf8
        $html = "<html><head><title>$Name report</title></head><body><h1>$Name report</h1><p>No records.</p></body></html>"
    }
    Set-Content -LiteralPath $htmlPath -Value $html -Encoding utf8
    [pscustomobject]@{ CsvPath = $csvPath; HtmlPath = $htmlPath }
}

Export-ModuleMember -Function Import-MigrationConfiguration, Get-MigrationTargetDatabaseDecision, Test-MigrationServerWorkEnabled, Get-MigrationDatabase, Test-MigrationDatabaseExists, Get-MigrationState, Get-MigrationStateKey, Get-MigrationBackupPath, Get-MigrationRunBackupDirectory, Get-MigrationDatabaseBackupDirectory, Get-MigrationBackupStripeFiles, Write-MigrationProgressEvent, Wait-MigrationControl, Remove-MigrationRunBackupDirectory, Set-MigrationState, Write-MigrationReports
