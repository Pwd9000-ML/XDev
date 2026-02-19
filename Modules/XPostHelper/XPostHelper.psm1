<#
.SYNOPSIS
    Shared helper module for posting blog content to X (formerly Twitter).

.DESCRIPTION
    Provides Send-XPost (OAuth 1.0a API v2 posting) and Invoke-XBlogPost
    (end-to-end blog selection, message composition, and posting) used by
    the Publish-X-Blog-UK and Publish-X-Blog-US Azure Functions.

    This module is loaded automatically via profile.ps1 on cold start.
    It depends on the BlogHelper module (Get-Blog) for blog selection
    and rotation tracking.

.NOTES
    X API credentials are read from Azure Function App Settings (env vars).
    Tracker table: 'blogtracker' | Partition: 'Posted-X'
#>

#region Send-XPost - Post to X (formerly Twitter) using API v2 with OAuth 1.0a
function Send-XPost {
    <#
    .SYNOPSIS
        Posts a message to X (formerly Twitter) using the v2 API (POST /2/tweets).
    .DESCRIPTION
        Implements OAuth 1.0a HMAC-SHA1 signing to authenticate against the X API v2.
        This replaces the deprecated PSTwitterAPI module and v1.1 statuses/update endpoint.
    .PARAMETER Message
        The text content of the post (max 280 characters).
    .PARAMETER ApiKey
        X API Consumer Key (also called API Key).
    .PARAMETER ApiSecret
        X API Consumer Secret (also called API Secret).
    .PARAMETER AccessToken
        OAuth 1.0a Access Token for the user posting.
    .PARAMETER AccessTokenSecret
        OAuth 1.0a Access Token Secret for the user posting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 280)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$ApiKey,

        [Parameter(Mandatory)]
        [string]$ApiSecret,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$AccessTokenSecret
    )

    $ErrorActionPreference = 'Stop'

    # X API v2 endpoint for creating posts
    $apiUrl = 'https://api.x.com/2/tweets'
    $httpMethod = 'POST'

    # --- OAuth 1.0a Signature Generation ---

    # Helper: Percent-encode per RFC 5849
    function Get-OAuthPercentEncode {
        param([string]$Value)
        $encoded = [System.Uri]::EscapeDataString($Value)
        # EscapeDataString doesn't encode some chars that OAuth requires
        $encoded = $encoded.Replace('!', '%21').Replace('*', '%2A').Replace("'", '%27').Replace('(', '%28').Replace(')', '%29')
        return $encoded
    }

    # Generate nonce (random alphanumeric string)
    $oauthNonce = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes([System.Guid]::NewGuid().ToString())) -replace '[^a-zA-Z0-9]', ''

    # Generate timestamp (Unix epoch seconds)
    $epochStart = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $oauthTimestamp = [Math]::Floor(([DateTime]::UtcNow - $epochStart).TotalSeconds).ToString()

    # OAuth parameters (sorted alphabetically by key for signature base string)
    $oauthParams = [ordered]@{
        oauth_consumer_key     = $ApiKey
        oauth_nonce            = $oauthNonce
        oauth_signature_method = 'HMAC-SHA1'
        oauth_timestamp        = $oauthTimestamp
        oauth_token            = $AccessToken
        oauth_version          = '1.0'
    }

    # Build parameter string (sorted by key, percent-encoded)
    $paramString = ($oauthParams.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$(Get-OAuthPercentEncode $_.Key)=$(Get-OAuthPercentEncode $_.Value)"
    }) -join '&'

    # Build signature base string: METHOD&URL&PARAMS
    $signatureBaseString = "$httpMethod&$(Get-OAuthPercentEncode $apiUrl)&$(Get-OAuthPercentEncode $paramString)"

    # Build signing key: ConsumerSecret&TokenSecret
    $signingKey = "$(Get-OAuthPercentEncode $ApiSecret)&$(Get-OAuthPercentEncode $AccessTokenSecret)"

    # Compute HMAC-SHA1 signature
    $hmacsha1 = New-Object System.Security.Cryptography.HMACSHA1
    $hmacsha1.Key = [System.Text.Encoding]::ASCII.GetBytes($signingKey)
    $oauthSignature = [System.Convert]::ToBase64String($hmacsha1.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($signatureBaseString)))

    # Build Authorization header
    $authHeader = "OAuth " +
        "oauth_consumer_key=`"$(Get-OAuthPercentEncode $ApiKey)`", " +
        "oauth_nonce=`"$(Get-OAuthPercentEncode $oauthNonce)`", " +
        "oauth_signature=`"$(Get-OAuthPercentEncode $oauthSignature)`", " +
        "oauth_signature_method=`"HMAC-SHA1`", " +
        "oauth_timestamp=`"$oauthTimestamp`", " +
        "oauth_token=`"$(Get-OAuthPercentEncode $AccessToken)`", " +
        "oauth_version=`"1.0`""

    # --- Send the Post ---

    $jsonBody = @{ text = $Message } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Body $jsonBody -ContentType 'application/json' -Headers @{
        Authorization = $authHeader
    }

    Write-Host "Successfully posted to X! Post ID: $($response.data.id)"
    return $response
}
#endregion

#region Invoke-XBlogPost - End-to-end blog selection, message composition, and posting to X
function Invoke-XBlogPost {
    <#
    .SYNOPSIS
        Selects a random blog post, composes a message, and posts it to X.

    .DESCRIPTION
        Orchestrates the full X posting workflow:
        1. Selects a random blog via Get-Blog (BlogHelper module) with rotation tracking.
        2. Builds hashtags from blog tags.
        3. Composes a 280-char message with t.co-aware truncation.
        4. Posts via Send-XPost (or logs output in dry-run mode).
        5. Logs any failures to Azure Table Storage.

        All configuration is read from Azure Function App Settings (env vars).
    #>
    [CmdletBinding()]
    param()

    # Import AzTable module for Azure Table Storage operations
    Import-Module AzTable

    # Set these environment variables in Azure Function App Settings:
    # DEV.to and Azure Storage
    $URI = $env:DevURI                             # e.g. "https://dev.to/api/articles?username=pwd9000&per_page=1000"
    $resourceGroupName = $env:Function_RGName       # Resource group containing the storage account
    $storageAccountName = $env:Function_SaActName   # Storage account name for tracking
    $excludeIds = $env:excludeBlogIds               # e.g. "1234, 1235, 1236"
    $excludeYears = $env:excludeBlogYears            # e.g. "2024" or "2023, 2024"

    # Dry-run mode: set to "true" to test without posting to X (no credits used)
    $dryRun = $env:dryRun                           # e.g. "true" to skip posting

    # X (formerly Twitter) API credentials - from X Developer Console (console.x.com)
    $xApiKey = $env:xApiKey                         # Consumer Key (API Key)
    $xApiSecret = $env:xApiSecret                   # Consumer Secret (API Secret)
    $xAccessToken = $env:xAccessToken               # Access Token (generate under "Authentication Tokens")
    $xAccessTokenSecret = $env:xAccessTokenSecret   # Access Token Secret (generate under "Authentication Tokens")

    ## Status tracking
    $statusGood = $true

    try {
        # 1. Select a random blog post (with rotation)
        [PSCustomObject]$blogToPost = Get-Blog -URI $URI -resourceGroupName $resourceGroupName -storageAccountName $storageAccountName -platform 'X' -excludeIds $excludeIds -excludeYears $excludeYears

        # 2. Build hashtags from blog tags (use -split for proper delimiter; remove hyphens which break hashtags)
        $hashtags = (($blogToPost.tags -split ',\s*') | Where-Object { $_ -ne '' } | ForEach-Object { '#' + ($_ -replace '-', '') }) -join ' '

        # 3. Compose the post message (max 280 chars for X)
        # X wraps all URLs via t.co, which always counts as 23 characters
        # regardless of actual URL length. We use this for accurate truncation.
        $tcoLength = 23  # t.co wrapped URL always counts as 23 chars

        $blogUrl = $blogToPost.url
        # Use twitter_username from DEV.to profile (field still named twitter_username in DEV.to API)
        $textPrefix = "RT: $($blogToPost.title), by @$($blogToPost.user.twitter_username). $($hashtags) "
        $Message = $textPrefix + $blogUrl

        # Calculate weighted length: text portion (actual chars) + URL (23 chars for t.co)
        $weightedLength = $textPrefix.Length + $tcoLength
        Write-Host "Weighted character count: $weightedLength / 280 (URL counts as $tcoLength via t.co)"

        # Truncate if weighted length exceeds 280 characters (preserve URL at end)
        if ($weightedLength -gt 280) {
            $availableTextLength = 280 - $tcoLength - 4  # 4 for "... "
            $truncatedPrefix = $textPrefix.Substring(0, $availableTextLength) + "... "
            $Message = $truncatedPrefix + $blogUrl
            $weightedLength = $truncatedPrefix.Length + $tcoLength
            Write-Host "Message truncated to fit 280 character limit (weighted: $weightedLength)."
        }

        Write-Host "Posting to X: $Message"
        Write-Host "Actual message length: $($Message.Length) chars | Weighted (t.co): $weightedLength / 280"

        # 4. Post to X using API v2 with OAuth 1.0a (skip if dry-run)
        if ($dryRun -eq 'true') {
            Write-Host "=== DRY RUN MODE === Post NOT sent to X. Message that would be posted:"
            Write-Host $Message
            Write-Host "Blog title: $($blogToPost.title)"
            Write-Host "Blog URL: $($blogToPost.url)"
            Write-Host "Blog tags: $($blogToPost.tags)"
            Write-Host "Published: $($blogToPost.published_at)"
            Write-Host "=== DRY RUN COMPLETE ==="
        }
        else {
            Send-XPost -Message $Message `
                -ApiKey $xApiKey `
                -ApiSecret $xApiSecret `
                -AccessToken $xAccessToken `
                -AccessTokenSecret $xAccessTokenSecret
        }

    }
    catch {
        $statusGood = $false
        $statusMessage = "Post to X Failed: $_"

        # Log failure to Azure Table Storage
        try {
            $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
            $storageContext = $storageAccount.Context
            $cloudTable = (Get-AzStorageTable -Name 'failed' -Context $storageContext).CloudTable
            $null = Add-AzTableRow -table $cloudTable -partitionKey 'Fail-X' -rowKey "$statusMessage -- [$Message]"
        }
        catch {
            Write-Error "Failed to log error to table storage: $($_.Exception.Message)"
        }
    }

    if ($statusGood) {
        $statusMessage = "Everything Ran OK"
    }

    Write-Host "$statusMessage"
}
#endregion

Export-ModuleMember -Function Send-XPost, Invoke-XBlogPost
