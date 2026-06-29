function Get-RfTimestamp {
    <#
    .SYNOPSIS
        Returns a UTC ISO-8601 timestamp with 'Z' suffix.

    .DESCRIPTION
        All persisted timestamps in state.sqlite and YAML audit fields use this
        format. Centralizing the formatting prevents drift across callers
        (e.g. one caller using local time, another UTC).

    .OUTPUTS
        [string]

    .EXAMPLE
        Get-RfTimestamp
        # 2026-05-22T03:42:11Z
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}
