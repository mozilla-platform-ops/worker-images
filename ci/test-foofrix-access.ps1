# Run from the repository root: pwsh -File ci/test-foofrix-access.ps1
$ErrorActionPreference = 'Stop'
$oldActor = $env:GITHUB_ACTOR
$pwsh = (Get-Process -Id $PID).Path
try {
    foreach ($case in @(
        @{ Actor = 'dpalmeiro'; Additional = $true; Allowed = $true },
        @{ Actor = 'dpalmeiro'; Additional = $false; Allowed = $false },
        @{ Actor = 'markcor'; Additional = $true; Allowed = $true },
        @{ Actor = 'markcor'; Additional = $false; Allowed = $true },
        @{ Actor = 'unauthorized-test-user'; Additional = $true; Allowed = $false },
        @{ Actor = ''; Additional = $true; Allowed = $false }
    )) {
        $env:GITHUB_ACTOR = $case.Actor
        $arguments = @('-NoProfile', '-File', 'ci/check-authorized-user.ps1')
        if ($case.Additional) { $arguments += @('-AdditionalUsersFile', '.github/foofrix.json') }
        & $pwsh @arguments *> $null
        if (($LASTEXITCODE -eq 0) -ne $case.Allowed) {
            throw "Unexpected authorization result for '$($case.Actor)', FooFrix=$($case.Additional)"
        }
    }
    Write-Host 'All authorization checks passed.'
} finally {
    $env:GITHUB_ACTOR = $oldActor
}
