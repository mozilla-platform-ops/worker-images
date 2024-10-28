## Run taskcluster tests
chmod +x /workerimages/tests/taskcluster.tests.ps1
pwsh -Command "Invoke-Pester -Path /workerimages/tests/taskcluster.tests.ps1"