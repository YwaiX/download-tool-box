function Get-NextThreadCount {
    param([int]$Current)
    $levels = @(64, 32, 16, 8, 4, 2, 1)
    $index = [array]::IndexOf($levels, $Current)
    if ($index -lt 0 -or $index -ge $levels.Count - 1) { return 1 }
    return $levels[$index + 1]
}
Export-ModuleMember -Function Get-NextThreadCount
