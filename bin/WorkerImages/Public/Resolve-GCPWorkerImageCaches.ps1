function Resolve-GCPWorkerImageCaches {
    param([Parameter(Mandatory)][ValidateSet('AMD64', 'ARM64')][string] $Architecture)
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $image = switch ($Architecture) {
        'AMD64' { 'ubuntu2404-test-base' }
        'ARM64' { 'ubuntu2404-arm64-test-base' }
    }
    $api = 'https://firefox-ci-tc.services.mozilla.com/api'
    $decision = (Invoke-RestMethod "$api/index/v1/task/gecko.v2.autoland.latest.taskgraph.decision" -MaximumRetryCount 5).taskId
    if (-not $decision) { throw 'Autoland index returned no decision task ID.' }
    $artifacts = "$api/queue/v1/task/$decision/artifacts/public"
    $download = [IO.Path]::GetTempFileName()
    try {
        Write-Host "Resolving cache inputs: decision=$decision image=$image"
        Invoke-WebRequest "$artifacts/parameters.yml" -OutFile $download -MaximumRetryCount 5
        $revision = (ConvertFrom-Yaml (Get-Content $download -Raw)).head_git_rev
        if ($revision -notmatch '^[0-9a-f]{40}$') { throw "Bad Gecko Git revision in decision $decision" }
        Invoke-WebRequest "$artifacts/run-task-git" -OutFile $download -MaximumRetryCount 5
        $helperHash = (Get-FileHash $download -Algorithm SHA256).Hash.ToLowerInvariant()

        # The full graph retains exact image cache keys on DONTBUILD pushes.
        Invoke-WebRequest "$artifacts/full-task-graph.json" -OutFile $download -MaximumRetryCount 5
        $label = "docker-image-$image"
        $index = jq --stream -er --arg l $label 'select(.[0] == [$l, "optimization", "index-search", 0]) | .[1] // empty' $download
        if ($LASTEXITCODE -ne 0 -or -not $index) { throw "No image cache key for $label in decision $decision" }
        $dockerTask = (Invoke-RestMethod "$api/index/v1/task/$index" -MaximumRetryCount 5).taskId
        if (-not $dockerTask) { throw "No Docker task ID at $index" }
        $status = Invoke-RestMethod "$api/queue/v1/task/$dockerTask/status" -MaximumRetryCount 5
        if ($status.status.state -ne 'completed') { throw "Docker task $dockerTask is not completed." }
        $dockerArtifacts = Invoke-RestMethod "$api/queue/v1/task/$dockerTask/artifacts" -MaximumRetryCount 5
        if (-not ($dockerArtifacts.artifacts | Where-Object { $_.name -eq 'public/image.tar.zst' })) {
            throw "Docker task $dockerTask has no public/image.tar.zst artifact."
        }
        $inputs = @{
            decision = $decision
            gecko_revision = $revision
            run_task_git_sha256 = $helperHash
            docker_label = $label
            docker_index = $index
            docker_task_id = $dockerTask
        }
        $manifest = [IO.Path]::GetTempFileName()
        $inputs | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding utf8
        Write-Host "Pinned cache inputs: Gecko=$revision Docker=$dockerTask helper=$helperHash"
        return $manifest
    } finally {
        Remove-Item -LiteralPath $download -Force
    }
}
