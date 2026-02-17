<#
.SYNOPSIS
    Shared blog helper module for cross-platform blog promotion.

.DESCRIPTION
    Provides the Get-Blog function used by all Publish-*-Blog Azure Functions.
    Handles blog selection from DEV.to, rotation tracking via Azure Table Storage,
    and platform-specific partitioning so each platform cycles independently.

    Tracker table: 'blogtracker' (platform-agnostic)
    Partition keys: 'Posted-{Platform}' (e.g. 'Posted-X', 'Posted-LinkedIn')

.NOTES
    MIGRATION: If upgrading from the original single-platform setup, create a new
    'blogtracker' table in Azure Storage (or rename the existing 'blogs' table).
    The old 'Blog-ID' partition is replaced by platform-specific partitions.
#>

function Get-Blog {
    <#
    .SYNOPSIS
        Selects a random blog post with rotation tracking via Azure Table Storage.

    .DESCRIPTION
        Fetches all blog posts from the DEV.to API, applies exclusion filters (by ID
        and/or year), then picks a random post that hasn't been posted to the specified
        platform yet. When all posts have been cycled through, the tracker resets
        automatically for that platform.

    .PARAMETER URI
        The DEV.to API endpoint (e.g. "https://dev.to/api/articles?username=pwd9000&per_page=1000").

    .PARAMETER resourceGroupName
        Azure resource group containing the storage account.

    .PARAMETER storageAccountName
        Azure Storage account name used for rotation tracking.

    .PARAMETER platform
        Platform identifier (e.g. 'X', 'LinkedIn', 'Mastodon', 'Bluesky').
        Used to build the partition key 'Posted-{platform}' so each platform
        cycles through blogs independently.

    .PARAMETER tableName
        Azure Table name for rotation tracking. Defaults to 'blogtracker'.

    .PARAMETER excludeIds
        Comma-separated blog IDs to permanently exclude (e.g. "1234, 5678").

    .PARAMETER excludeYears
        Comma-separated years to exclude (e.g. "2023, 2024").
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]
        [string]$URI,

        [Parameter(Mandatory)]
        [string]$resourceGroupName,

        [Parameter(Mandatory)]
        [string]$storageAccountName,

        [Parameter(Mandatory)]
        [string]$platform,

        [Parameter(Mandatory = $false)]
        [string]$tableName = 'blogtracker',

        [Parameter(Mandatory = $false)]
        [string]$excludeIds = $null,

        [Parameter(Mandatory = $false)]
        [string]$excludeYears = $null
    )

    # Build platform-specific partition key for independent rotation per platform
    $tablePartition = "Posted-$platform"

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
    Write-Output "$blogCount blogs left to post on $platform"

    # If no blogs are available (all excluded by ID/year filters), reset tracker and retry
    if ($blogCount -eq 0) {
        Write-Warning "No available blogs to post on $platform. All blogs may be excluded or already tracked. Resetting tracker and retrying."
        if ($records) {
            try {
                $records | Remove-AzTableRow -table $cloudTable -Verbose
                $records = $null
            }
            catch {
                Write-Error $_.Exception.Message
            }
        }

        # Recalculate available blogs after reset
        $availableBlogIds = $blogPosts.id
        $blogCount = $availableBlogIds.Count

        if ($blogCount -eq 0) {
            Write-Error "No blogs available even after tracker reset. Check excludeBlogIds/excludeBlogYears filters or DEV.to API."
            return $null
        }
        Write-Host "Tracker reset complete. $blogCount blogs now available for $platform."
    }

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

Export-ModuleMember -Function Get-Blog
