function Get-DownloadFileName {
    param([string]$Url, [string]$ContentDisposition, [string]$FinalUrl)
    if ($ContentDisposition) {
        if ($ContentDisposition -match 'filename\*\s*=\s*(?:UTF-8''|utf-8'')?([^;]+)') {
            $candidate = $Matches[1].Trim('"', "'", ' ')
            try { return [uri]::UnescapeDataString($candidate) } catch {}
        }
        if ($ContentDisposition -match 'filename\s*=\s*"?([^";]+)') {
            return $Matches[1].Trim()
        }
    }
    foreach ($candidateUrl in @($FinalUrl, $Url)) {
        if ([string]::IsNullOrWhiteSpace($candidateUrl)) { continue }
        try {
            $uri = [uri]$candidateUrl
            $name = [IO.Path]::GetFileName($uri.AbsolutePath)
            if ($name) { return [uri]::UnescapeDataString($name) }
        } catch {}
    }
    foreach ($candidateUrl in @($FinalUrl, $Url)) {
        if ($candidateUrl -match '[?&](?:filename|file|name)=([^&]+)') {
            try { return [uri]::UnescapeDataString($Matches[1]) } catch {}
        }
    }
    return $null
}
function Get-SafeFileName {
    param([string]$Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    foreach ($char in $invalid) { $Name = $Name.Replace([string]$char, "_") }
    return $Name.Trim()
}
Export-ModuleMember -Function Get-DownloadFileName, Get-SafeFileName
