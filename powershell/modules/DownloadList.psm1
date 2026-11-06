function Read-DownloadList {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "下载清单不存在：$Path" }
    $items = [System.Collections.Generic.List[object]]::new()
    $commentLine = $null
    $commentText = $null
    $versions = @()
    $versionIndex = 0
    foreach ($raw in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith("#")) {
            $commentLine = $line
            $commentText = $line.TrimStart("#").Trim()
            $versionIndex = 0
            $versions = @()
            if ($commentText -match '^(.*?)\s*\[([^\]]+)\]\s*$') {
                $commentText = $Matches[1].Trim()
                $versions = @($Matches[2].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            continue
        }
        if ($line -notmatch '^https?://') {
            $items.Add([pscustomobject]@{ Url = $line; CommentLine = $commentLine; DisplayName = $commentText; Version = $null })
            continue
        }
        $version = $null
        if ($versionIndex -lt $versions.Count) { $version = $versions[$versionIndex] }
        $versionIndex++
        $display = $commentText
        if ($version) { $display = "$display $version" }
        $items.Add([pscustomobject]@{
            Url = $line
            CommentLine = $commentLine
            DisplayName = $display
            Version = $version
        })
    }
    return $items
}
Export-ModuleMember -Function Read-DownloadList
