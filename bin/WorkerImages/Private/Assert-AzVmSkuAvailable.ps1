function Assert-AzVmSkuAvailable {
    param (
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $Location,
        [Parameter(Mandatory)][string] $VmSize,
        [bool] $UseSpot = $false
    )

    $region = $Location.ToLowerInvariant() -replace '[\s-]', ''
    $json = az vm list-skus --subscription $SubscriptionId --location $region `
        --resource-type virtualMachines --size $VmSize --all --output json
    if ($LASTEXITCODE -ne 0) { throw "Unable to check Azure VM SKU $VmSize in $region." }
    $availableSkus = @(
        ($json | ConvertFrom-Json -AsHashtable) | Where-Object {
            $_['resourceType'] -eq 'virtualMachines' -and $_['name'] -eq $VmSize -and $region -in $_['locations']
        }
    )
    # --size is a substring filter, so require an exact match ourselves.
    if ($availableSkus.Count -ne 1) { throw "VM SKU $VmSize is not offered in $region for subscription $SubscriptionId." }
    $sku = $availableSkus[0]
    foreach ($restriction in $sku['restrictions']) {
        # Packer's current Azure sources are non-zonal. A zone-only restriction
        # does not prohibit a regional VM; a location restriction does.
        if ($restriction['type'] -eq 'Zone') { continue }
        $locations = @($restriction['values'])
        if ($restriction['restrictionInfo']) { $locations += @($restriction['restrictionInfo']['locations']) }
        $locations = @($locations | Where-Object { $_ })
        if ($restriction['type'] -ne 'Location' -or -not $locations -or $region -in $locations) {
            throw "VM SKU $VmSize is restricted in ${region}: $($restriction | ConvertTo-Json -Compress -Depth 5)"
        }
    }
    if ($UseSpot -and -not ($sku['capabilities'] | Where-Object { $_['name'] -eq 'LowPriorityCapable' -and $_['value'] -eq 'True' })) {
        throw "VM SKU $VmSize does not advertise Spot support in $region."
    }
    # ponytail: catalogue support is not a capacity/quota reservation; allocation can still fail.
    Write-Host "Azure preflight: $VmSize is supported in $region (live capacity and quota are not guaranteed)."
}
