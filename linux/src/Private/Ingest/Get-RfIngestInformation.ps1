# Assemble the RFIP discovery payload (GET /api/v1/ingest/information). This is
# the runtime source of truth a consumer negotiates against: supported protocol
# versions, the manifest schema RepoFabric validates, the WinGet source-API
# versions the RUNNING rewinged accepts (live-probed), upload limits, the
# caller's effective repo allow-list, and the auth contract.

# The single manifest schema version RepoFabric validates + writes. Kept in
# lockstep with Format-RfCustomManifest's default and the vendored schemas.
$script:RfIngestManifestSchemaVersion = '1.6.0'
$script:RfIngestProtocolVersions      = @('1.0')

function Get-RfIngestInformation {
    <#
    .SYNOPSIS
        Build the discovery object for a given ingest client.
    .PARAMETER Client
        The normalised ingest client object (for the effective allow-list).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]$Client,
        [hashtable]$Configuration,
        [string]$DataSource
    )
    if (-not $Configuration) { try { $Configuration = Get-RfConfiguration } catch { $Configuration = @{} } }
    if (-not $DataSource)    { $DataSource = Open-RfStateDatabase }

    $maxUpload = if ($env:REPOFABRIC_UPLOAD_MAX_BYTES) { [int64]$env:REPOFABRIC_UPLOAD_MAX_BYTES } else { 2147483648 }
    $sourceApi = Get-RfRewingedInformation -Configuration $Configuration

    return [PSCustomObject]@{
        protocol              = 'repofabric-ingest'
        supportedVersions     = @($script:RfIngestProtocolVersions)
        transportPath         = '/api/v1/ingest'
        manifestSchemaVersion = $script:RfIngestManifestSchemaVersion
        sourceApi             = [PSCustomObject]@{
            sourceIdentifier        = $sourceApi.SourceIdentifier
            serverSupportedVersions = @($sourceApi.ServerSupportedVersions)
            reachable               = [bool]$sourceApi.Reachable
            probedAt                = $sourceApi.ProbedAt
        }
        maxUploadBytes        = $maxUpload
        binaryModes           = @('local','upstream')
        allowedRepos          = @(Get-RfIngestAllowedRepos -Client $Client -DataSource $DataSource)
        auth                  = [PSCustomObject]@{
            bearer            = 'package:write'
            signature         = 'rfc9421-ecdsa-p256-sha256'
            coveredComponents = @('@method','@target-uri','content-digest','@authority')
            signatureRequired = $true
        }
        openapi               = '/api/v1/ingest/openapi.json'
    }
}
