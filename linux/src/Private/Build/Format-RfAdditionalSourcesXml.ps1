function Format-RfAdditionalSourcesXml {
    <#
    .SYNOPSIS
        Renders the <Sources>...</Sources> XML payload that the DesktopAppInstaller
        CSP policies EnableAdditionalSources and EnableAllowedSources accept.

    .DESCRIPTION
        The exact shape is the same as `winget source export` output on a
        Windows endpoint. The Intune Settings Catalog setting for either of
        the two source-related policies is a "simple string" instance whose
        value is the literal XML body returned here.

        We deliberately set TrustLevel=Trusted so silent installs from this
        source do not generate a prompt on managed endpoints.

    .PARAMETER Name
        Source name as it appears in `winget source list`. Default 'repofabric'.

    .PARAMETER Arg
        REST source URL. Must end with a trailing slash for the winget client
        to construct sub-paths correctly. Example: 'https://winget.example.com/api/'.

    .PARAMETER Identifier
        Stable identifier used internally by winget to track the source.
        Defaults to 'RfPrivate'.

    .OUTPUTS
        [string] - the serialized XML document.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Arg,
        [string]$Name       = 'repofabric',
        [string]$Identifier = 'RfPrivate'
    )

    if (-not $Arg.EndsWith('/')) { $Arg = $Arg + '/' }

    $xmlDoc = [System.Xml.XmlDocument]::new()
    $sources = $xmlDoc.CreateElement('Sources')
    $source  = $xmlDoc.CreateElement('Source')
    $sources.AppendChild($source) | Out-Null
    $xmlDoc.AppendChild($sources) | Out-Null

    function _AddText { param([System.Xml.XmlElement]$parent, [string]$name, [string]$text)
        $el = $xmlDoc.CreateElement($name)
        $el.InnerText = $text
        $parent.AppendChild($el) | Out-Null
        return $el
    }
    _AddText $source 'Name'       $Name        | Out-Null
    _AddText $source 'Arg'        $Arg         | Out-Null
    _AddText $source 'Type'       'Microsoft.Rest' | Out-Null
    _AddText $source 'Identifier' $Identifier  | Out-Null
    _AddText $source 'Data'       ''           | Out-Null

    $pin    = $xmlDoc.CreateElement('CertificatePinning')
    $chains = $xmlDoc.CreateElement('Chains')
    $pin.AppendChild($chains) | Out-Null
    $source.AppendChild($pin) | Out-Null

    _AddText $source 'TrustLevel' 'Trusted' | Out-Null
    _AddText $source 'Explicit'   'false'   | Out-Null

    # Compact serialization, no XML declaration. Intune accepts both with
    # and without the declaration; omitting keeps the JSON-embedded payload
    # shorter and avoids accidental double-encoding by the operator.
    $sw = [System.IO.StringWriter]::new()
    $xw = [System.Xml.XmlTextWriter]::new($sw)
    $xw.Formatting = [System.Xml.Formatting]::None
    $xmlDoc.WriteTo($xw)
    $xw.Flush()
    return $sw.ToString()
}
