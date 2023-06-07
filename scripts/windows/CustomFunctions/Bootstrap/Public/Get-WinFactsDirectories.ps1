Function Get-WinFactsDirectories {
    $systemdrive = $env:systemdrive
    $system32 = "$systemdrive\windows\system32"
    $programdata = $env:programdata
    $programfiles = $env:ProgramW6432
    $programfilesx86 = "$systemdrive\Program Files (x86)"

    # Bug list
    # https://bugzilla.mozilla.org/show_bug.cgi?id=1520855
    [PSCustomObject]@{
        custom_win_systemdrive       = $env:systemdrive
        custom_win_system32          = $system32
        custom_win_programdata       = $programdata
        custom_win_programfiles      = $programfiles
        custom_win_programfilesx86   = $programfilesx86
        custom_win_roninprogramdata  = "$($programdata)\PuppetLabs\ronin"
        custom_win_roninsemaphoredir = "$($programdata)\PuppetLabs\ronin\semaphore"
        custom_win_roninslogdir      = "$($systemdrive)\logs"
        custom_win_temp_dir          = "$($systemdrive)\Windows\Temp"
        custom_win_third_party       = "$($systemdrive)\third_party"
    }
}
