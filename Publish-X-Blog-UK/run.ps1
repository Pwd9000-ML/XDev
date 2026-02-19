# ============================================================================
# Publish-X-Blog-UK - Posts a blog to X on Wednesday 07:30 UTC (UK morning)
# ============================================================================
# Timer trigger: fires once per week at Wednesday 07:30 UTC.
# All posting logic is handled by the shared XPostHelper module
# (Modules/XPostHelper/XPostHelper.psm1), loaded automatically via profile.ps1.
#
# Depends on:
#   - BlogHelper module (Get-Blog) for blog selection and rotation tracking
#   - XPostHelper module (Invoke-XBlogPost) for message composition and X API posting
#
# Required App Settings (environment variables):
#   DEV.to / Storage: DevURI, Function_RGName, Function_SaActName
#   Exclusions:       excludeBlogIds, excludeBlogYears
#   X API creds:      xApiKey, xApiSecret, xAccessToken, xAccessTokenSecret
#   Optional:         dryRun ("true" to skip posting)
# ============================================================================

# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format.
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

Write-Host "Publish-X-Blog-UK triggered at $($currentUTCtime.ToString('yyyy-MM-dd HH:mm:ss')) UTC"

# Invoke the shared posting workflow (blog selection → message composition → post to X)
Invoke-XBlogPost
