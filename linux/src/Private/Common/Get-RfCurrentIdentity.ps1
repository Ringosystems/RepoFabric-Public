function Get-RfCurrentIdentity {
    <#
    .SYNOPSIS
        Returns a string identifying the current operator for audit fields.

    .DESCRIPTION
        Resolution order:
          1. $script:RfOperatorUpn   (set by Invoke-RfApiRoute when the
             current loopback request carries an X-Rf-Operator-Upn header
             forwarded by the Node admin's per-request middleware). This is
             the browser-authenticated operator's Entra UPN.
          2. $env:REPOFABRIC_OPERATOR_UPN    (legacy env-var override; rare).
          3. The string 'SYSTEM'       (cron, scheduled cleanups, direct
             curl, any flow that did not pass an operator UPN). The string
             is intentionally short and unambiguous so the admin UI's
             Activity tab can render it as "SYSTEM (scheduled)" without
             extra heuristics.

        The Windows-fork helper of the same name returned DOMAIN\\user
        from WindowsIdentity. That is gone in the Linux container; the
        in-process uid (repofabric/99) is never meaningful as an "operator"
        and pretending it is leads to confusing audit rows that all
        attribute to repofabric@<container-id>.

    .OUTPUTS
        System.String. Either a UPN like 'ringo@example.com' or 'SYSTEM'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:RfOperatorUpn) { return [string]$script:RfOperatorUpn }
    if ($env:REPOFABRIC_OPERATOR_UPN)  { return [string]$env:REPOFABRIC_OPERATOR_UPN }
    return 'SYSTEM'
}
