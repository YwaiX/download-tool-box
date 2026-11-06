function Send-UiEvent {
    param([Parameter(Mandatory)][string]$Type, [string]$Message = "", [hashtable]$Data = @{})
    $payload = @{ type = $Type; message = $Message }
    foreach ($key in $Data.Keys) { $payload[$key] = $Data[$key] }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress -Depth 6))
}
function Write-DownloadLog {
    param([string]$Path, [string]$Status, [string]$FileName, [string]$Message)
    $line = "[{0}] [{1}] {2} | {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Status, $FileName, $Message
    # 明细日志只进入当前会话日志和日志控制台，不写入长期总日志 download.log
    Send-UiEvent -Type "log" -Message $line
}
Export-ModuleMember -Function Send-UiEvent, Write-DownloadLog
