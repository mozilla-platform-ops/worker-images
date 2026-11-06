function Resolve-GCPWorkerImageCaches {
    param(
        [string[]] $DockerImages = @()
    )
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $api = 'https://firefox-ci-tc.services.mozilla.com/api'
    $decision = (Invoke-RestMethod "$api/index/v1/task/gecko.v2.autoland.latest.taskgraph.decision" -MaximumRetryCount 5).taskId
    if (-not $decision) { throw 'Autoland index returned no decision task ID.' }
    $artifacts = "$api/queue/v1/task/$decision/artifacts/public"
    $download = [IO.Path]::GetTempFileName()
    try {
        Write-Host "Resolving cache inputs: decision=$decision"
        Invoke-WebRequest "$artifacts/parameters.yml" -OutFile $download -MaximumRetryCount 5
        $revision = (ConvertFrom-Yaml (Get-Content $download -Raw)).head_git_rev
        if ($revision -notmatch '^[0-9a-f]{40}$') { throw "Bad Gecko Git revision in decision $decision" }
        Invoke-WebRequest "$artifacts/run-task-git" -OutFile $download -MaximumRetryCount 5
        $helperHash = (Get-FileHash $download -Algorithm SHA256).Hash.ToLowerInvariant()

        Invoke-WebRequest "$artifacts/full-task-graph.json" -OutFile $download -MaximumRetryCount 5
        $dockerTasks = @{}
        foreach ($image in $DockerImages | Sort-Object -Unique) {
            if ($image -notmatch '^[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?$') {
                throw "Invalid Docker image name: $image"
            }
            $label = "docker-image-$image"
            $index = jq --stream -er --arg l $label 'select(.[0] == [$l, "optimization", "index-search", 0]) | .[1] // empty' $download
            if ($LASTEXITCODE -ne 0 -or -not $index) { throw "No image cache key for $label in decision $decision" }
            $dockerTask = (Invoke-RestMethod "$api/index/v1/task/$index" -MaximumRetryCount 5).taskId
            if ($dockerTask -notmatch '^[A-Za-z0-9_-]{22}$') { throw "Invalid Docker task ID at $index" }
            $status = Invoke-RestMethod "$api/queue/v1/task/$dockerTask/status" -MaximumRetryCount 5
            if ($status.status.state -ne 'completed') { throw "Docker task $dockerTask is not completed." }
            $dockerArtifacts = Invoke-RestMethod "$api/queue/v1/task/$dockerTask/artifacts" -MaximumRetryCount 5
            if (-not ($dockerArtifacts.artifacts | Where-Object { $_.name -eq 'public/image.tar.zst' })) {
                throw "Docker task $dockerTask has no public/image.tar.zst artifact."
            }
            if (-not $dockerTasks.ContainsKey($dockerTask)) {
                $dockerTasks[$dockerTask] = @{
                    docker_labels = @()
                    docker_index = $index
                    docker_task_id = $dockerTask
                }
            }
            $dockerTasks[$dockerTask].docker_labels += $label
        }
        $inputs = @{
            decision = $decision
            gecko_revision = $revision
            run_task_git_sha256 = $helperHash
            docker_images = @($dockerTasks.Values)
        }
        $manifest = [IO.Path]::GetTempFileName()
        $inputs | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifest -Encoding utf8
        Write-Host "Pinned cache inputs: Gecko=$revision DockerImages=$($dockerTasks.Count) helper=$helperHash"
        return $manifest
    } finally {
        Remove-Item -LiteralPath $download -Force
    }
}
