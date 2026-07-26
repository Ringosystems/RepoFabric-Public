#Requires -Version 7.4
#Requires -Module Pester
# ConvertTo-RfHashtable must preserve JSON array-ness through the conversion.
#
# Regression: a bare `return @(...)` inside the function is UNROLLED on the way
# out, so a SINGLE-element array collapsed to its element. Every one-installer
# package submitted over RFIP (POST /api/v1/ingest/packages) therefore failed
# WinGet schema validation with:
#     Value is "object" but should be "array" at '/Installers' (schema_invalid)
# because [{...}] had been rewritten to {...} before Test-RfManifestSchema ran.
# The manifest on the wire was always correct; the router corrupted it. Note the
# collapse hit by-parameter calls (WebRouter's `-InputObject $body.manifest`)
# just as hard as piped ones, so "call it by parameter" was never a safeguard.
# The fix is the unary comma: `return ,@(...)`.

Describe 'ConvertTo-RfHashtable array fidelity' {
    BeforeAll {
        $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'RepoFabric.psd1')
        Import-Module $script:ModulePath -Force -ErrorAction Stop
    }

    Context 'single-element arrays survive (the RFIP /Installers bug)' {
        It 'keeps a one-installer Installers array as an array' {
            InModuleScope RepoFabric {
                $body = '{"PackageIdentifier":"Test.Pkg","Installers":[{"Architecture":"x64","InstallerUrl":"https://example.invalid/a.exe"}]}' | ConvertFrom-Json
                $m = ConvertTo-RfHashtable -InputObject $body
                $m['Installers'] -is [array] | Should -BeTrue
                @($m['Installers']).Count | Should -Be 1
            }
        }

        It 'serializes a one-installer manifest back to a JSON array, not an object' {
            InModuleScope RepoFabric {
                $body = '{"Installers":[{"Architecture":"x64"}]}' | ConvertFrom-Json
                $json = ConvertTo-Json -InputObject (ConvertTo-RfHashtable -InputObject $body) -Depth 20 -Compress
                # The exact shape the WinGet installer schema demands.
                $json | Should -BeLike '*"Installers":[[]*'
                $json | Should -Not -BeLike '*"Installers":{*'
            }
        }

        It 'keeps a one-element array of strings as an array' {
            InModuleScope RepoFabric {
                $body = '{"Tags":["cli"]}' | ConvertFrom-Json
                $m = ConvertTo-RfHashtable -InputObject $body
                $m['Tags'] -is [array] | Should -BeTrue
                @($m['Tags']).Count | Should -Be 1
            }
        }

        It 'keeps nested one-element arrays as arrays' {
            InModuleScope RepoFabric {
                $body = '{"Locales":[{"Keys":["a"]}]}' | ConvertFrom-Json
                $m = ConvertTo-RfHashtable -InputObject $body
                $m['Locales'] -is [array] | Should -BeTrue
                $m['Locales'][0]['Keys'] -is [array] | Should -BeTrue
            }
        }
    }

    Context 'other arities and scalars are unaffected' {
        It 'keeps a multi-element array as an array' {
            InModuleScope RepoFabric {
                $body = '{"Installers":[{"Architecture":"x64"},{"Architecture":"arm64"}]}' | ConvertFrom-Json
                $m = ConvertTo-RfHashtable -InputObject $body
                $m['Installers'] -is [array] | Should -BeTrue
                @($m['Installers']).Count | Should -Be 2
            }
        }

        It 'keeps an empty array as an empty array (not null)' {
            InModuleScope RepoFabric {
                $body = '{"Installers":[]}' | ConvertFrom-Json
                $m = ConvertTo-RfHashtable -InputObject $body
                $m['Installers'] -is [array] | Should -BeTrue
                @($m['Installers']).Count | Should -Be 0
            }
        }

        It 'leaves scalars and nested objects alone' {
            InModuleScope RepoFabric {
                $body = '{"Name":"x","Nested":{"N":1},"Flag":true}' | ConvertFrom-Json
                $m = ConvertTo-RfHashtable -InputObject $body
                $m['Name'] | Should -Be 'x'
                $m['Flag'] | Should -BeTrue
                $m['Nested'] -is [hashtable] | Should -BeTrue
                $m['Nested']['N'] | Should -Be 1
            }
        }

        It 'converts a string to a string, never to a char array' {
            InModuleScope RepoFabric {
                $m = ConvertTo-RfHashtable -InputObject 'plain'
                $m | Should -Be 'plain'
                $m -is [array] | Should -BeFalse
            }
        }
    }
}
