# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format.
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# ============================================================================
# SCHEDULE GUARD - Only post on the intended day/time slots:
#   - Wednesday 08:30 UTC (EU morning peak)
#   - Thursday  13:30 UTC (US morning peak / EU afternoon)
# The CRON fires at 08:30 and 13:30 on both Wed & Thu (4 times).
# This guard skips the 2 unintended slots (Wed 13:30 and Thu 08:30).
# Uses a 15-minute grace window to account for cold-start delays.
# ============================================================================
$utcDay = $currentUTCtime.DayOfWeek
$utcTotalMinutes = $currentUTCtime.Hour * 60 + $currentUTCtime.Minute
$graceMinutes = 15  # Allow up to 15 minutes late from cold start

$scheduledSlots = @(
    @{ Day = 'Wednesday'; Minutes = 510 }   # 08:30 UTC (8*60+30=510) → EU morning
    @{ Day = 'Thursday';  Minutes = 810 }   # 13:30 UTC (13*60+30=810) → US morning
)

$isScheduledSlot = $scheduledSlots | Where-Object {
    $_.Day -eq $utcDay -and
    $utcTotalMinutes -ge $_.Minutes -and
    $utcTotalMinutes -le ($_.Minutes + $graceMinutes)
}

if (-not $isScheduledSlot) {
    Write-Host "Skipping: Not a scheduled posting slot ($utcDay $($currentUTCtime.ToString('HH:mm')) UTC). Active slots: Wed 08:30, Thu 13:30 UTC (±${graceMinutes}min grace)."
    return
}

Write-Host "Active posting slot: $utcDay $($currentUTCtime.ToString('HH:mm')) UTC"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

#region Get-Blog - Select a random blog post with rotation tracking via Azure Table Storage
function Get-Blog {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]
        [string]$URI,
        [Parameter(Mandatory)]
        [string]$resourceGroupName,
        [Parameter(Mandatory)]
        [string]$storageAccountName,
        [Parameter(Mandatory = $false)]
        [string]$tableName = 'blogs',
        [Parameter(Mandatory = $false)]
        [string]$tablePartition = 'Blog-ID',
        [Parameter(Mandatory = $false)]
        [string]$excludeIds = $null,
        [Parameter(Mandatory = $false)]
        [string]$excludeYears = $null
    )

    # Excluded posts (Not wanted in posts)
    if ($excludeIds) {
        $excludeBlogIds = $excludeIds.Split(', ')
    }
    else {
        $excludeBlogIds = $null
    }

    # Connect to Az Table Storage to check tracking (Already posted)
    try {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
        $storageContext = $storageAccount.Context
        $cloudTable = (Get-AzStorageTable -Name $tableName -Context $storageContext).CloudTable
        $records = Get-AzTableRow -table $cloudTable -PartitionKey $tablePartition
    }
    catch {
        Write-Error $_.Exception.Message
    }

    if ($records) {
        $blogPreCalledIds = $records | Select-Object -ExpandProperty RowKey
    }
    else {
        $blogPreCalledIds = $null
    }

    # Add exclusions if any (by blog ID, comma separated)
    foreach ($id in $excludeBlogIds) {
        if ($blogPreCalledIds -notcontains $id) {
            Write-Host "$id not in tracker, adding to tracker to exclude"
            $null = Add-AzTableRow -table $cloudTable -partitionKey $tablePartition -rowKey $id
            $blogPreCalledIds += $id
        }
        else {
            Write-Host "$id in tracker, and will be excluded"
        }
    }

    # Call DEV.to API to get all posts
    $blogPosts = Invoke-RestMethod -Uri $URI -Method GET

    # Exclude entire years if specified (e.g. "2023, 2024")
    if ($excludeYears) {
        $yearsToExclude = $excludeYears.Split(', ') | ForEach-Object { $_.Trim() }
        $beforeCount = $blogPosts.Count
        $blogPosts = $blogPosts | Where-Object {
            $publishedYear = ([DateTime]$_.published_at).Year.ToString()
            $publishedYear -notin $yearsToExclude
        }
        $excludedCount = $beforeCount - $blogPosts.Count
        Write-Host "Excluded $excludedCount blogs from year(s): $excludeYears"
    }

    if ($null -ne $blogPreCalledIds) {
        $availableBlogIds = Compare-Object -ReferenceObject ($blogPosts.id) -DifferenceObject $blogPreCalledIds -PassThru
    }
    else {
        $availableBlogIds = $blogPosts.id
    }

    $blogCount = $availableBlogIds.Count
    Write-Output "$blogCount blogs left to post on X"

    # Reset rotation when only 1 blog left
    $Reset = ($blogCount -eq 1)

    if ($Reset) {
        try {
            $records | Remove-AzTableRow -table $cloudTable -Verbose
            $records = $null
        }
        catch {
            Write-Error $_.Exception.Message
        }
    }

    # Select a random blog from available entries
    $blogItem = Get-Random -Maximum $blogCount
    $blogDataId = $availableBlogIds[$blogItem]
    $blogData = $blogPosts | Where-Object { $_.id -eq $blogDataId }

    # Track selection in table storage
    try {
        $null = Add-AzTableRow -table $cloudTable -partitionKey $tablePartition -rowKey $blogDataId
    }
    catch {
        Write-Error $_.Exception.Message
    }

    return $blogData
}
#endregion

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

# ============================================================================
# MAIN EXECUTION
# ============================================================================

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
    [PSCustomObject]$blogToPost = Get-Blog -URI $URI -resourceGroupName $resourceGroupName -storageAccountName $storageAccountName -excludeIds $excludeIds -excludeYears $excludeYears

    # 2. Build hashtags from blog tags
    $hashtags = ''
    $blogToPost.tags.Split(', ') | ForEach-Object {
        $tag = $_
        $hashtags += (' #' + $tag)
    }
    $hashtags = $hashtags.Trim()

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
        $null = Add-AzTableRow -table $cloudTable -partitionKey 'Blog-Fail' -rowKey "$statusMessage -- [$Message]"
    }
    catch {
        Write-Error "Failed to log error to table storage: $($_.Exception.Message)"
    }
}

if ($statusGood) {
    $statusMessage = "Everything Ran OK"
}

Write-Host "$statusMessage"