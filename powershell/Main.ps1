param(
    [Parameter(Mandatory)][string]$ListFile,
    [Parameter(Mandatory)][string]$SaveDir,
    [string]$DataDir = (Split-Path -Parent $SaveDir),
    [ValidateSet(1, 2, 4, 8, 16, 32, 64)][int]$Threads = 64
)

# ---------- Encoding ----------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "modules"
Get-ChildItem -LiteralPath $modulePath -Filter "*.psm1" | ForEach-Object { Import-Module $_.FullName -Force }

try {
    $config = Get-DownloaderConfig -ListFile $ListFile -SaveDir $SaveDir -DataDir $DataDir -ThreadCount $Threads
    New-Item -ItemType Directory -Path $config.SaveDir -Force | Out-Null
    New-Item -ItemType Directory -Path $config.TempDir -Force | Out-Null

    # 统一长期日志路径：DownloaderData/logs/download.log
    $logDir = Join-Path $DataDir "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $config.LogFile = Join-Path $logDir "download.log"

    # 不清空历史日志，只在首次创建时写入文件头
    if (-not (Test-Path -LiteralPath $config.LogFile)) {
        Set-Content -LiteralPath $config.LogFile -Encoding UTF8 -Value @(
            "========== Batch Download Log =========="
            ""
        )
    }

    # 每次下载任务开始时追加启动时间
    Add-Content -LiteralPath $config.LogFile -Encoding UTF8 -Value @(
        ""
        "========== Download Session =========="
        "Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ""
    )
    Initialize-ManualProcessFile -Path $config.ManualProcessFile
    $items = @(Read-DownloadList -Path $config.ListFile)
    if ($items.Count -eq 0) { throw "下载清单中没有有效任务。" }

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $pending = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $retryCount = @{}
    $commentMap = @{}
    $displayMap = @{}
    $resolvedFileMap = @{}
    $manualSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $successCount = 0
    $failedCount = 0
    $manualCount = 0
    $total = 0

    foreach ($item in $items) {
        $url = $item.Url
        try {
            $uri = [uri]$url
            if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @("http", "https")) { throw "仅支持 HTTP/HTTPS 链接" }
            if ($pending.Add($url)) {
                $queue.Enqueue($url)
                $commentMap[$url] = $item.CommentLine
                $displayMap[$url] = if ($item.DisplayName) { $item.DisplayName } else { $url }
                $retryCount[$url] = 0
                $total++
            }
        } catch {
            if ($manualSet.Add($url)) {
                Add-ManualProcessItem -Path $config.ManualProcessFile -Url $url -CommentLine $item.CommentLine -Reason "无效下载链接：$($_.Exception.Message)"
                $manualCount++
            }
            Write-DownloadLog -Path $config.LogFile -Status "ERROR" -FileName $item.DisplayName -Message "无效下载链接：$($_.Exception.Message)"
        }
    }

    Send-UiEvent -Type "log" -Message "读取到 $total 个有效下载任务。" -Data @{ total = $total }
    $progressCallback = {
        param([long]$received, [long]$totalBytes)
        $filePercent = if ($totalBytes -gt 0) { [math]::Floor($received * 100 / $totalBytes) } else { 0 }
        if ($filePercent -gt 100) { $filePercent = 100 }
        Send-UiEvent -Type "file-progress" -Message "文件下载进度" -Data @{ percent = $filePercent }
    }
    while ($queue.Count -gt 0) {
        $url = $queue.Dequeue()
        [void]$pending.Remove($url)
        $displayName = $displayMap[$url]
        $urlFileName = Get-DownloadFileName -Url $url
        $startDisplayName = if ([string]::IsNullOrWhiteSpace($urlFileName)) { $displayName } else { Get-SafeFileName -Name $urlFileName }
        Send-UiEvent -Type "log" -Message "开始下载：$startDisplayName"
        Send-UiEvent -Type "file-progress" -Message "文件下载进度" -Data @{ percent = 0; current = $startDisplayName }
        $downloadTempPath = Join-Path $config.TempDir ([guid]::NewGuid().ToString("N") + ".download")
        $result = Invoke-HttpDownload -Url $url -Destination $downloadTempPath -TimeoutSeconds $config.TimeoutSeconds -BufferSize $config.BufferSize -ThreadCount $config.ThreadCount -OnProgress $progressCallback

        if ($result.Success) {
            $name = Get-DownloadFileName -Url $url -ContentDisposition $result.ContentDisposition -FinalUrl $result.FinalUrl
            if ([string]::IsNullOrWhiteSpace($name)) { $name = "download-$([guid]::NewGuid().ToString('N')).bin" }
            $name = Get-SafeFileName -Name $name
            if ($resolvedFileMap.ContainsKey($url)) { $name = $resolvedFileMap[$url] } else { $resolvedFileMap[$url] = $name }
            Move-Item -LiteralPath $downloadTempPath -Destination (Join-Path $config.SaveDir $name) -Force
            $successCount++
            Write-DownloadLog -Path $config.LogFile -Status "SUCCESS" -FileName $name -Message "下载完成，大小：$($result.Size) bytes"
        } else {
            if ($result.IsNetwork) {
                $action = "Retry"
            } else {
                $retryCount[$url]++
                $action = Get-RetryAction -IsNetwork $false -RetryCount $retryCount[$url] -MaxNonNetworkRetries $config.MaxNonNetworkRetries
            }

            if ($action -eq "Retry") {
                Start-Sleep -Seconds $config.RetryDelaySeconds
                if ($pending.Add($url)) { $queue.Enqueue($url) }
                Write-DownloadLog -Path $config.LogFile -Status "RETRY" -FileName $displayName -Message "第 $($retryCount[$url]) 次重试；$($result.Error)"
            } else {
                $failedCount++
                if ($manualSet.Add($url)) {
                    Add-ManualProcessItem -Path $config.ManualProcessFile -Url $url -CommentLine $commentMap[$url] -Reason $result.Error
                    $manualCount++
                }
                Write-DownloadLog -Path $config.LogFile -Status "ERROR" -FileName $displayName -Message "达到最大重试次数，加入手动处理清单；$($result.Error)"
            }
        }

        Send-UiEvent -Type "progress" -Message "下载进度更新" -Data @{
            current = $displayName
            success = $successCount
            failed = $failedCount
            pending = $queue.Count
        }
    }

    $summary = @(
        "========== Batch Download Summary =========="
        "End: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Total: $total"
        "Success: $successCount"
        "Failed: $failedCount"
        "Manual process: $manualCount"
        "Manual list: $($config.ManualProcessFile)"
    )
    Add-Content -LiteralPath $config.LogFile -Value $summary -Encoding UTF8
    Send-UiEvent -Type "summary" -Message "下载结束：总数 $total，成功 $successCount，失败 $failedCount，需要手动处理 $manualCount。"
} catch {
    Send-UiEvent -Type "error" -Message $_.Exception.Message
    exit 1
}
