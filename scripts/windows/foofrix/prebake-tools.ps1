# Run after the compiler installation and restart. No runtime authentication.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$software = (Get-Content 'C:\FooFrix\image-config.json' -Raw | ConvertFrom-Json).software

# Match FooFrix's current samply source selection. Record the resolved commit below.
& cargo.exe install --git https://github.com/mstange/samply --rev $software.samply_revision --locked samply
if ($LASTEXITCODE -ne 0) { throw 'samply installation failed' }
& cargo.exe install --locked --version $software.searchfox_cli searchfox-cli
if ($LASTEXITCODE -ne 0) { throw 'searchfox-cli installation failed' }

# Preserve resolved versions, including the samply commit, with the image.
$inventory = & cargo.exe install --list
if ($LASTEXITCODE -ne 0) { throw 'Cargo inventory failed' }
$inventory | Set-Content 'C:\FooFrix\cargo-tools.txt'
