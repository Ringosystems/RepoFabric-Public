function ConvertTo-RfVersionSortKey {
    <#
    .SYNOPSIS
        Builds a lexically-sortable form of a winget version string so
        SQL ORDER BY collates 150.x above 99.x as a natural-sort would.

    .DESCRIPTION
        winget version strings are mostly dot-separated numeric (1.2.3.4)
        but not always: prerelease tags ('2.0-rc1'), letter suffixes
        ('3.5a'), and entirely non-numeric forms appear in upstream
        manifests. The output key normalises every dot-separated segment
        to its leading numeric portion, left-padded with zeros to ten
        characters. Lexical comparison on the resulting string yields
        the natural-sort ordering.

        Examples:
            '150.0.7558.62'  -> '0000000150.0000000000.0000007558.0000000062'
            '99.0.1'         -> '0000000099.0000000000.0000000001'
            '2.0-rc1'        -> '0000000002.0000000000'  (rc1 segment -> '0')
            '3.5a'           -> '0000000003.0000000005'  (5a stem -> '5')
            ''               -> ''

        Ten characters cover any realistic semver segment (max int32 is
        10 digits) without ballooning the column size. Non-parseable
        leading segments fall back to '0', which sorts to the bottom of
        the natural-sort axis without throwing.

    .PARAMETER Version
        The raw version string from upstream_index.version.

    .OUTPUTS
        [string]. Empty string when -Version is null / whitespace.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) { return '' }

    $segments = $Version -split '\.'
    $padded = foreach ($seg in $segments) {
        $leadingDigits = if ($seg -match '^(\d+)') { $matches[1] } else { '0' }
        $leadingDigits.PadLeft(10, '0')
    }
    return ($padded -join '.')
}
