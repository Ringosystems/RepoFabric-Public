function Get-RfInstallerMetadata {
    <#
    .SYNOPSIS
        Inspects an installer binary and returns heuristic metadata used to
        pre-fill the custom-publish wizard. Mirrors the heuristics from the
        microsoft/winget-create CLI and the YamlCreate.ps1 community tool,
        adapted for a Linux container (no MSIs are executed; we parse the
        PE header / MSI database / Appx XML directly from bytes).

    .DESCRIPTION
        Detected fields fall into two buckets:

        a) Always available from any binary:
             - Sha256, SizeBytes
             - InstallerType (from extension + magic bytes)
             - Architecture  (from PE MachineType, MSI Template, Appx Identity)
             - DefaultSwitches (Silent / SilentWithProgress / Log / InstallLocation)
             - DefaultInstallModes
             - DefaultExpectedReturnCodes (rich for msi/wix/burn/inno/msix)
             - DefaultScope (from filename keyword)

        b) MSI-only (require msiinfo on PATH):
             - ProductCode, UpgradeCode, ProductVersion, PackageLocale,
               Publisher (Manufacturer), PackageName (ProductName)
             - The above auto-fill AppsAndFeaturesEntries[0]

        c) Appx/Msix-only (parse AppxManifest.xml inside the zip):
             - PackageFamilyName, ProductVersion, PackageLocale,
               PackageName (DisplayName), Publisher

        Authoritative sources for the lookup tables:
          https://github.com/microsoft/winget-cli .../ManifestCommon.cpp
          https://github.com/microsoft/winget-create .../PackageParser.cs
          https://github.com/microsoft/winget-pkgs .../YamlCreate.ps1
        All MIT-licensed; lookup tables transliterated verbatim.

    .PARAMETER Path
        Absolute filesystem path to the staged installer (typically under
        /var/lib/repofabric/staging/uploads/<uuid>/<filename>).

    .PARAMETER OriginalName
        The browser-supplied filename. Used for extension + heuristic
        regex matching when $Path is a UUID-suffixed staging copy.

    .OUTPUTS
        PSCustomObject with all of the above. Missing values are $null,
        empty arrays, or empty hashtables so the consumer can dot into
        any field without null-guards.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$OriginalName
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Installer file not found: $Path" }

    $fileInfo = Get-Item -LiteralPath $Path
    $sizeBytes = [int64]$fileInfo.Length
    $useName = if ($OriginalName) { $OriginalName } else { $fileInfo.Name }
    $ext = ([System.IO.Path]::GetExtension($useName)).TrimStart('.').ToLowerInvariant()

    # ---------- SHA-256 (always) -----------------------------------------
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()

    # ---------- InstallerType detection ----------------------------------
    # Order: extension first (covers the easy 80%); refine via magic bytes
    # for the .exe and .msi edge cases where the extension alone isn't enough
    # (Inno vs Nullsoft vs plain-exe; MSI vs WiX-authored MSI; Burn).
    $installerType = $null
    switch ($ext) {
        'msix'        { $installerType = 'msix' }
        'msixbundle'  { $installerType = 'msix' }
        'appx'        { $installerType = 'appx' }
        'appxbundle'  { $installerType = 'appx' }
        'zip'         { $installerType = 'zip' }
        'msi'         { $installerType = 'msi' }   # may be refined to 'wix' below
        'exe'         { $installerType = 'exe' }   # may be refined to inno/nullsoft/burn below
        default       { $installerType = if ($ext) { $ext } else { 'exe' } }
    }

    # MSI subtype: scan the first 256KB for the literal "wix" / "windows
    # installer xml" (case-insensitive). WiX-authored MSIs always carry one
    # of those strings in the CreatingApp summary property AND in the
    # binary stream. False positives are rare in practice.
    if ($installerType -eq 'msi') {
        try {
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                $buf = New-Object byte[] ([Math]::Min(262144, $sizeBytes))
                $null = $fs.Read($buf, 0, $buf.Length)
                $text = [System.Text.Encoding]::ASCII.GetString($buf)
                if ($text -match '(?i)windows installer xml|\bWix\b') {
                    $installerType = 'wix'
                }
            } finally { $fs.Close() }
        } catch { }
    }

    # EXE subtype: check for Burn (.wixburn section), Inno Setup magic, or
    # NSIS firstheader signature. Fall back to plain 'exe'.
    if ($installerType -eq 'exe') {
        try {
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                $scanLen = [Math]::Min(1048576, $sizeBytes)
                $buf = New-Object byte[] $scanLen
                $null = $fs.Read($buf, 0, $scanLen)
                $text = [System.Text.Encoding]::ASCII.GetString($buf)
                if ($text -match '\.wixburn') {
                    $installerType = 'burn'
                } elseif ($text -match 'Inno Setup Setup Data') {
                    $installerType = 'inno'
                } elseif ($text -match 'Nullsoft\.NSIS\.exehead' -or $text -match 'Nullsoft Install System') {
                    $installerType = 'nullsoft'
                }
            } finally { $fs.Close() }
        } catch { }
    }

    # ---------- Architecture detection -----------------------------------
    $architecture = $null
    if ($installerType -in @('exe','msi','wix','burn','inno','nullsoft')) {
        $architecture = _Get-PEArchitecture -Path $Path
    } elseif ($installerType -in @('msix','appx')) {
        $appxMeta = _Read-AppxIdentity -Path $Path
        if ($appxMeta) { $architecture = [string]$appxMeta.Architecture }
    }
    # Fallback: regex on the filename. Works as a tiebreaker even when the
    # PE header is unreadable.
    if (-not $architecture) {
        $nameLower = $useName.ToLowerInvariant()
        if ($nameLower -match '\b(arm|aarch)64\b')                { $architecture = 'arm64' }
        elseif ($nameLower -match '\barm\b')                      { $architecture = 'arm' }
        elseif ($nameLower -match '\b(x|win)?64\b')               { $architecture = 'x64' }
        elseif ($nameLower -match '\b((win|ia)32|(x?86))\b')      { $architecture = 'x86' }
    }

    # ---------- Default switches (lookup table from winget-cli) ----------
    $switches = _Get-DefaultSwitches -InstallerType $installerType

    # ---------- Default install modes ------------------------------------
    $installModes = _Get-DefaultInstallModes -InstallerType $installerType

    # ---------- Default expected return codes ----------------------------
    $expectedReturnCodes = _Get-DefaultExpectedReturnCodes -InstallerType $installerType

    # ---------- Scope hint from filename keywords ------------------------
    $scope = $null
    $nameLower = $useName.ToLowerInvariant()
    if     ($nameLower -match '\b(per-user|user)\b')           { $scope = 'user' }
    elseif ($nameLower -match '\b(per-machine|machine|system|allusers)\b') { $scope = 'machine' }

    # ---------- MSI metadata (msiinfo) -----------------------------------
    $msiMeta = $null
    if ($installerType -in @('msi','wix') -and (Get-Command msiinfo -ErrorAction SilentlyContinue)) {
        $msiMeta = _Read-MSIProperties -Path $Path
    }

    # ---------- Appx/MSIX identity ---------------------------------------
    $appxIdentity = $null
    if ($installerType -in @('msix','appx')) {
        $appxIdentity = _Read-AppxIdentity -Path $Path
    }

    # ---------- EXE version resource (FileDescription / Comments) --------
    # MSIs carry Subject + Comments in the Summary Information stream;
    # for plain exe / inno / nullsoft / burn the equivalent lives in the
    # PE VS_VERSIONINFO resource. exiftool reads it without executing
    # the binary. Adds the same wizard auto-fill (Subject -> identifier
    # remainder, Comments -> ShortDescription) for EXE installers.
    $exeVersion = $null
    if ($installerType -in @('exe','inno','nullsoft','burn') -and (Get-Command exiftool -ErrorAction SilentlyContinue)) {
        $exeVersion = _Read-ExeVersionInfo -Path $Path
    }

    # Upstream-hash collision: run synchronously so the wizard knows
    # before Publish whether the same binary already exists in the
    # public WinGet repo. Best-effort; if the grep errors (no upstream
    # clone yet, etc.) we return an empty array and the weekly cron
    # job Update-RfCustomPackageCollisions will fill it in later.
    # Defensive @() wrap because the function emits arrays naturally
    # (no comma trick). @() collapses scalar / null / multi-emit into a
    # uniform array shape for the JSON serializer + the client renderer.
    $upstreamMatches = @()
    try { $upstreamMatches = @(Find-RfUpstreamHashMatches -Sha256 $sha) } catch { }

    return [PSCustomObject]@{
        FileName                  = $useName
        SizeBytes                 = $sizeBytes
        Sha256                    = $sha
        InstallerType             = $installerType
        Architecture              = $architecture
        Scope                     = $scope
        DefaultSwitches           = $switches
        DefaultInstallModes       = $installModes
        DefaultExpectedReturnCodes = $expectedReturnCodes
        MsiMetadata               = $msiMeta
        AppxIdentity              = $appxIdentity
        ExeVersionInfo            = $exeVersion
        # @(...) forces array context so ConvertTo-Json emits [] / [{...}]
        # rather than null / {...}. The Find-* helper already returns with
        # the comma operator; this is the second line of defence so a
        # caller that drops the wrapper still gets a JSON array.
        KnownUpstreamMatches      = @($upstreamMatches)
    }
}

function Find-RfUpstreamHashMatches {
    <#
    .SYNOPSIS
        Greps the upstream sparse-checkout for manifests whose
        InstallerSha256 equals a given SHA-256. Returns an array of
        @{ PackageId; Version; ManifestPath } records or an empty array.
    .DESCRIPTION
        Called by the weekly cron job Update-RfCustomPackageCollisions
        to detect when an operator's custom-published binary also exists
        in the public WinGet repo (which usually means a managed
        subscription would be the better choice).
        Bounded execution: the upstream tree has ~140k manifest files
        but only a handful will contain any specific hash, so grep
        returns sub-second on the SSD cache.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Sha256)
    if (-not $Sha256) { return @() }
    $upstreamRoot = if ($env:REPOFABRIC_MANIFEST_CACHE_DIR) { $env:REPOFABRIC_MANIFEST_CACHE_DIR } else { '/var/cache/repofabric/manifests' }
    $sparseRoot   = '/var/lib/repofabric/cache/winget-pkgs/winget-pkgs/manifests'
    $root = if (Test-Path -LiteralPath $sparseRoot) { $sparseRoot } elseif (Test-Path -LiteralPath $upstreamRoot) { $upstreamRoot } else { return @() }

    # Case-insensitive grep on the literal sha. Hex is single-case anyway
    # but YAMLs in older manifests sometimes carry uppercase.
    # Named "$results" (not "$matches") to avoid shadowing PowerShell's
    # automatic regex match variable.
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $files = & grep -rilE "InstallerSha256:\s+$Sha256" $root 2>$null
        if (-not $files) { return @() }
        foreach ($f in @($files)) {
            # Path shape: <root>/<letter>/<Publisher>/<Package>/<Version>/<file>
            $rel = $f.Substring($root.Length).TrimStart('/','\')
            $parts = $rel -split '[\\/]'
            if ($parts.Count -lt 3) { continue }
            $version  = $parts[-2]
            $packageId = ($parts[1..($parts.Count - 3)] -join '.')
            $null = $results.Add(@{
                PackageId    = $packageId
                Version      = $version
                ManifestPath = $rel
            })
        }
    } catch { }
    # Return the array directly. Consumers MUST force-array context with
    # @(Find-RfUpstreamHashMatches ...) before iterating or storing.
    # Earlier versions used `return ,@(...)` here so a one-element result
    # would not get pipeline-unwrapped to a scalar, but the comma trick
    # ended up double-wrapping the array when the caller assigned it to
    # a variable (the wrap was preserved across the function boundary),
    # which is how the stored upstream_match_json column ended up as
    # [[{...}]] instead of [{...}]. The contract now: producers emit
    # arrays naturally; consumers wrap defensively.
    return $results.ToArray()
}

function _Get-DefaultSwitches {
    param([string]$InstallerType)
    # Transliterated from microsoft/winget-cli GetDefaultKnownSwitches
    # (MIT). Tokens <LOGPATH> and <INSTALLPATH> are placeholders winget
    # substitutes at install time.
    switch ($InstallerType) {
        { $_ -in @('msi','wix','burn') } {
            return [ordered]@{
                Silent             = '/quiet /norestart'
                SilentWithProgress = '/passive /norestart'
                Log                = '/log "<LOGPATH>"'
                InstallLocation    = 'TARGETDIR="<INSTALLPATH>"'
            }
        }
        'nullsoft' {
            return [ordered]@{
                Silent             = '/S'
                SilentWithProgress = '/S'
                InstallLocation    = '/D=<INSTALLPATH>'
            }
        }
        'inno' {
            return [ordered]@{
                Silent             = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
                SilentWithProgress = '/SP- /SILENT /SUPPRESSMSGBOXES /NORESTART'
                Log                = '/LOG="<LOGPATH>"'
                InstallLocation    = '/DIR="<INSTALLPATH>"'
            }
        }
        default {
            # exe, portable, zip, msix, appx, pwa, font: no canonical
            # defaults. Operator must supply Silent for raw exe; the
            # other types are inherently silent.
            return [ordered]@{}
        }
    }
}

function _Get-DefaultInstallModes {
    param([string]$InstallerType)
    switch ($InstallerType) {
        { $_ -in @('msi','wix','burn','inno') } { return @('interactive','silent','silentWithProgress') }
        'nullsoft'                              { return @('interactive','silent') }
        { $_ -in @('msix','appx','portable','zip','pwa') } { return @('silent') }
        default                                 { return @() }  # operator supplies for plain exe
    }
}

function _Get-DefaultExpectedReturnCodes {
    param([string]$InstallerType)
    # Pure-data subset (the common cases) from winget-cli
    # GetDefaultKnownReturnCodes. Schema docs codes that map to OUTCOMES
    # other than implicit success (0 / 1641 / 3010 are implicit success
    # in winget and are NOT listed).
    switch ($InstallerType) {
        { $_ -in @('msi','wix','burn') } {
            return @(
                @{ InstallerReturnCode = 1605; ReturnResponse = 'installInProgress' }
                @{ InstallerReturnCode = 1618; ReturnResponse = 'installInProgress' }
                @{ InstallerReturnCode = 1623; ReturnResponse = 'systemNotSupported' }
                @{ InstallerReturnCode = 1633; ReturnResponse = 'systemNotSupported' }
                @{ InstallerReturnCode = 1602; ReturnResponse = 'cancelledByUser' }
                @{ InstallerReturnCode = 1638; ReturnResponse = 'alreadyInstalled' }
                @{ InstallerReturnCode = 1625; ReturnResponse = 'blockedByPolicy' }
                @{ InstallerReturnCode = 1643; ReturnResponse = 'blockedByPolicy' }
                @{ InstallerReturnCode =  112; ReturnResponse = 'diskFull' }
                @{ InstallerReturnCode = 1601; ReturnResponse = 'contactSupport' }
                @{ InstallerReturnCode = 1620; ReturnResponse = 'invalidParameter' }
                @{ InstallerReturnCode = 1639; ReturnResponse = 'invalidParameter' }
            )
        }
        'inno' {
            return @(
                @{ InstallerReturnCode = 2; ReturnResponse = 'cancelledByUser' }
                @{ InstallerReturnCode = 5; ReturnResponse = 'cancelledByUser' }
                @{ InstallerReturnCode = 8; ReturnResponse = 'rebootRequiredForInstall' }
            )
        }
        default { return @() }
    }
}

function _Get-PEArchitecture {
    [OutputType([string])]
    param([string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            # MZ header
            if ($br.ReadUInt16() -ne 0x5A4D) { return $null }
            $fs.Position = 0x3C
            $peOffset = $br.ReadInt32()
            if ($peOffset -le 0 -or $peOffset -gt ($fs.Length - 6)) { return $null }
            $fs.Position = $peOffset
            if ($br.ReadUInt32() -ne 0x00004550) { return $null }   # 'PE\0\0'
            $machine = $br.ReadUInt16()
            switch ($machine) {
                0x014C { return 'x86' }
                0x8664 { return 'x64' }
                0x01C0 { return 'arm' }
                0x01C4 { return 'arm' }
                0xAA64 { return 'arm64' }
                default { return $null }
            }
        } finally { $br.Dispose(); $fs.Close() }
    } catch { return $null }
}

function _Read-MSIProperties {
    [OutputType([hashtable])]
    param([string]$Path)
    try {
        # msitools' msiinfo is the Linux equivalent of WiX's Tablet/etc.
        # Exports the Property table as TSV.
        $raw = & msiinfo export $Path Property 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $props = @{}
        # First line is a header ("Property\tValue"); skip.
        foreach ($line in ($raw -split "`n" | Select-Object -Skip 1)) {
            if (-not $line) { continue }
            $kv = $line -split "`t", 2
            if ($kv.Count -lt 2) { continue }
            $props[$kv[0].Trim()] = $kv[1].Trim()
        }
        $lcid = if ($props.ProductLanguage) { [int]$props.ProductLanguage } else { 0 }
        $locale = _Convert-LcidToBcp47 -Lcid $lcid

        # Pull the Summary Information stream too. The "Subject" and
        # "Comments" fields drive PackageIdentifier remainder + the
        # wizard's ShortDescription auto-fill respectively, and live in
        # the summary stream rather than the Property table.
        $sum = _Read-MSISummary -Path $Path

        return @{
            ProductCode    = $props.ProductCode
            UpgradeCode    = $props.UpgradeCode
            ProductVersion = $props.ProductVersion
            ProductName    = $props.ProductName
            Manufacturer   = $props.Manufacturer
            PackageLocale  = $locale
            Lcid           = $lcid
            Subject        = if ($sum) { $sum.Subject }  else { $null }
            Comments       = if ($sum) { $sum.Comments } else { $null }
            Title          = if ($sum) { $sum.Title }    else { $null }
            Author         = if ($sum) { $sum.Author }   else { $null }
        }
    } catch { return $null }
}

function _Read-MSISummary {
    [OutputType([hashtable])]
    param([string]$Path)
    try {
        $raw = & msiinfo suminfo $Path 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $sum = @{}
        foreach ($line in ($raw -split "`n")) {
            if (-not $line) { continue }
            $kv = $line -split ':', 2
            if ($kv.Count -lt 2) { continue }
            # Normalize: "Last Saved By" -> "LastSavedBy" so the keys are
            # stable PowerShell identifiers regardless of msiinfo version.
            $key = ($kv[0] -replace '\s+', '').Trim()
            $sum[$key] = $kv[1].Trim()
        }
        return @{
            Title    = $sum.Title
            Subject  = $sum.Subject
            Author   = $sum.Author
            Comments = $sum.Comments
            Keywords = $sum.Keywords
        }
    } catch { return $null }
}

function _Read-AppxIdentity {
    [OutputType([hashtable])]
    param([string]$Path)
    try {
        # MSIX/Appx are zip archives. Pull AppxManifest.xml directly
        # without unpacking. unzip -p stays portable on debian.
        $unzip = Get-Command unzip -ErrorAction SilentlyContinue
        if (-not $unzip) { return $null }
        $xml = & $unzip.Source -p $Path AppxManifest.xml 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $xml) { return $null }
        $doc = [xml]($xml -join "`n")
        $identity = $doc.Package.Identity
        $props    = $doc.Package.Properties
        $deflt    = $doc.Package.SelectSingleNode("//*[local-name()='Properties']")
        return @{
            Architecture   = [string]$identity.ProcessorArchitecture
            ProductName    = if ($props -and $props.DisplayName) { [string]$props.DisplayName } else { $null }
            Publisher      = if ($props -and $props.PublisherDisplayName) { [string]$props.PublisherDisplayName } else { $null }
            ProductVersion = [string]$identity.Version
            PackageFamilyName = [string]$identity.Name
        }
    } catch { return $null }
}

function _Read-ExeVersionInfo {
    [OutputType([hashtable])]
    param([string]$Path)
    try {
        # exiftool emits one "Tag Name: Value" per line. We pluck the
        # standard VS_VERSIONINFO StringFileInfo entries. Keys are
        # case-sensitive in exiftool output (CompanyName, FileDescription,
        # etc.). The custom-publish wizard uses FileDescription as the
        # closest analog to MSI Summary "Subject" and Comments to fill
        # ShortDescription, matching the operator's screenshot semantics.
        $raw = & exiftool -S -CompanyName -FileDescription -ProductName -FileVersion -ProductVersion -Comments -LegalCopyright $Path 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $info = @{}
        foreach ($line in ($raw -split "`n")) {
            if (-not $line) { continue }
            $kv = $line -split ':', 2
            if ($kv.Count -lt 2) { continue }
            $info[$kv[0].Trim()] = $kv[1].Trim()
        }
        $hasAny = $false
        foreach ($v in $info.Values) { if ($v) { $hasAny = $true; break } }
        if (-not $hasAny) { return $null }
        return @{
            CompanyName     = $info.CompanyName
            FileDescription = $info.FileDescription
            ProductName     = $info.ProductName
            FileVersion     = $info.FileVersion
            ProductVersion  = $info.ProductVersion
            Comments        = $info.Comments
            LegalCopyright  = $info.LegalCopyright
        }
    } catch { return $null }
}

function _Convert-LcidToBcp47 {
    [OutputType([string])]
    param([int]$Lcid)
    if (-not $Lcid) { return $null }
    try {
        return [System.Globalization.CultureInfo]::new($Lcid).Name
    } catch { return $null }
}
