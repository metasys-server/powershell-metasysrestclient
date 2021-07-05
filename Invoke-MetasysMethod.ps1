

param(
    [string]$SiteHost,
    [string]$UserName,
    [switch]$Login,
    [Parameter(Position=0)]
    [string]$Path,
    [switch]$Clear,
    [string]$Body,
    [Microsoft.PowerShell.Commands.WebRequestMethod]$Method = "Get",
    [Int]$Version,
    [switch]$SkipCertificateCheck,
    [hashtable]$Headers,
    [SecureString]$Password

)
Import-Module -Force -Name ./Invoke-MetasysMethod

#Get-MetasysUsers

# mget-object "WIN-21DJ9JV9QH6:EECMI-NCE25-2/MV1" -SkipCertificateCheck:$SkipCertificateCheck
Invoke-MetasysMethod -SiteHost $SiteHost -UserName $UserName -Path $Path -Body $Body `
    -Method $Method -Version $Version -SkipCertificateCheck:$SkipCertificateCheck `
    -Clear:$Clear -Login:$Login -Header $Headers -Password $Password
