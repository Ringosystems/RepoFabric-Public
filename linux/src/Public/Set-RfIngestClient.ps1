function Set-RfIngestClient {
    <#
    .SYNOPSIS
        Edit a registered ingest client's metadata, allow-list, capabilities, or
        active/suspended status. Does NOT touch key material (use
        Reset-RfIngestClientKey) and cannot un-revoke (revocation is terminal).
    .PARAMETER Status
        'active' or 'suspended'. Suspend/reactivate. A suspended client fails
        BOTH auth factors exactly like a revoked one, but suspension is
        reversible whereas revocation is not.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [string]$DisplayName,
        [string]$OwnerContact,
        [string[]]$AllowedRepos,
        [ValidateSet('package:write')]
        [string[]]$Capabilities,
        [ValidateSet('active','suspended')][string]$Status,
        [string]$Actor
    )
    $ClientId = $ClientId.ToLowerInvariant()
    $db = Open-RfStateDatabase
    $current = Get-RfIngestClientById -ClientId $ClientId -DataSource $db
    if (-not $current) { throw "Ingest client '$ClientId' not found." }
    if ($current.Status -eq 'revoked') {
        throw "Ingest client '$ClientId' is revoked; revocation is terminal. Register a new client instead."
    }

    $sets   = @()
    $params = @{ cid = $ClientId }
    if ($PSBoundParameters.ContainsKey('DisplayName'))  { $sets += 'display_name = @display_name'; $params.display_name = $DisplayName }
    if ($PSBoundParameters.ContainsKey('OwnerContact')) { $sets += 'owner_contact = @owner';        $params.owner = if ($OwnerContact) { $OwnerContact } else { [DBNull]::Value } }
    if ($PSBoundParameters.ContainsKey('Status'))       { $sets += 'status = @status';              $params.status = $Status }
    if ($PSBoundParameters.ContainsKey('Capabilities')) { $sets += 'capabilities_json = @caps';     $params.caps = (ConvertTo-Json -InputObject ([string[]]@($Capabilities)) -Compress) }
    if ($PSBoundParameters.ContainsKey('AllowedRepos')) {
        foreach ($r in @($AllowedRepos)) {
            $slug = ([string]$r).ToLowerInvariant()
            if (-not (Get-RfVirtualRepo -RepoId $slug -DataSource $db -ErrorAction SilentlyContinue)) {
                throw "Allowed repo '$slug' does not exist."
            }
        }
        $sets += 'allowed_repos_json = @repos'
        # [string[]] cast, no -AsArray (see New-RfIngestClient): keep the JSON a flat array.
        $params.repos = (ConvertTo-Json -InputObject ([string[]]@($AllowedRepos | ForEach-Object { ([string]$_).ToLowerInvariant() })) -Compress)
    }
    if ($sets.Count -eq 0) { throw 'Nothing to update: supply at least one of -DisplayName/-OwnerContact/-AllowedRepos/-Capabilities/-Status.' }

    if (-not $PSCmdlet.ShouldProcess("ingest client '$ClientId'", "Update ($($sets.Count) field(s))")) { return }

    $who = if ($Actor) { $Actor } else { Get-RfCurrentIdentity }
    $sql = "UPDATE ingest_client SET $($sets -join ', ') WHERE client_id = @cid"
    Invoke-RfSqliteQuery -DataSource $db -Query $sql -SqlParameters $params | Out-Null

    $eventType = if ($PSBoundParameters.ContainsKey('Status')) {
        if ($Status -eq 'suspended') { 'ingest_client_suspended' } else { 'ingest_client_reactivated' }
    } else { 'ingest_client_updated' }
    Write-RfAdminEvent -EventType $eventType -Subject $ClientId -Actor $who -Data @{
        fields = @($sets | ForEach-Object { ($_ -split ' = ')[0] })
        status = if ($PSBoundParameters.ContainsKey('Status')) { $Status } else { $current.Status }
    }

    return (Get-RfIngestClientById -ClientId $ClientId -DataSource $db)
}
