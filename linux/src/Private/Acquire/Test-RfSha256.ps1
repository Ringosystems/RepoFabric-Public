function Test-RfSha256 {
    <#
    .SYNOPSIS
        Computes SHA-256 of a file and compares against an expected hex string.

    .OUTPUTS
        PSCustomObject with: Actual, Expected, Match (bool), SizeBytes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Expected
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
    $expectedLower = $Expected.ToLower().Trim()
    [PSCustomObject]@{
        Actual    = $hash
        Expected  = $expectedLower
        Match     = ($hash -eq $expectedLower)
        SizeBytes = (Get-Item -LiteralPath $Path).Length
    }
}
