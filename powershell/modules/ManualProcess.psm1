function Initialize-ManualProcessFile {
    param([string]$Path)
    Set-Content -LiteralPath $Path -Encoding UTF8 -Value @(
        "========== 需要手动处理的下载任务 =========="
        "生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ""
    )
}
function Add-ManualProcessItem {
    param([string]$Path, [string]$Url, [string]$CommentLine, [string]$Reason)
    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($CommentLine)) { $lines += $CommentLine }
    $lines += $Url
    if ($Reason) { $lines += "# 失败原因：$Reason" }
    $lines += ""
    Add-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}
Export-ModuleMember -Function Initialize-ManualProcessFile, Add-ManualProcessItem
