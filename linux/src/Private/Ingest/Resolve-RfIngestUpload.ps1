function Resolve-RfIngestUpload {
    <#
    .SYNOPSIS
        Resolve a client-supplied uploadId (from POST /api/v1/ingest/binaries)
        to the staged file on disk and HASH-BIND it: assert the staged file's
        SHA-256 equals the sha256 the client declared in the signed publish
        request. This is what lets a multi-GB binary be trusted via a small
        signed request without signing the whole blob.
    .DESCRIPTION
        The Node uploader stages to <stateDir>/staging/uploads/<uuid>/<file> and
        returns only the uuid to the client; the server path is never exposed.
        This reconstructs that path from the uuid, finds the single staged file,
        verifies its hash, and returns the {LocalPath, OriginalName, Sha256,
        SizeBytes, InstallerIndex} shape Format-RfCustomManifest consumes.
    .OUTPUTS
        Hashtable in the InstallerUploads shape. Throws on unknown id or hash
        mismatch (the route maps a mismatch to HTTP 409).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$UploadId,
        [Parameter(Mandatory)][string]$DeclaredSha256,
        [int]$InstallerIndex = 0,
        [string]$OriginalName
    )
    if ($UploadId -notmatch '^[0-9a-fA-F-]{36}$') { throw "Invalid uploadId '$UploadId'." }

    $stateRoot = if ($env:REPOFABRIC_STATE_DIR) { $env:REPOFABRIC_STATE_DIR } else { '/var/lib/repofabric' }
    $dir = Join-Path $stateRoot 'staging' | Join-Path -ChildPath 'uploads' | Join-Path -ChildPath $UploadId
    if (-not (Test-Path -LiteralPath $dir)) { throw "Unknown or expired uploadId '$UploadId'." }

    $file = Get-ChildItem -LiteralPath $dir -File | Select-Object -First 1
    if (-not $file) { throw "Staging dir for uploadId '$UploadId' is empty." }

    $check = Test-RfSha256 -Path $file.FullName -Expected $DeclaredSha256
    if (-not $check.Match) {
        throw "StagedHashMismatch: uploadId '$UploadId' staged content is $($check.Actual) but the signed request declared $($check.Expected)."
    }

    return @{
        LocalPath      = $file.FullName
        OriginalName   = if ($OriginalName) { $OriginalName } else { $file.Name }
        Sha256         = $check.Actual
        SizeBytes      = $check.SizeBytes
        InstallerIndex = $InstallerIndex
    }
}
