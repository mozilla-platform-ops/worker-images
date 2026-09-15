@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # Provisioning output belongs in the build transcript, including Write-Host.
        'PSAvoidUsingWriteHost'
        # These unattended entrypoints must run to completion, not partially honor WhatIf.
        'PSUseShouldProcessForStateChangingFunctions'
        # Keep the existing public provisioning API names; renaming them is not a lint fix.
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
    )
}
