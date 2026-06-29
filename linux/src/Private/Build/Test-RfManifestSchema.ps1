function Test-RfManifestSchema {
    <#
    .SYNOPSIS
        Validates a custom manifest payload against the vendored WinGet v1.6.0
        JSON schemas. Used server-side as belt-and-braces beyond the
        wizard's client-side validation.
    .DESCRIPTION
        The payload shape mirrors the JSON the publish-custom SPA posts:
          {
            "version":      {...},   # validated against manifest.version.1.6.0.json
            "installer":    {...},   # validated against manifest.installer.1.6.0.json
            "defaultLocale":{...},   # validated against manifest.defaultLocale.1.6.0.json
            "locales":      [{...}]  # each validated against manifest.locale.1.6.0.json
          }
        Returns @{ Valid = $true } on success or @{ Valid = $false;
        Errors = [string[]] } with a per-document error list.
    .PARAMETER Manifest
        The manifest payload as a hashtable / PSCustomObject.
    .PARAMETER SchemaDir
        Override the schemas directory. Defaults to <module>/../schemas/.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [string]$SchemaDir
    )

    if (-not $SchemaDir) {
        $SchemaDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'schemas'
    }
    if (-not (Test-Path $SchemaDir)) {
        throw "Schema directory not found: $SchemaDir"
    }

    $errors = [System.Collections.Generic.List[string]]::new()

    function _CheckOne {
        param([string]$Label, [object]$Doc, [string]$SchemaFile)
        if (-not $Doc) { return }
        $schemaPath = Join-Path $SchemaDir $SchemaFile
        if (-not (Test-Path $schemaPath)) {
            $errors.Add("$Label : schema file missing: $SchemaFile")
            return
        }
        try {
            $json = $Doc | ConvertTo-Json -Depth 20 -Compress
            $schema = Get-Content -Raw -Path $schemaPath
            if (-not (Test-Json -Json $json -Schema $schema -ErrorAction Stop)) {
                $errors.Add("$Label : schema check returned false")
            }
        } catch {
            $errors.Add("$Label : $($_.Exception.Message)")
        }
    }

    _CheckOne 'version'       $Manifest.version        'manifest.version.1.6.0.json'
    _CheckOne 'installer'     $Manifest.installer      'manifest.installer.1.6.0.json'
    _CheckOne 'defaultLocale' $Manifest.defaultLocale  'manifest.defaultLocale.1.6.0.json'

    if ($Manifest.locales) {
        for ($i = 0; $i -lt @($Manifest.locales).Count; $i++) {
            _CheckOne ("locales[$i]") $Manifest.locales[$i] 'manifest.locale.1.6.0.json'
        }
    }

    return @{ Valid = ($errors.Count -eq 0); Errors = @($errors) }
}
