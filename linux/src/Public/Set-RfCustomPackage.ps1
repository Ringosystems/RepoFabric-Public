function Set-RfCustomPackage {
    <#
    .SYNOPSIS
        Updates the operator-editable fields on a custom_packages row.
    .DESCRIPTION
        Currently scoped to Notes only. Everything else on a custom
        package (package_id, name, publisher, version, manifest_json)
        is derived from the published manifest and must stay in sync
        with what is in Gitea. Edits to those fields would create
        client/server drift and break the "republish to update"
        invariant, so they go through Publish-RfCustomPackage instead.

        Passing $null for Notes clears the existing note. Passing an
        empty string also clears it. Anything else replaces it.
    .PARAMETER CustomId
        custom_packages.custom_id of the row to update.
    .PARAMETER Notes
        New notes value. $null and "" both clear the column.
    .OUTPUTS
        PSCustomObject of the updated row (same shape as Get-RfCustomPackage).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][int]$CustomId,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Notes
    )

    $db = Open-RfStateDatabase
    $row = Invoke-RfSqliteQuery -DataSource $db -Query 'SELECT custom_id, package_id FROM custom_packages WHERE custom_id=@cid' -SqlParameters @{ cid = $CustomId }
    if (-not $row) { throw "Custom package #$CustomId not found." }
    if (-not $PSCmdlet.ShouldProcess("custom_packages #$CustomId ($($row.package_id))", 'Update notes')) { return }

    $now = Get-RfTimestamp
    $identity = Get-RfCurrentIdentity
    $notesValue = if ([string]::IsNullOrEmpty($Notes)) { [DBNull]::Value } else { $Notes }
    Invoke-RfSqliteQuery -DataSource $db -Query @'
UPDATE custom_packages
   SET notes        = @notes,
       modified_by  = @actor,
       modified_at  = @now
 WHERE custom_id    = @cid;
'@ -SqlParameters @{
        cid   = $CustomId
        notes = $notesValue
        actor = $identity
        now   = $now
    } | Out-Null

    Write-RfLog -Level Information -Event 'custom_updated' -Message "Custom package notes updated" -Data @{
        custom_id  = $CustomId
        package_id = [string]$row.package_id
        actor      = $identity
    }

    Write-RfAdminEvent -EventType 'custom_updated' -Subject ([string]$row.package_id) -Actor $identity -Data @{
        custom_id = $CustomId
        field     = 'notes'
    }

    return Get-RfCustomPackage -CustomId $CustomId -DataSource $db
}
