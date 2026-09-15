Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot/../bin/WorkerImages/Private/Import-WorkerImagesYaml.ps1"
Import-WorkerImagesYaml
