# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format.
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# ============================================================================
# SCHEDULE GUARD - Only post on the intended day/time slot:
#   - Monday  07:30 UTC (UK morning 7:30 AM GMT / 8:30 AM BST)
# The CRON fires at 07:30 on Monday only, so this guard is a safety net.
# Uses a 15-minute grace window to account for cold-start delays.
#
# Set App Setting 'forceRun' to 'true' to bypass the schedule guard
# for manual/test runs. Remember to set it back to 'false' afterwards.
# ============================================================================
$forceRun = $env:forceRun

if ($forceRun -eq 'true') {
    Write-Host "forceRun=true → Schedule guard BYPASSED. Running immediately."
}
else {
    $utcDay = $currentUTCtime.DayOfWeek
    $utcTotalMinutes = $currentUTCtime.Hour * 60 + $currentUTCtime.Minute
    $graceMinutes = 15  # Allow up to 15 minutes late from cold start

    $scheduledSlots = @(
        @{ Day = 'Monday'; Minutes = 450 }   # 07:30 UTC (7*60+30=450) → UK morning
    )

    $isScheduledSlot = $scheduledSlots | Where-Object {
        $_.Day -eq $utcDay -and
        $utcTotalMinutes -ge $_.Minutes -and
        $utcTotalMinutes -le ($_.Minutes + $graceMinutes)
    }

    if (-not $isScheduledSlot) {
        Write-Host "Skipping: Not a scheduled posting slot ($utcDay $($currentUTCtime.ToString('HH:mm')) UTC). Active slot: Mon 07:30 UTC (±${graceMinutes}min grace)."
        return
    }

    Write-Host "Active posting slot: $utcDay $($currentUTCtime.ToString('HH:mm')) UTC"
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Get-Blog is provided by the shared BlogHelper module (Modules/BlogHelper/BlogHelper.psm1)
# Loaded automatically via profile.ps1 on cold start.
# Tracker table: 'blogtracker' | Partition: 'Posted-LinkedIn'

#region Send-LinkedInPost - Post to LinkedIn using REST API with OAuth 2.0
function Send-LinkedInPost {
    <#
    .SYNOPSIS
        Posts content to LinkedIn using the Community Management REST API.

    .DESCRIPTION
        Creates a post on LinkedIn with an article link preview using OAuth 2.0
        Bearer token authentication. Uses the versioned REST API (rest/posts).

        Prerequisites:
        1. Create a LinkedIn App at https://www.linkedin.com/developers/apps
        2. Under "Products", request access to "Share on LinkedIn" and
           "Sign In with LinkedIn using OpenID Connect"
        3. Under "Auth" tab, add the OAuth 2.0 scopes: w_member_social, openid, profile
        4. Generate an OAuth 2.0 access token via the 3-legged OAuth flow
        5. Store credentials in Azure Function App Settings

        To find your Person URN:
        - Use the token to call: GET https://api.linkedin.com/v2/userinfo
        - Your person URN is: urn:li:person:{sub}

        IMPORTANT - Token Expiry:
        LinkedIn access tokens expire after 60 days (or 365 days for some apps).
        For long-running automation, you have two options:
        a) Use a refresh token flow to auto-renew (recommended)
        b) Manually regenerate the token every ~60 days

    .PARAMETER Commentary
        The text content of the LinkedIn post (max 3000 characters).

    .PARAMETER ArticleUrl
        The URL of the article to share (appears as rich link preview).

    .PARAMETER ArticleTitle
        Title for the article link preview.

    .PARAMETER ArticleDescription
        Optional description for the article link preview.

    .PARAMETER AccessToken
        LinkedIn OAuth 2.0 Bearer access token.

    .PARAMETER PersonUrn
        LinkedIn person URN in format "urn:li:person:{id}".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateLength(1, 3000)]
        [string]$Commentary,

        [Parameter(Mandatory)]
        [string]$ArticleUrl,

        [Parameter(Mandatory)]
        [string]$ArticleTitle,

        [Parameter(Mandatory = $false)]
        [string]$ArticleDescription = '',

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$PersonUrn
    )

    $ErrorActionPreference = 'Stop'

    # LinkedIn REST API endpoint for creating posts (versioned API)
    $apiUrl = 'https://api.linkedin.com/rest/posts'

    # Build post body with article content (shows as rich link preview in feed)
    $postBody = @{
        author         = $PersonUrn
        commentary     = $Commentary
        visibility     = 'PUBLIC'
        distribution   = @{
            feedDistribution               = 'MAIN_FEED'
            targetEntities                 = @()
            thirdPartyDistributionChannels = @()
        }
        content        = @{
            article = @{
                source      = $ArticleUrl
                title       = $ArticleTitle
                description = $ArticleDescription
            }
        }
        lifecycleState = 'PUBLISHED'
    }

    $jsonBody = $postBody | ConvertTo-Json -Depth 5

    $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Body $jsonBody -ContentType 'application/json' -Headers @{
        'Authorization'             = "Bearer $AccessToken"
        'LinkedIn-Version'          = '202401'
        'X-Restli-Protocol-Version' = '2.0.0'
    }

    Write-Host "Successfully posted to LinkedIn!"
    return $response
}
#endregion

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Import AzTable module for Azure Table Storage operations
Import-Module AzTable

# Set these environment variables in Azure Function App Settings:
# DEV.to and Azure Storage (shared across all platform functions)
$URI = $env:DevURI                             # e.g. "https://dev.to/api/articles?username=pwd9000&per_page=1000"
$resourceGroupName = $env:Function_RGName       # Resource group containing the storage account
$storageAccountName = $env:Function_SaActName   # Storage account name for tracking
$excludeIds = $env:excludeBlogIds               # e.g. "1234, 1235, 1236"
$excludeYears = $env:excludeBlogYears            # e.g. "2024" or "2023, 2024"

# Dry-run mode: set to "true" to test without posting to LinkedIn (no API calls)
$dryRun = $env:dryRun                           # e.g. "true" to skip posting

# LinkedIn API credentials - from LinkedIn Developer Console (linkedin.com/developers)
$linkedInAccessToken = $env:linkedInAccessToken   # OAuth 2.0 Bearer access token
$linkedInPersonUrn = $env:linkedInPersonUrn       # e.g. "urn:li:person:AbCdEf123"

## Status tracking
$statusGood = $true

try {
    # 1. Select a random blog post (with rotation tracking for LinkedIn)
    [PSCustomObject]$blogToPost = Get-Blog -URI $URI -resourceGroupName $resourceGroupName -storageAccountName $storageAccountName -platform 'LinkedIn' -excludeIds $excludeIds -excludeYears $excludeYears

    # 2. Build hashtags from blog tags + static tags, deduplicated (case-insensitive)
    $staticTags = @('GitHubCopilot', 'GenerativeAI', 'DevOps', 'MicrosoftMVP', 'MVPBuzz', 'AI', 'DevCommunity', 'TechCommunity', 'OpenSource', 'DevTo', 'CloudComputing')
    $blogTags = ($blogToPost.tags -split ',\s*') | Where-Object { $_ -ne '' } | ForEach-Object { $_ -replace '-', '' }
    $allTags = $blogTags + $staticTags
    $seen = @{}
    $uniqueTags = $allTags | Where-Object { $lower = $_.ToLower(); if (-not $seen[$lower]) { $seen[$lower] = $true; $true } else { $false } }
    $hashtags = ($uniqueTags | ForEach-Object { '#' + $_ }) -join ' '

    # 3. Compose LinkedIn post (max 3000 chars — much more room than X!)
    # Uses 5 rotating fun commentary templates to keep posts fresh and engaging.
    $publishedDate = ([DateTime]$blogToPost.published_at).ToString('dd/MM/yyyy')
    $blogDescription = if ($blogToPost.description) { $blogToPost.description } else { '' }

    $commentaryTemplates = @(
        @"
Welcome aboard the AI-powered time machine! This week we're warping back to $publishedDate to revisit one of my popular blog posts from the archives.

`"$($blogToPost.title)`"
$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogToPost.url)

$hashtags
"@
        ,
        @"
Now playing on the DevOps Mixtape... A throwback track from $publishedDate that still slaps! Hit play and check out this banger from the blog archives.

`"$($blogToPost.title)`"
$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogToPost.url)

$hashtags
"@
        ,
        @"
BREAKING NEWS from the Dev Community! Our reporters have uncovered a blog post from $publishedDate that's still making waves today. Read all about it!

`"$($blogToPost.title)`"
$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogToPost.url)

$hashtags
"@
        ,
        @"
Today's treasure from the blog vault! While digging through the archives, I unearthed this gem from $publishedDate. Dust it off and give it a read!

`"$($blogToPost.title)`"
$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogToPost.url)

$hashtags
"@
        ,
        @"
BEEP BOOP! Your friendly neighbourhood blog bot here! My circuits have selected a post from $publishedDate for your reading pleasure. Enjoy, humans!

`"$($blogToPost.title)`"
$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogToPost.url)

$hashtags
"@
    )

    # Pick a random template and clean up any blank lines from empty conditional fields
    $Commentary = $commentaryTemplates | Get-Random
    $Commentary = ($Commentary -split "`n" | Where-Object { $_.Trim() -ne '' }) -join "`n"

    $ArticleUrl = $blogToPost.url
    $ArticleTitle = $blogToPost.title
    $ArticleDescription = if ($blogToPost.description) { $blogToPost.d 3000"

    # 4. Post to LinkedIn (skip if dry-run)
    if ($dryRun -eq 'true') {
        Write-Host "=== DRY RUN MODE === Post NOT sent to LinkedIn. Message that would be posted:"
        Write-Host "Commentary: $Commentary"
        Write-Host "Article URL: $ArticleUrl"
        Write-Host "Article Title: $ArticleTitle"
        Write-Host "Article Description: $ArticleDescription"
        Write-Host "Blog tags: $($blogToPost.tags)"
        Write-Host "Published: $($blogToPost.published_at)"
        Write-Host "=== DRY RUN COMPLETE ==="
    }
    else {
        Send-LinkedInPost -Commentary $Commentary `
            -ArticleUrl $ArticleUrl `
            -ArticleTitle $ArticleTitle `
            -ArticleDescription $ArticleDescription `
            -AccessToken $linkedInAccessToken `
            -PersonUrn $linkedInPersonUrn
    }

}
catch {
    $statusGood = $false
    $statusMessage = "Post to LinkedIn Failed: $_"

    # Log failure to Azure Table Storage
    try {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
        $storageContext = $storageAccount.Context
        $cloudTable = (Get-AzStorageTable -Name 'failed' -Context $storageContext).CloudTable
        $null = Add-AzTableRow -table $cloudTable -partitionKey 'Fail-LinkedIn' -rowKey "$statusMessage -- [$Commentary]"
    }
    catch {
        Write-Error "Failed to log error to table storage: $($_.Exception.Message)"
    }
}

if ($statusGood) {
    $statusMessage = "Everything Ran OK"
}

Write-Host "$statusMessage"
