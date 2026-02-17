<#
.SYNOPSIS
    Local test script for the Publish-*-Blog functions.
    Tests DEV.to API, blog selection, message composition, and character limits
    WITHOUT needing Azure Table Storage or any platform API credentials.

.DESCRIPTION
    Run this locally to verify:
    1. DEV.to API returns your blog posts
    2. Year exclusion filtering works
    3. Message composition fits within platform character limits
    4. Blog rotation picks different posts each run

    Supports testing message formats for: X (280 chars), LinkedIn (3000 chars)

.NOTES
    No Azure or platform credentials needed for this test.
    Run from PowerShell: .\Test-LocalDryRun.ps1
    Test LinkedIn format: .\Test-LocalDryRun.ps1 -Platform LinkedIn
    Test all platforms:   .\Test-LocalDryRun.ps1 -Platform All
#>

param(
    [string]$Username = 'pwd9000',
    [string]$ExcludeYears = '',        # e.g. '2024' or '2023, 2024'
    [int]$SimulateRuns = 5,            # How many random selections to simulate
    [ValidateSet('X', 'LinkedIn', 'All')]
    [string]$Platform = 'All'          # Which platform message format to test
)

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Publish-Blog - Local Dry Run Test" -ForegroundColor Cyan
Write-Host " Platform(s): $Platform" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: Test DEV.to API ---
Write-Host "[TEST 1] Fetching blogs from DEV.to API for user: $Username" -ForegroundColor Yellow
$uri = "https://dev.to/api/articles?username=$Username&per_page=1000"

try {
    $blogPosts = Invoke-RestMethod -Uri $uri -Method GET
    Write-Host "  OK - Retrieved $($blogPosts.Count) blog posts" -ForegroundColor Green
}
catch {
    Write-Host "  FAIL - Could not reach DEV.to API: $_" -ForegroundColor Red
    exit 1
}

# --- Step 2: Test year exclusion ---
Write-Host ""
Write-Host "[TEST 2] Year exclusion filter" -ForegroundColor Yellow

if ($ExcludeYears) {
    $yearsToExclude = $ExcludeYears.Split(', ') | ForEach-Object { $_.Trim() }
    $beforeCount = $blogPosts.Count
    $blogPosts = $blogPosts | Where-Object {
        $publishedYear = ([DateTime]$_.published_at).Year.ToString()
        $publishedYear -notin $yearsToExclude
    }
    $excludedCount = $beforeCount - $blogPosts.Count
    Write-Host "  Excluded $excludedCount blogs from year(s): $ExcludeYears" -ForegroundColor Green
    Write-Host "  Remaining: $($blogPosts.Count) blogs" -ForegroundColor Green
}
else {
    Write-Host "  No years excluded (excludeYears is empty)" -ForegroundColor DarkGray
}

# --- Step 3: Show year distribution ---
Write-Host ""
Write-Host "[TEST 3] Blog posts by year:" -ForegroundColor Yellow
$blogPosts | Group-Object { ([DateTime]$_.published_at).Year } | Sort-Object Name | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count) posts" -ForegroundColor Green
}

# --- Step 4: Simulate random selections and message composition ---
Write-Host ""
Write-Host "[TEST 4] Simulating $SimulateRuns random blog selections and message composition:" -ForegroundColor Yellow
Write-Host ""

$platformsToTest = if ($Platform -eq 'All') { @('X', 'LinkedIn') } else { @($Platform) }

$allIds = $blogPosts.id

for ($i = 1; $i -le $SimulateRuns; $i++) {
    $blogItem = Get-Random -Maximum $allIds.Count
    $blogDataId = $allIds[$blogItem]
    $blogData = $blogPosts | Where-Object { $_.id -eq $blogDataId }

    # Build hashtags (use -split for proper delimiter; remove hyphens which break hashtags)
    $hashtags = (($blogData.tags -split ',\s*') | Where-Object { $_ -ne '' } | ForEach-Object { '#' + ($_ -replace '-', '') }) -join ' '

    Write-Host "  --- Run $i ---" -ForegroundColor Cyan
    Write-Host "  Blog: $($blogData.title)" -ForegroundColor White
    Write-Host "  Published: $(([DateTime]$blogData.published_at).ToString('dd/MM/yyyy'))" -ForegroundColor DarkGray
    Write-Host "  URL: $($blogData.url)" -ForegroundColor DarkGray
    Write-Host "  Tags: $($blogData.tags)" -ForegroundColor DarkGray

    foreach ($plt in $platformsToTest) {
        switch ($plt) {
            'X' {
                # X message: max 280 weighted chars (URLs count as 23 via t.co)
                $tcoLength = 23
                $blogUrl = $blogData.url
                $twitterUsername = $blogData.user.twitter_username
                $textPrefix = "RT: $($blogData.title), by @$twitterUsername. $($hashtags) "
                $Message = $textPrefix + $blogUrl

                $weightedLength = $textPrefix.Length + $tcoLength

                $truncated = $false
                if ($weightedLength -gt 280) {
                    $availableTextLength = 280 - $tcoLength - 4
                    $truncatedPrefix = $textPrefix.Substring(0, $availableTextLength) + "... "
                    $Message = $truncatedPrefix + $blogUrl
                    $weightedLength = $truncatedPrefix.Length + $tcoLength
                    $truncated = $true
                }

                $color = if ($weightedLength -le 280) { 'Green' } else { 'Red' }
                $truncLabel = if ($truncated) { ' [TRUNCATED]' } else { '' }

                Write-Host ""
                Write-Host "  ┌─── X Post ─── (weighted: $weightedLength/280)$truncLabel" -ForegroundColor $color
                Write-Host "  │" -ForegroundColor DarkGray
                Write-Host "  │  $Message" -ForegroundColor White
                Write-Host "  │" -ForegroundColor DarkGray
                Write-Host "  └────────────────────────────────────────────" -ForegroundColor DarkGray
            }
            'LinkedIn' {
                # LinkedIn message: max 3000 chars + article preview
                # Merge dynamic blog tags + static tags, deduplicated (case-insensitive)
                $staticTags = @('GitHubCopilot', 'GenerativeAI', 'DevOps', 'MicrosoftMVP', 'MVPBuzz', 'AI', 'DevCommunity', 'TechCommunity', 'OpenSource', 'DevTo', 'CloudComputing')
                $blogTags = ($blogData.tags -split ',\s*') | Where-Object { $_ -ne '' } | ForEach-Object { $_ -replace '-', '' }
                $allTags = $blogTags + $staticTags
                $seen = @{}
                $uniqueTags = $allTags | Where-Object { $lower = $_.ToLower(); if (-not $seen[$lower]) { $seen[$lower] = $true; $true } else { $false } }
                $liHashtags = ($uniqueTags | ForEach-Object { '#' + $_ }) -join ' '

                $publishedDate = ([DateTime]$blogData.published_at).ToString('dd/MM/yyyy')
                $blogDescription = if ($blogData.description) { $blogData.description } else { '' }

                # Uses the same 5 rotating fun commentary templates as the live function
                $commentaryTemplates = @(
                    @"
Welcome aboard the AI-powered time machine! This week we're warping back to $publishedDate to revisit one of my popular blog posts from the archives: `"$($blogData.title)`"

$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogData.url)

$liHashtags
"@
                    ,
                    @"
Now playing on the DevOps Mixtape... A throwback track from $publishedDate that still slaps! Hit play and check out this banger from the blog archives: `"$($blogData.title)`"
$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogData.url)

$liHashtags
"@
                    ,
                    @"
BREAKING NEWS from the Dev Community! Our reporters have uncovered a blog post from $publishedDate that's still making waves today. Read all about it!

`"$($blogData.title)`"
$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogData.url)

$liHashtags
"@
                    ,
                    @"
Today's treasure from the blog vault! While digging through the archives, I unearthed this gem from $publishedDate. Dust it off and give it a read!

`"$($blogData.title)`"
$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogData.url)

$liHashtags
"@
                    ,
                    @"
BEEP BOOP! Your friendly neighbourhood blog bot here! My circuits have selected a post from $publishedDate for your reading pleasure. Enjoy, humans!

`"$($blogData.title)`"
$(if ($blogDescription) { "`n$blogDescription" })

Article URL: $($blogData.url)

$liHashtags
"@
                )

                $Commentary = $commentaryTemplates | Get-Random
                $Commentary = ($Commentary -split "`n" | Where-Object { $_.Trim() -ne '' }) -join "`n"

                $charCount = $Commentary.Length
                $color = if ($charCount -le 3000) { 'Green' } else { 'Red' }

                Write-Host ""
                Write-Host "  ┌─── LinkedIn Post ─── ($charCount/3000 chars)" -ForegroundColor $color
                Write-Host "  │" -ForegroundColor DarkGray
                $Commentary -split "`n" | ForEach-Object {
                    Write-Host "  │  $_" -ForegroundColor White
                }
                Write-Host "  │" -ForegroundColor DarkGray
                Write-Host "  │  ┌──────────────────────────────────────" -ForegroundColor DarkCyan
                Write-Host "  │  │  Article Preview" -ForegroundColor DarkCyan
                Write-Host "  │  │  $($blogData.title)" -ForegroundColor Cyan
                Write-Host "  │  │  $($blogData.url)" -ForegroundColor DarkGray
                Write-Host "  │  └──────────────────────────────────────" -ForegroundColor DarkCyan
                Write-Host "  │" -ForegroundColor DarkGray
                Write-Host "  └────────────────────────────────────────────" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""
}

# --- Step 5: Check for potential issues ---
Write-Host "[TEST 5] Checking for potential issues:" -ForegroundColor Yellow

# Check twitter_username
$sampleUser = $blogPosts[0].user.twitter_username
if ([string]::IsNullOrEmpty($sampleUser)) {
    Write-Host "  WARNING - twitter_username is empty in DEV.to profile. The @mention in posts will be blank." -ForegroundColor Red
}
else {
    Write-Host "  OK - twitter_username found: @$sampleUser" -ForegroundColor Green
}

# Check for posts with very long titles
$longTitlePosts = $blogPosts | Where-Object { $_.title.Length -gt 100 }
if ($longTitlePosts) {
    Write-Host "  INFO - $($longTitlePosts.Count) posts have titles > 100 chars (may trigger truncation)" -ForegroundColor DarkYellow
}
else {
    Write-Host "  OK - No excessively long titles found" -ForegroundColor Green
}

# Check for posts with no tags
$noTagPosts = $blogPosts | Where-Object { [string]::IsNullOrEmpty($_.tags) }
if ($noTagPosts) {
    Write-Host "  INFO - $($noTagPosts.Count) posts have no tags" -ForegroundColor DarkYellow
}
else {
    Write-Host "  OK - All posts have tags" -ForegroundColor Green
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " All local tests complete!" -ForegroundColor Cyan
Write-Host " Next steps:" -ForegroundColor Cyan
Write-Host "  1. Deploy to Azure with dryRun='true'" -ForegroundColor White
Write-Host "  2. Trigger function manually in Azure" -ForegroundColor White
Write-Host "  3. Check logs in Azure Portal" -ForegroundColor White
Write-Host "  4. Set dryRun='false' and test live" -ForegroundColor White
Write-Host "" -ForegroundColor White
Write-Host " Platform schedules:" -ForegroundColor Cyan
Write-Host "  X:        Wed 07:30 UTC (7:30 AM GMT), Thu 13:30 UTC" -ForegroundColor White
Write-Host "  LinkedIn: Mon 07:30 UTC (7:30 AM GMT / 8:30 AM BST)" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
