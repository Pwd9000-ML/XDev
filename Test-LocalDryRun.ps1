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

    # Build hashtags
    $hashtags = ''
    $blogData.tags.Split(', ') | ForEach-Object {
        $hashtags += (' #' + $_)
    }
    $hashtags = $hashtags.Trim()

    Write-Host "  --- Run $i ---" -ForegroundColor Cyan
    Write-Host "  Blog: $($blogData.title)" -ForegroundColor White
    Write-Host "  Published: $($blogData.published_at)" -ForegroundColor DarkGray
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

                $charCount = $Message.Length
                $color = if ($weightedLength -le 280) { 'Green' } else { 'Red' }

                Write-Host "  [X] (weighted: $weightedLength/280, actual: $charCount chars)$(if($truncated){' [TRUNCATED]'}):" -ForegroundColor $color
                Write-Host "  $Message" -ForegroundColor White
            }
            'LinkedIn' {
                # LinkedIn message: max 3000 chars + article preview
                # Uses the same 6 rotating commentary templates as the live function
                $blogDescription = if ($blogData.description) { $blogData.description } else { '' }
                $readingTime = if ($blogData.reading_time_minutes) { "$($blogData.reading_time_minutes) min read" } else { '' }
                $reactions = if ($blogData.positive_reactions_count -gt 0) { "$($blogData.positive_reactions_count) reactions" } else { '' }

                $commentaryTemplates = @(
                    @"
I wrote a blog on this topic and wanted to share it with the community!

$($blogData.title)

$(if ($blogDescription) { "$blogDescription" })
$(if ($readingTime) { "[$readingTime]" })

$hashtags #MicrosoftMVP #Azure #DevCommunity
"@
                    ,
                    @"
One of my favourite blog posts! Have you seen this one yet?

$($blogData.title)

$(if ($blogDescription) { "$blogDescription" })
$(if ($readingTime) { "[$readingTime]" })

If you find this useful, feel free to share it with your network!

$hashtags #MicrosoftMVP #DevCommunity #TechCommunity
"@
                    ,
                    @"
Sharing some knowledge with the community today!

$($blogData.title)

$(if ($blogDescription) { "$blogDescription" })
$(if ($readingTime) { "[$readingTime]" })

I'd love to hear your thoughts - drop a comment below!

$hashtags #MicrosoftMVP #Azure #DeveloperProductivity
"@
                    ,
                    @"
This is a topic I'm really passionate about, and I put together a detailed blog post on it.

$($blogData.title)

$(if ($blogDescription) { "$blogDescription" })
$(if ($readingTime) { "[$readingTime]" })

Hope this helps someone out there - happy learning!

$hashtags #MicrosoftMVP #DevCommunity #MVPBuzz
"@
                    ,
                    @"
If you're looking to level up your skills, check out this blog post I wrote!

$($blogData.title)

$(if ($blogDescription) { "$blogDescription" })
$(if ($readingTime) { "[$readingTime]" })

Let me know what you think in the comments.

$hashtags #MicrosoftMVP #Azure #TechCommunity
"@
                    ,
                    @"
I recently shared this blog, and the response has been amazing! If you missed it, here it is:

$($blogData.title)

$(if ($blogDescription) { "$blogDescription" })
$(if ($readingTime -and $reactions) { "[$readingTime | $reactions]" } elseif ($readingTime) { "[$readingTime]" })

$hashtags #MicrosoftMVP #DevCommunity #LearnInPublic
"@
                )

                $Commentary = $commentaryTemplates | Get-Random
                $Commentary = ($Commentary -split "`n" | Where-Object { $_.Trim() -ne '' }) -join "`n"

                $charCount = $Commentary.Length
                $color = if ($charCount -le 3000) { 'Green' } else { 'Red' }

                Write-Host "  [LinkedIn] ($charCount/3000 chars):" -ForegroundColor $color
                Write-Host "  Commentary: $($Commentary.Replace("`n", ' | '))" -ForegroundColor White
                Write-Host "  Article: $($blogData.title) → $($blogData.url)" -ForegroundColor DarkGray
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
Write-Host "  X:        Wed 08:30 UTC, Thu 13:30 UTC" -ForegroundColor White
Write-Host "  LinkedIn: Mon 09:00 UTC, Fri 14:00 UTC" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
