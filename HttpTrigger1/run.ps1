# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format.
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

#GET-BLOG##
function Get-Blog {
    [cmdletbinding()]
    Param (
        [Parameter(Mandatory=$false,
        ValueFromPipeline=$false)]
        [switch] $Reset,
        [Parameter(Mandatory)]
        [string]$URI,
        [Parameter(Mandatory)]
        [string]$resourceGroupName,
        [Parameter(Mandatory)]
        [string]$storageAccountName,
        [Parameter(Mandatory=$false)]
        [string]$tableName='blogs',
        [Parameter(Mandatory=$false)]
        [string]$tablePartition='Blog-ID',
        [Parameter(Mandatory=$false)]
        [string]$excludeIds=$null
    )
  
    #Excluded posts (Not wanted in posts)
    if ($excludeIds) {
        $excludeBlogIds = $excludeIds.Split(', ') # e.g. "1234, 1235, 1236"
    }
    else {
        $excludeBlogIds = $null
    }

    # Try to connect to Az Table storage to check tracking (Already posted tweets)
    try {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
        $storageContext = $storageAccount.Context
        $cloudTable = (Get-AzStorageTable –Name $tableName –Context $storageContext).CloudTable
        $records = Get-AzTableRow -table $cloudTable -PartitionKey $tablePartition
    }
    catch {
        Write-Error $_.Exception.Message
    }

    if($records) {#if there are some (Already posted tweets)
        $blogPreCalledIds = $records | select-object -ExpandProperty RowKey
    }
    else {
        $blogPreCalledIds = $null
    }

    # Add exclusions if any (Stuff not wanting to tweet, by blog ID, comma seperated)
    foreach ($id in $excludeBlogIds) {
        If ($blogPreCalledIds -notcontains $id) {
            Write-host "$id not in tracker, adding to tracker to exclude"
            $null = Add-AzTableRow -table $cloudTable -partitionKey $tablePartition -rowKey $id
            $blogPreCalledIds += $id
        } 
        else {
            Write-host "$id in tracker, and will be excluded" 
        }
    }

    # Call Dev API to get all posts from URI
    $blogPosts = Invoke-RestMethod -Uri $URI -Method GET

    if($blogPreCalledIds -ne $null) {
        $availableBlogIds = Compare-Object -ReferenceObject ($blogPosts.id) -DifferenceObject $blogPreCalledIds -PassThru
    }
    else {
        $availableBlogIds = $blogPosts.id
    }
    
    #Number of items
    $blogCount = $availableBlogIds.Count
    Write-Output "$blogCount blogs left to tweet"
    
    if ($blogCount -eq 1) {
        $Reset = $true
    }
    else {
        $Reset = $false
    }

    if($Reset) {
        try {
            #Delete all for the tablePartition
            $records | Remove-AzTableRow -table $cloudTable -Verbose
            $records = $null
        }
        catch {
            Write-Error $_.Exception.Message
        }
    }

    #Generate a random number based on the entries available
    $blogItem = Get-Random -Maximum $blogCount

    #Selected data
    $blogDataId = $availableBlogIds[$blogItem]
    $blogData = $blogPosts | where-object {$_.id -eq $blogDataId}
    #Add entry and returned
    try {
        $null = Add-AzTableRow -table $cloudTable -partitionKey $tablePartition -rowKey $blogDataId
    }
    catch {
        Write-Error $_.Exception.Message
    }

    return $blogData
}

#Get short URL from blog long URL#
function Get-ShortUrl {
    [cmdletbinding()]
    param(
        [parameter(Mandatory)]
        $Url,

        [parameter(Mandatory)]
        [string]$OAuthToken
    )

    $ErrorActionPreference = 'Stop'

    $headers = @{
        Authorization = "Bearer $OAuthToken"
    }

    $body = @{long_url = $Url} | ConvertTo-Json

    $params = @{
        Uri         = 'https://api-ssl.bitly.com/v4/shorten'
        Method      = 'Post'
        Body        = $body
        Headers     = $headers
        ContentType = 'application/json'
    }

    try {
        $shortUrl = (Invoke-RestMethod @params).link
    }
    catch {
        Write-Error $_.Exception.Message
    }

    return $shortUrl
}

###Twitter Section####
##Needed modules##
#Install-Module AzTable -force
Import-Module AzTable
#Install-Module PSTwitterAPI -force
Import-Module PSTwitterAPI

# Set these environment variables up in Function App settings:
$URI = $env:DevURI
$resourceGroupName = $env:Function_RGName
$storageAccountName = $env:Function_SaActName
$excludeIds = $env:excludeBlogIds # e.g. "1234, 1235, 1236"

$bitlyToken = $env:bitlyOAuth

$twtApiKey = $env:twtApiKey
$twtApiSecret = $env:twtApiSecret
$twtToken = $env:twtToken
$twtTokenSecret = $env:twtTokenSecret

## Set Status##
$statusGood = $true

try {
    [PSCustomObject]$blogToPost = Get-Blog -URI $URI -resourceGroupName $resourceGroupName -storageAccountName $storageAccountName -excludeIds $excludeIds
    [PSCustomObject]$sUrl = Get-ShortUrl -Url ($blogToPost.Url) -OAuthToken $bitlyToken

    $hashtags = ''
    $blogToPost.tags.Split(', ') | Foreach-Object {
        $tag = $_
        $hashtags += (' #' + $tag)
    }
    $hashtags = $hashtags.Trim()

    $Message = "RT: $($blogToPost.title), by @$($blogToPost.user.twitter_username). $($hashtags) $($sUrl)"
    Write-Host "$Message"

    $OAuthSettings = @{
        ApiKey = $twtApiKey
        ApiSecret = $twtApiSecret
        AccessToken = $twtToken
        AccessTokenSecret = $twtTokenSecret
      }
    Set-TwitterOAuthSettings @OAuthSettings -Verbose

    # Send tweet to your timeline:
    Send-TwitterStatuses_Update -status $Message -Verbose

} catch {
    $statusGood = $false
    $statusMessage = "Tweet Failed: $_"

    $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
    $storageContext = $storageAccount.Context
    $cloudTable = (Get-AzStorageTable –Name 'failed' –Context $storageContext).CloudTable
    $null = Add-AzTableRow -table $cloudTable -partitionKey 'Blog-Fail' -rowKey "$statusMessage -- [$Message]"
}

if($statusGood)
{
    $statusMessage = "Everything Ran OK"
}

Write-Host "$statusMessage"

#other twitter commands:
# Use one of the API Helpers provided:
#$TwitterUser = Get-TwitterUsers_Lookup -screen_name 'pwd9000'

# Send DM to a user:
#$Event = Send-TwitterDirectMessages_EventsNew -recipient_id $TwitterUser.Id -text "Hello @$($TwitterUser.screen_name)!! #PSTwitterAPI"

# Get the tweets you would see on your timeline:
#$TwitterStatuses = Get-TwitterStatuses_HomeTimeline -count 100

# Get tweets from someone elses timeline (what they tweeted):
#$TwitterStatuses = Get-TwitterStatuses_UserTimeline -screen_name 'mkellerman' -count 400

# Search for tweets:
#$Tweets = Get-TwitterSearch_Tweets -q '#powershell' -count 400