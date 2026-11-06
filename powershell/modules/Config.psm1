function Get-DownloaderConfig {
    param([string]$ListFile, [string]$SaveDir, [string]$DataDir, [int]$ThreadCount = 64)
    [pscustomobject]@{
        ListFile = $ListFile
        SaveDir = $SaveDir
        DataDir = $DataDir
        LogFile = Join-Path (Join-Path $DataDir "logs") "download.log"
        TempDir = Join-Path $DataDir "tmp"
        ManualProcessFile = Join-Path $DataDir "manual_process.txt"
        TimeoutSeconds = 300
        BufferSize = 65536
        RetryDelaySeconds = 3
        MaxNonNetworkRetries = 5
        ThreadCount = $ThreadCount
    }
}
Export-ModuleMember -Function Get-DownloaderConfig
