using namespace System
using namespace System.IO
using namespace System.Security
using namespace Microsoft.PowerShell.Commands
using namespace System.Management.Automation

Set-StrictMode -Version 3

# HACK: https://stackoverflow.com/a/49859001
# Otherwise on Linux I get "Unable to find type [WebRequestMethod]" error
Start-Sleep -Milliseconds 1

function assertPowershellCore {
    if ($PSVersionTable.PSEdition -ne "Core") {

        $errorString = "Windows Powershell is not supported. Please install PowerShell Core" + "`n" + "Windows Powershell is not supported. Please install PowerShell Core"
        throw $errorString
    }
}

function setBackgroundColorsToMatchConsole {
    # Setup text background colors to match console background
    $backgroundColor = $Host.UI.RawUI.BackgroundColor
    if ($Host.PrivateData) {
        $Host.PrivateData.DebugBackgroundColor = $backgroundColor
        $Host.PrivateData.ErrorBackgroundColor = $backgroundColor
        $Host.PrivateData.WarningBackgroundColor = $backgroundColor
        $Host.PrivateData.VerboseBackgroundColor = $backgroundColor
    }

}

function convertResponseObjectToString {
    param(
        [WebResponseObject]$responseObject
    )

    $body = [String]::new($responseObject.Content)
    $errorMessage = "`nStatus: " + $responseObject.StatusCode.ToString() + " (" + $responseObject.StatusDescription + ")"
    $responseObject.Headers.Keys | ForEach-Object { $errorMessage += "`n" + $_ + ": " + $responseObject.Headers[$_] }
    $errorMessage += "`n$body"
    return $errorMessage
}

function createErrorStringFromResponseObject {
    param(
        [WebResponseObject]$responseObject
    )

    return convertResponseObjectToString $responseObject
}

function invokeWithWarningsOff {
    <#
        .SYNOPOSIS
            Invokes a script block with warning preference set to SilentlyContinue
            This is used in this file to invoke the password management functions that
            write warnings when called directly by a client. But for which we'd rather
            not see warnings if they are called by Invoke-MetasysMethod.

            It seems that I should just be able to invoke my password management functions with
            -WarningAction SilentlyContinue but that doesn't seem to work. This is my work around
            for now.
    #>
    param (
        [ScriptBlock]$script
    )
    $oldWarningPref = $WarningPreference
    $WarningPreference = "SilentlyContinue"
    try {
        & $script
    }
    finally {
        $WarningPreference = $oldWarningPref
    }
}


function Invoke-MetasysMethod {
    <#
    .SYNOPSIS
        Sends an HTTPS request to a Metasys device running Metasys REST API

    .DESCRIPTION
        This function allows you to call methods of the Metasys REST API. Once a session is established (on the first invocation) the session state is maintained in the terminal session. This allows you to make additional calls with less boilerplate text necessary for each call.

    .OUTPUTS
        System.String
            The payloads from Metasys are formatted JSON strings. This is the default return type for this function.

        PSObject, Hashtable
            If the switch `ReturnBodyAsObject` is set then this function attempts to convert the response to a custom object. In some cases, the JSON string may contain properties that only differ in casing and can't be converted to a PSObject. In such cases, a Hashtable is returned instead. Note: This parameter only applies if the response content type is JSON. Otherwise it is ignored.

    .EXAMPLE
        Invoke-MetasysMethod /objects/$id

        Reads the default view of the specified object assuming $id contains a valid object identifier

    .EXAMPLE
        Invoke-MetasysMethod /alarms

        This will read the first page of alarms from the site.

    .EXAMPLE
        Invoke-MetasysMethod -Method Put /objects/$id/commands/adjust -Body '{ "parameters": [72.5] }'

        This example will send the adjust command to the specified object (assuming a valid id is stored in $id, and v4 of the API).

    .LINK

        https://github.com/metasys-server/powershell-metasysrestclient

    #>

    [CmdletBinding(PositionalBinding = $false)]
    param(
        # The relative or absolute url for an endpont. For example: /alarms
        # All of the urls are listed in the API Documentation
        [Parameter(Position = 0)]
        [string]$Path,
        # The payload to send with your request.
        #
        # Alias: -b
        [Parameter(ValueFromPipeline = $true)]
        [Alias("b")]
        [string]$Body,
        # The HTTP Method you are sending.
        #
        # Aliases: -m, -verb
        [Alias("verb", "m")]
        [Microsoft.PowerShell.Commands.WebRequestMethod]$Method = "Get",
        # The version of the API you intend to use. Typically you do not need to specify anything for this parameter as this command will use whatever version was specified when you ran `Connect-MetasysAccount`. However, you may wish to use this paramter if you want to invoke an operation at a different version than the one used to connect.
        #
        # Acceptable values: 2, 3, 4, 5
        # Alias: -v
        [Alias("v")]
        [string]$Version,
        # Skips certificate validation checks. This includes all validations
        # such as expiration, revocation, trusted root authority, etc.
        # [!WARNING] Using this parameter is not secure and is not recommended.
        # This switch is only intended to be used against known hosts using a
        # self-signed certificate for testing purposes. Use at your own risk.
        [switch]$SkipCertificateCheck,
        # A collection of headers to include in the request
        #
        # Alias: -h
        [Alias("h")]
        [hashtable]$Headers = @{},
        # Add support for password to be passed in
        #
        # Alias: -p
        [Alias("p")]
        [SecureString]$Password,
        # Return the response as PSObject or Hashtable instead of JSON string
        # Aliases: -o, -object
        [Alias("o", "object")]
        [Switch]$ReturnBodyAsObject,
        # Includes the response headers in the output
        #
        # Alias: -rh
        [Alias("rh")]
        [Switch]$IncludeResponseHeaders,

        # Add a subscription for this resource. Pass a `stream id` as the value
        # of this parameter. For example `0915342b-4557-401e-a061-237d0bced15d` (
        # assuming this is the stream id passed to you in the hello event of your stream
        # )
        #
        # This is identical to including `METASYS-SUBSCRIBE` in `Headers` parameter.
        # If you use both `Subscribe` and `Headers` the `Subscribe` parameter value is
        # used
        # Alias: s
        [Alias("s")]
        [Guid]$Subscribe
    )

    BEGIN {
        Set-Variable -Name fiveMinutes -Value ([TimeSpan]::FromMinutes(5)) -Option Constant

        setBackgroundColorsToMatchConsole


        assertPowershellCore

        if (!$Path) {
            Write-Information "Path not supplied. Please enter a path"
            $Path = Read-Host -Prompt "Path"
        }

        # Read SkipCertificateCheck from environment
        $SkipCertificateCheck = [MetasysEnvVars]::getSkipCertificateCheck()


        if (!$SkipCertificateCheck.IsPresent) {
            $SkipCertificateCheck = Get-MetasysSkipSecureCheckNotSecure
        }

        $uri = [Uri]::new($path, [UriKind]::RelativeOrAbsolute)
        if ($uri.IsAbsoluteUri) {
            $versionSegment = $uri.Segments[2]
            $versionNumber = $versionSegment.SubString(1, $versionSegment.Length - 2)
            if ($Version -ne "" -and $versionNumber -ne $Version) {
                Write-Error "An absolute url was given for Path and it specifies a version ('$versionNumber') that conflicts with Version ('$Version')"
                continue
            }
        }

        If ($Version -eq "") {
            # Use the version from last cma call, else the default api version (if set), else latest version
            $Version = $env:METASYS_VERSION ?? (Get-MetasysDefaultApiVersion) ?? (Get-MetasysLatestVersion)
            Write-Information "No version specified. Defaulting to v$Version"
        }

        # Login Region

        if ($null -eq ([MetasysEnvVars]::getToken()) ) {
            Write-Error "No connection to a Metasys site exists. Please connect using Connect-MetasysAccount"
            continue
        }
        else {
            if ([MetasysEnvVars]::getExpires()) {
                $expiration = [MetasysEnvVars]::getExpires()
                if ([DateTimeOffset]::UtcNow -gt $expiration) {
                    # Token is expired, attempt to connect with previously used site host and user name
                    try {
                        Write-Information "Session has expired. Trying to reconnect with this command:"
                        Write-Information "Connect-MetasysAccount -SiteHost $([MetasysEnvVars]::getSiteHost()) -UserName $([MetasysEnvVars]::getUserName()) -Version $($Version) `
-                         -SkipCertificateCheck:$($SkipCertificateCheck)"
                        Connect-MetasysAccount -SiteHost ([MetasysEnvVars]::getSiteHost()) -UserName ([MetasysEnvVars]::getUserName()) -Version $Version `
                            -SkipCertificateCheck:$SkipCertificateCheck
                    }
                    catch {
                        Write-Error "Session expired and attempt to re-connect failed"
                        continue
                    }
                }
                elseif ([DateTimeOffset]::UtcNow -gt ($expiration - $fiveMinutes)) {

                    # attempt to renew the token as it will expire soon
                    $uri = buildUri -siteHost ([MetasysEnvVars]::getSiteHost()) -version ([MetasysEnvVars]::getVersion()) -path "/refreshToken"
                    $refreshRequest = buildRequest -uri $uri -token ([MetasysEnvVars]::getToken()) -skipCertificateCheck:$SkipCertificateCheck

                    try {
                        Write-Information -Message "Attempting to refresh access token"
                        $refreshResponse = Invoke-RestMethod @refreshRequest
                        [MetasysEnvVars]::setExpires($refreshResponse.expires)
                        [MetasysEnvVars]::setTokenAsPlainText($refreshResponse.accessToken)
                        Write-Information -Message "Refresh token successful"
                    }
                    catch {
                        Write-Debug "Error attempting to refresh token"
                        Write-Debug $_
                        continue
                    }
                }
            }
        }
        $uri = buildUri -path $Path -version $Version -siteHost ([MetasysEnvVars]::getSiteHost())

    }

    # PROCESS block is needed if you accept input from pipeline like Body in this function
    PROCESS {

        if ($Subscribe) {
            $Headers['Metasys-Subscribe'] = $Subscribe
        }

        $request = buildRequest -uri $uri -method $Method -body $Body -token ([MetasysEnvVars]::getToken()) -skipCertificateCheck:$SkipCertificateCheck `
            -headers $Headers


        $response = $null
        $responseObject = $null

        Write-Information -Message "Attempting request"

        try {
            $responseObject = Invoke-WebRequest @request -SkipHttpErrorCheck
        }
        catch {
            # Catches errors like host name can't be found but not http errors like 4xx, 5xx due to SkipHttpErrorCheck above
            Write-Error $_
            return
        }

        $contentType = "unknown"; # one of json, text, unknown
        if ($responseObject) {

            $contentLength = 0
            [Int]::TryParse($responseObject.Headers["Content-Length"], [ref] $contentLength)  | Out-Null

            if ($responseObject.Headers["Content-Type"] -like "*json*" -or $contentLength -eq 0 -or $responseObject.StatusCode -eq 204 -or $responseObject.StatusCode -ge 400) {
                $contentType = "json"
            }
            elseif ($responseObject.Headers["Content-Type"] -like "text*") {
                $contentType = "text"
            }
            else {
                $contentType = "unknown"
                Write-Error "An unexpected content type was found"
                Write-Error (createErrorStringFromResponseObject -responseObject $responseObject)

            }
            if ($responseObject.Content -is [String]) {
                $response = $responseObject.Content
            }
            else {
                $response = [System.Text.Encoding]::UTF8.GetString($responseObject.Content)
            }
        }

        # Only overwrite the last response if $response is not null
        if ($null -ne $response -and $contentType -eq "json") {
            [MetasysEnvVars]::setLast($response)
            [MetasysEnvVars]::setHeaders($responseObject.Headers)
            [MetasysEnvVars]::setStatus($responseObject.StatusCode, $responseObject.StatusDescription)
        }

        if ($ReturnBodyAsObject.IsPresent -and $null -ne $response -and $contentType -eq "json") {
            Get-LastMetasysResponseBodyAsObject
        }
        elseif ($null -ne $response) {

            if ($contentType -eq "json") {
                if ($IncludeResponseHeaders) {
                    Show-LastMetasysFullResponse
                }
                else {
                    Show-LastMetasysResponseBody
                }
            }
            if ($contentType -eq "text") {

                if ($IncludeResponseHeaders) {
                    convertResponseObjectToString $responseObject
                }
                else {
                    $responseObject.Content
                }
            }

        }
    }

}



function Show-LastMetasysAccessToken {
    ConvertFrom-SecureString -AsPlainText -SecureString ([MetasysEnvVars]::getToken())
}

function Show-LastMetasysHeaders {

    $response = ""
    $headers = ConvertFrom-Json ([MetasysEnvVars]::getHeaders())
    foreach ($header in $headers.PSObject.Properties) {
        $response += "$($header.Name): $($header.Value -join ',')" + "`n"
    }
    $response
}

function Show-LastMetasysStatus {
    ([MetasysEnvVars]::getStatus())
}

function ConvertFrom-JsonSafely {
    param(
        [String]$json
    )

    # Always use -AsHashtable since we have some enum sets that
    # have keys that vary only in casing in the same enum set.
    try {
        ConvertFrom-Json -AsHashtable -InputObject $json
    }
    catch {
        # apparently this wasn't JSON so leave it as is
        $json
    }

}

function Show-LastMetasysResponseBody {
    $body = [MetasysEnvVars]::getLast()
    if ($body -and ($contentType -eq "json")) {
        ConvertFrom-JsonSafely $body | ConvertTo-Json -Depth 20
    }
}

function Show-LastMetasysFullResponse {
    "$(Show-LastMetasysStatus)`n$(Show-LastMetasysHeaders)`n$(Show-LastMetasysResponseBody)"
}

function Get-LastMetasysResponseBodyAsObject {
    ConvertFrom-JsonSafely ([MetasysEnvVars]::getLast())
}

function Get-LastMetasysHeadersAsObject {
    ConvertFrom-Json ([MetasysEnvVars]::getHeaders())
}

function Clear-MetasysEnvVariables {
    [MetasysEnvVars]::clear()
    "The environment variables related to the current Metasys sessions have been cleared."
}

Set-Alias -Name imm -Value Invoke-MetasysMethod

Export-ModuleMember -Function 'Invoke-MetasysMethod', 'Show-LastMetasysHeaders', 'Show-LastMetasysAccessToken', 'Show-LastMetasysResponseBody', 'Show-LastMetasysFullResponse', `
    'Get-LastMetasysResponseBodyAsObject', 'Show-LastMetasysStatus', 'Get-LastMetasysHeadersAsObject', 'Clear-MetasysEnvVariables'

Export-ModuleMember -Alias 'imm'

