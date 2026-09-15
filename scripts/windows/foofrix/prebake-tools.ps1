# Run after the compiler installation and restart. No runtime authentication.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Match FooFrix's current samply source selection. Record the resolved commit below.
& cargo.exe install --git https://github.com/mstange/samply --branch main --locked samply
if ($LASTEXITCODE -ne 0) { throw 'samply installation failed' }
& cargo.exe install --locked searchfox-cli
if ($LASTEXITCODE -ne 0) { throw 'searchfox-cli installation failed' }

# Preserve resolved versions, including the samply commit, with the image.
$inventory = & cargo.exe install --list
if ($LASTEXITCODE -ne 0) { throw 'Cargo inventory failed' }
$inventory | Set-Content 'C:\FooFrix\cargo-tools.txt'
