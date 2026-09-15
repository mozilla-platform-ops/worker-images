function Export-WorkerImageEnvironment {
    # Functions also work locally; GitHub Actions needs values in later steps.
    if (-not $env:GITHUB_ENV) { return }
    foreach ($variable in Get-ChildItem Env: | Where-Object Name -Match '^(PKR_VAR_|PACKER_GITHUB_API_TOKEN$)') {
        $delimiter = [guid]::NewGuid().ToString('N')
        "$($variable.Name)<<$delimiter`n$($variable.Value)`n$delimiter" |
            Out-File -LiteralPath $env:GITHUB_ENV -Append -Encoding utf8
    }
}
