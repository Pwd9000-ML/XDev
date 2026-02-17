# Azure Functions profile.ps1
#
# This profile.ps1 will get executed every "cold start" of your Function App.
# "cold start" occurs when:
#
# * A Function App starts up for the very first time
# * A Function App starts up after being de-allocated due to inactivity
#
# You can define helper functions, run commands, or specify environment
# variables in this file.

# Authenticate with Azure PowerShell using Managed Identity.
# Required for Azure Table Storage operations (blog post rotation tracking).
if ($env:IDENTITY_ENDPOINT) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity
}

# Import shared modules used by all Publish-*-Blog functions.
# BlogHelper provides the Get-Blog function for platform-agnostic blog selection
# and rotation tracking (table: 'blogtracker', partitions: 'Posted-X', 'Posted-LinkedIn', etc.)
Import-Module "$PSScriptRoot/Modules/BlogHelper" -Force
