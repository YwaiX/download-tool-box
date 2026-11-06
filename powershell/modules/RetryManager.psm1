function Get-RetryAction {
    param([bool]$IsNetwork, [int]$RetryCount, [int]$MaxNonNetworkRetries)
    if ($IsNetwork) { return "Retry" }
    if ($RetryCount -le $MaxNonNetworkRetries) { return "Retry" }
    return "Manual"
}
Export-ModuleMember -Function Get-RetryAction
