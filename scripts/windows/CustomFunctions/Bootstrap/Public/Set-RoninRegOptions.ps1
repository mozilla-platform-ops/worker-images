function Set-RoninRegOptions {
    param (
        [string] $mozilla_key = "HKLM:\SOFTWARE\Mozilla\",
        [string] $ronin_key = "$mozilla_key\ronin_puppet",
        [string] $source_key = "$ronin_key\source",
        [string] $Image_Provisioner = "azure",
        [string] $Worker_Pool_Id = $ENV:worker_pool_id,
        [string] $base_image = $ENV:base_image,
        [string] $src_Organisation = $ENV:src_organisation,
        [string] $src_Repository = $ENV:src_Repository,
        [string] $src_Branch = $ENV:src_Branch
    )
    begin {
        Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
    }
    process {
        If (-Not ( Test-path $ronin_key)) {
            New-Item -Path "HKLM:\SOFTWARE" -Name "Mozilla" -force | Out-Null
            New-Item -Path $mozilla_key -name "ronin_puppet" -force | Out-Null
        }

        New-Item -Path $ronin_key -Name source -force | Out-Null
        New-ItemProperty -Path $ronin_key -Name 'image_provisioner' -Value $image_provisioner -PropertyType String -force | Out-Null
        New-ItemProperty -Path $ronin_key -Name 'worker_pool_id' -Value $worker_pool_id -PropertyType String -force | Out-Null
        New-ItemProperty -Path $ronin_key -Name 'role' -Value $base_image -PropertyType String -force | Out-Null
        New-ItemProperty -Path $ronin_key -Name 'inmutable' -Value 'false' -PropertyType String -force | Out-Null
        New-ItemProperty -Path $ronin_key -Name 'last_run_exit' -Value '0' -PropertyType Dword -force | Out-Null
        New-ItemProperty -Path $ronin_key -Name 'bootstrap_stage' -Value 'setup' -PropertyType String -force | Out-Null
        New-ItemProperty -Path $source_key -Name 'Organisation' -Value $src_Organisation -PropertyType String -force | Out-Null
        New-ItemProperty -Path $source_key -Name 'Repository' -Value $src_Repository -PropertyType String -force | Out-Null
        New-ItemProperty -Path $source_key -Name 'Branch' -Value $src_Branch -PropertyType String -force | Out-Null
    }
    end {
        Write-Log -message ('{0} :: end - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('{0} :: end - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
    }
}
