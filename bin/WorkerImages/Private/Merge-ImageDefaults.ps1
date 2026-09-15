function Merge-ImageDefaults {
    param ([hashtable] $Defaults, [hashtable] $Image)

    $merged = @{}
    foreach ($key in $Defaults.Keys) { $merged[$key] = $Defaults[$key] }
    foreach ($key in $Image.Keys) {
        if ($Image[$key] -is [hashtable] -and $Defaults[$key] -is [hashtable]) {
            $merged[$key] = Merge-ImageDefaults -Defaults $Defaults[$key] -Image $Image[$key]
        } else {
            # Explicit false, empty arrays and null are overrides, not missing values.
            $merged[$key] = $Image[$key]
        }
    }
    return $merged
}
