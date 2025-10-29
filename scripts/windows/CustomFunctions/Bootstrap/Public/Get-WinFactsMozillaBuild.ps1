function Get-WinFactsMozillaBuild {
    # This Source Code Form is subject to the terms of the Mozilla Public
    # License, v. 2.0. If a copy of the MPL was not distributed with this
    # file, You can obtain one at http://mozilla.org/MPL/2.0/.

    # This is specific for creation of facts for items isntalled
    # by the Mozilla Build package

    # these are needed becuase we are unable to run validation commands
    # or do a direct version validation of application

    $mozbld_file = "$env:systemdrive\mozilla-build\VERSION"
    $hg_file = "$env:ProgramW6432\Mercurial\hg.exe"
    $python3_file = "$env:systemdrive\mozilla-build\python3\python3.exe"
    $zstandard = "$env:systemdrive\mozilla-build\python3\lib\site-packages\zstandard"

    # Mozilla Build
    # Needed in roles_profiles::profiles::mozilla_build
    if (Test-Path $mozbld_file) {
        $mozbld_ver = (get-content $mozbld_file)
    }
    else {
        $mozbld_ver = 0.0.0
    }

    # Mercurial
    # Needed in roles_profiles::profiles::mozilla_build
    if (Test-Path $hg_file) {
        $hg_object = Get-InstalledSoftware | Where-Object { $PSItem.displayname -match "Mercurial" }
        $hg_ver = $hg_object.DisplayVersion
    }
    else {
        $hg_ver = 0.0.0
    }

    # Python 3 Pip
    if (Test-Path $python3_file) {
        $pip_version = (C:\mozilla-build\python3\python3.exe -m pip --version)
        $py3_pip_version = ($pip_version -split " ")[1]
    }
    else {
        $py3_pip_version = 0.0.0
    }

    # Python version
    if (Test-Path $python3_file) {
        $python_version_out = (C:\mozilla-build\python3\python3.exe --version)
        $python_version = ($python_version_out -split " ")[1]
    }
    else {
        $python_version = 0.0.0
    }

    # Pyhton 3 zstandard
    if (Test-Path $python3_file) {
        $zstandard_info = (C:\mozilla-build\python3\python3.exe -m pip show zstandard)
        $zstandard_version = [regex]::Matches($zstandard_info, "(\d+\.\d+\.\d+)").value
    }
    else {
        $zstandard_version = 0.0.0
    }

    [PSCustomObject]@{
        custom_win_py3_pip_version       = $py3_pip_version
        custom_win_mozbld_version        = $mozbld_ver
        custom_win_hg_version            = $hg_ver
        custom_win_py3_zstandard_version = $zstandard_version
        custom_win_python_version        = $python_version
    }

}