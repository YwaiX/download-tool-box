$script:MinRangeSize = 524288
$script:ModulePath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

function Test-NetworkException {
    param([System.Exception]$Exception)
    $current = $Exception
    while ($current) {
        if ($current -is [System.Net.WebException]) {
            return $current.Status -in @(
                [System.Net.WebExceptionStatus]::NameResolutionFailure,
                [System.Net.WebExceptionStatus]::ProxyNameResolutionFailure,
                [System.Net.WebExceptionStatus]::ConnectFailure,
                [System.Net.WebExceptionStatus]::Timeout,
                [System.Net.WebExceptionStatus]::ConnectionClosed,
                [System.Net.WebExceptionStatus]::ReceiveFailure,
                [System.Net.WebExceptionStatus]::SendFailure,
                [System.Net.WebExceptionStatus]::PipelineFailure,
                [System.Net.WebExceptionStatus]::KeepAliveFailure
            )
        }
        if ($current -is [System.IO.IOException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Get-RangeProbe {
    param([string]$Url, [int]$TimeoutSeconds = 300)
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = "GET"
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AllowAutoRedirect = $true
        $request.UserAgent = "Downloader/1.0"
        $request.AddRange(0, 0)
        $response = $request.GetResponse()
        $probe = [pscustomobject]@{
            Supported = $false
            Total = [long]0
            ContentDisposition = $response.Headers["Content-Disposition"]
            FinalUrl = $response.ResponseUri.AbsoluteUri
            Error = $null
            IsNetwork = $false
        }
        $contentRange = $response.Headers["Content-Range"]
        $contentEncoding = $response.Headers["Content-Encoding"]
        if ([int]$response.StatusCode -eq 206 -and -not $contentEncoding -and $contentRange -match '/(\d+)\s*$') {
            $probe.Total = [long]$Matches[1]
            $probe.Supported = $probe.Total -gt 0
        }
        return $probe
    } catch {
        return [pscustomobject]@{
            Supported = $false; Total = [long]0; ContentDisposition = $null; FinalUrl = $null
            Error = $_.Exception.Message; IsNetwork = (Test-NetworkException -Exception $_.Exception)
        }
    } finally {
        if ($response) { $response.Close() }
    }
}

function Invoke-RangeSegment {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][long]$Start,
        [Parameter(Mandatory)][long]$End,
        [Parameter(Mandatory)][string]$FilePath,
        [int]$TimeoutSeconds = 300,
        [int]$BufferSize = 65536,
        [int]$Index = -1,
        [hashtable]$ProgressState = $null
    )
    $response = $null
    $inputStream = $null
    $outputStream = $null
    $progressClock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = "GET"
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AllowAutoRedirect = $true
        $request.UserAgent = "Downloader/1.0"
        $request.AddRange($Start, $End)
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 206) {
            throw "服务器未按范围响应（状态码 $([int]$response.StatusCode)）"
        }
        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] $BufferSize
        [long]$received = 0
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $received += $read
            if ($ProgressState -and $Index -ge 0 -and $progressClock.ElapsedMilliseconds -ge 300) {
                $ProgressState[$Index] = $received
                $progressClock.Restart()
            }
        }
        $outputStream.Flush()
        if ($ProgressState -and $Index -ge 0) { $ProgressState[$Index] = $received }
        $expected = $End - $Start + 1
        if ($received -ne $expected) {
            throw "分段长度不匹配，预期 $expected 字节，实际 $received 字节"
        }
        return [pscustomobject]@{ Ok = $true; Error = $null; IsNetwork = $false }
    } catch {
        return [pscustomobject]@{
            Ok = $false; Error = $_.Exception.Message
            IsNetwork = (Test-NetworkException -Exception $_.Exception)
        }
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Close() }
    }
}

function Invoke-RangedDownload {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$SegmentCount,
        [long]$Total,
        [string]$ContentDisposition,
        [string]$FinalUrl,
        [int]$TimeoutSeconds = 300,
        [int]$BufferSize = 65536,
        [scriptblock]$OnProgress = $null
    )
    $temp = "$Destination.download.tmp"
    $partPaths = [System.Collections.Generic.List[string]]::new()
    $jobs = [System.Collections.Generic.List[object]]::new()
    $progressState = [hashtable]::Synchronized(@{})
    $pool = $null
    $outputStream = $null
    $isNetwork = $false
    try {
        $segmentUrl = if ([string]::IsNullOrWhiteSpace($FinalUrl)) { $Url } else { $FinalUrl }
        $segmentSize = [long][Math]::Ceiling($Total / $SegmentCount)
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $SegmentCount)
        $pool.Open()

        for ($index = 0; $index -lt $SegmentCount; $index++) {
            $start = [long]$index * $segmentSize
            if ($start -ge $Total) { break }
            $end = [Math]::Min($start + $segmentSize - 1, $Total - 1)
            $partPath = "$temp.part$index"
            $partPaths.Add($partPath)

            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript({
                param($Url, $Start, $End, $FilePath, $TimeoutSeconds, $BufferSize, $ModulePath, $Index, $ProgressState)
                Import-Module $ModulePath -Force
                Invoke-RangeSegment -Url $Url -Start $Start -End $End -FilePath $FilePath -TimeoutSeconds $TimeoutSeconds -BufferSize $BufferSize -Index $Index -ProgressState $ProgressState
            }).AddParameter("Url", $segmentUrl).AddParameter("Start", $start).AddParameter("End", $end).AddParameter("FilePath", $partPath).AddParameter("TimeoutSeconds", $TimeoutSeconds).AddParameter("BufferSize", $BufferSize).AddParameter("ModulePath", $script:ModulePath).AddParameter("Index", $index).AddParameter("ProgressState", $progressState)

            $jobs.Add([pscustomobject]@{
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            })
        }

        while ($true) {
            $allDone = $true
            foreach ($job in $jobs) {
                if (-not $job.Handle.IsCompleted) { $allDone = $false; break }
            }
            if ($OnProgress -and $Total -gt 0) {
                [long]$receivedTotal = 0
                for ($index = 0; $index -lt $jobs.Count; $index++) {
                    if ($progressState.ContainsKey($index)) { $receivedTotal += [long]$progressState[$index] }
                }
                & $OnProgress $receivedTotal $Total
            }
            if ($allDone) { break }
            Start-Sleep -Milliseconds 300
        }

        $errors = [System.Collections.Generic.List[string]]::new()
        foreach ($job in $jobs) {
            $result = $null
            try {
                $result = $job.PowerShell.EndInvoke($job.Handle) | Select-Object -Last 1
            } catch {
                $errors.Add($_.Exception.Message)
                if (Test-NetworkException -Exception $_.Exception) { $isNetwork = $true }
                continue
            }
            if (-not $result -or -not $result.Ok) {
                if ($result) {
                    $errors.Add($result.Error)
                    if ($result.IsNetwork) { $isNetwork = $true }
                } else {
                    $errors.Add("分段下载未返回结果")
                }
            }
        }
        if ($errors.Count -gt 0) { throw ($errors[0]) }

        $outputStream = [System.IO.File]::Open($temp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        foreach ($partPath in $partPaths) {
            $inputStream = [System.IO.File]::OpenRead($partPath)
            try { $inputStream.CopyTo($outputStream, $BufferSize) } finally { $inputStream.Dispose() }
        }
        $outputStream.Flush()
        $outputStream.Dispose(); $outputStream = $null

        $size = (Get-Item -LiteralPath $temp).Length
        if ($size -ne $Total) { throw "文件长度不匹配，预期 $Total 字节，实际 $size 字节" }
        Move-Item -LiteralPath $temp -Destination $Destination -Force
        if ($OnProgress) { & $OnProgress $Total $Total }
        return [pscustomobject]@{
            Success = $true; Size = $size; ContentDisposition = $ContentDisposition
            FinalUrl = $FinalUrl; Error = $null; IsNetwork = $false
        }
    } catch {
        return [pscustomobject]@{
            Success = $false; Size = 0; ContentDisposition = $null
            FinalUrl = $null; Error = $_.Exception.Message; IsNetwork = $isNetwork
        }
    } finally {
        foreach ($job in $jobs) {
            try { $job.PowerShell.Dispose() } catch {}
        }
        if ($pool) { $pool.Close(); $pool.Dispose() }
        if ($outputStream) { $outputStream.Dispose() }
        foreach ($partPath in $partPaths) { Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-HttpDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [int]$TimeoutSeconds = 300,
        [int]$BufferSize = 65536,
        [int]$ThreadCount = 1,
        [scriptblock]$OnProgress = $null
    )
    if ($ThreadCount -gt 1) {
        $probe = Get-RangeProbe -Url $Url -TimeoutSeconds $TimeoutSeconds
        if ($probe.Error) {
            return [pscustomobject]@{
                Success = $false; Size = 0; ContentDisposition = $null
                FinalUrl = $null; Error = $probe.Error; IsNetwork = $probe.IsNetwork
            }
        }
        if ($probe.Supported) {
            $segmentCount = [int][Math]::Min([long]$ThreadCount, [long][Math]::Ceiling($probe.Total / $script:MinRangeSize))
            if ($segmentCount -gt 1) {
                return Invoke-RangedDownload -Url $Url -Destination $Destination -SegmentCount $segmentCount `
                    -Total $probe.Total -ContentDisposition $probe.ContentDisposition -FinalUrl $probe.FinalUrl `
                    -TimeoutSeconds $TimeoutSeconds -BufferSize $BufferSize -OnProgress $OnProgress
            }
        }
    }

    $temp = "$Destination.download.tmp"
    $request = $null
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = "GET"
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AllowAutoRedirect = $true
        $request.UserAgent = "Downloader/1.0"
        $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $response = $request.GetResponse()
        $contentLength = $response.ContentLength
        $progressClock = [System.Diagnostics.Stopwatch]::StartNew()
        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open($temp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] $BufferSize
        [long]$received = 0
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $received += $read
            if ($OnProgress -and $contentLength -gt 0 -and $progressClock.ElapsedMilliseconds -ge 300) {
                & $OnProgress $received $contentLength
                $progressClock.Restart()
            }
        }
        $outputStream.Flush()
        $outputStream.Dispose(); $outputStream = $null
        $inputStream.Dispose(); $inputStream = $null
        $contentDisposition = $response.Headers["Content-Disposition"]
        $finalUrl = $response.ResponseUri.AbsoluteUri
        $response.Close(); $response = $null

        if ($received -le 0) { throw "下载文件为空" }
        if ($contentLength -gt 0 -and $received -ne $contentLength) {
            throw "文件长度不匹配，预期 $contentLength 字节，实际 $received 字节"
        }
        Move-Item -LiteralPath $temp -Destination $Destination -Force
        if ($OnProgress) {
            $progressTotal = if ($contentLength -gt 0) { $contentLength } else { $received }
            & $OnProgress $received $progressTotal
        }
        return [pscustomobject]@{
            Success = $true; Size = $received; ContentDisposition = $contentDisposition
            FinalUrl = $finalUrl; Error = $null; IsNetwork = $false
        }
    } catch {
        $isNetwork = Test-NetworkException -Exception $_.Exception
        return [pscustomobject]@{
            Success = $false; Size = 0; ContentDisposition = $null
            FinalUrl = $null; Error = $_.Exception.Message; IsNetwork = $isNetwork
        }
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Close() }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}
Export-ModuleMember -Function Invoke-HttpDownload, Invoke-RangeSegment, Test-NetworkException
