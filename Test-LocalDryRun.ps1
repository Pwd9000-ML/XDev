<#
.SYNOPSIS
    Local test script for the Publish-X-Blog function.
    Tests DEV.to API, blog selection, message composition, and character limits
    WITHOUT needing Azure Table Storage or X API credits.

.DESCRIPTION
    Run this locally to verify:
    1. DEV.to API returns your blog posts
    2. Year exclusion filtering works
    3. Message composition fits within 280 chars
    4. Blog rotation picks different posts each run

.NOTES
    No Azure or X credentials needed for this test.
    Run from PowerShell: .\Test-LocalDryRun.ps1
#>

param(
    [string]$Username = 'pwd9000',
    [string]$ExcludeYears = '',        # e.g. '2024' or '2023, 2024'
    [int]$SimulateRuns = 5              # How many random selections to simulate
)

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Publish-X-Blog - Local Dry Run Test" -ForegroundColor Cyan
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

$allIds = $blogPosts.id

for ($i = 1; $i -le $SimulateRuns; $i++) {
    $blogItem = Get-Random -Maximum $allIds.Count
    $blogDataId = $allIds[$blogItem]
    $blogData = $blogPosts | Where-Object { $_.id -eq $blogDataId }

    # Build hashtags
    $hashtags = ''
    $blogData.tags.Split(', ') | ForEach-Object {
        $hashtags += (' #' + $_)
    }
    $hashtags = $hashtags.Trim()

    # Build message (X wraps URLs via t.co = always 23 chars)
    $tcoLength = 23
    $blogUrl = $blogData.url
    $twitterUsername = $blogData.user.twitter_username
    $textPrefix = "RT: $($blogData.title), by @$twitterUsername. $($hashtags) "
    $Message = $textPrefix + $blogUrl

    # Calculate weighted length: text (actual) + URL (23 chars for t.co)
    $weightedLength = $textPrefix.Length + $tcoLength

    # Truncate if weighted length exceeds 280
    $truncated = $false
    if ($weightedLength -gt 280) {
        $availableTextLength = 280 - $tcoLength - 4  # 4 for "... "
        $truncatedPrefix = $textPrefix.Substring(0, $availableTextLength) + "... "
        $Message = $truncatedPrefix + $blogUrl
        $weightedLength = $truncatedPrefix.Length + $tcoLength
        $truncated = $true
    }

    # Status color based on weighted length
    $charCount = $Message.Length
    if ($weightedLength -le 280) { $color = 'Green' } else { $color = 'Red' }

    Write-Host "  --- Run $i ---" -ForegroundColor Cyan
    Write-Host "  Blog: $($blogData.title)" -ForegroundColor White
    Write-Host "  Published: $($blogData.published_at)" -ForegroundColor DarkGray
    Write-Host "  URL: $blogUrl" -ForegroundColor DarkGray
    Write-Host "  Tags: $($blogData.tags)" -ForegroundColor DarkGray
    Write-Host "  Message (weighted: $weightedLength/280, actual: $charCount chars)$(if($truncated){' [TRUNCATED]'}):" -ForegroundColor $color
    Write-Host "  $Message" -ForegroundColor White
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
Write-Host "  4. Buy credits, set dryRun='false', test live" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
