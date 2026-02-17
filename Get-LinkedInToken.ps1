<#
.SYNOPSIS
    Automates the LinkedIn OAuth 2.0 token generation flow every 2 months when the token expires.
    https://www.linkedin.com/developers/apps/228996448/auth

.DESCRIPTION
    Spins up a temporary local HTTP listener, opens your browser to LinkedIn's
    authorization page, captures the redirect callback with the auth code,
    exchanges it for an access token, and retrieves your Person URN.

    No manual copy-pasting of codes needed — it's all automated.

.PARAMETER ClientId
    LinkedIn App Client ID (from Auth tab in LinkedIn Developer Portal).

.PARAMETER ClientSecret
    LinkedIn App Client Secret (from Auth tab in LinkedIn Developer Portal).

.PARAMETER Port
    Local port for the callback listener. Default: 8080.
    Must match the redirect URI configured in your LinkedIn App.

.EXAMPLE
    .\Get-LinkedInToken.ps1 -ClientId "78ln6cfmtxzuxw" -ClientSecret "WPL_AP1.xxxxx"

.EXAMPLE
    # Pipe directly into Azure Function App settings:
    $creds = .\Get-LinkedInToken.ps1 -ClientId "78ln6cfmtxzuxw" -ClientSecret "WPL_AP1.xxxxx"
    $creds.AccessToken
    $creds.PersonUrn

.NOTES
    Ensure 'https://localhost:8080/callback' (or your chosen port) is added as an
    Authorized redirect URL in your LinkedIn App's Auth settings.

    Run this script whenever your token expires (~2 months) to generate a new one.
#>

param(
    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [string]$ClientSecret,

    [int]$Port = 8080
)

$ErrorActionPreference = 'Stop'

$redirectUri = "http://localhost:$Port/callback"
$scope = "openid profile w_member_social"
$state = [System.Guid]::NewGuid().ToString('N')

# ============================================================================
# Step 1: Start a temporary HTTP listener to capture the OAuth callback
# ============================================================================
Write-Host "Starting local HTTP listener on port $Port..." -ForegroundColor Cyan

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

# ============================================================================
# Step 2: Open browser to LinkedIn authorization page
# ============================================================================
$authUrl = "https://www.linkedin.com/oauth/v2/authorization?" + `
    "response_type=code" + `
    "&client_id=$ClientId" + `
    "&redirect_uri=$([System.Uri]::EscapeDataString($redirectUri))" + `
    "&scope=$([System.Uri]::EscapeDataString($scope))" + `
    "&state=$state"

Write-Host "Opening browser for LinkedIn authorization..." -ForegroundColor Yellow
Write-Host "If the browser doesn't open, visit this URL manually:" -ForegroundColor DarkGray
Write-Host $authUrl -ForegroundColor DarkGray
Write-Host ""
Write-Host "Waiting for authorization callback..." -ForegroundColor Yellow

Start-Process $authUrl

# ============================================================================
# Step 3: Wait for the callback and extract the authorization code
# ============================================================================
$authCode = $null
try {
    # Keep listening until we get the actual OAuth callback (ignore favicon/other requests)
    while ($null -eq $authCode) {
        $context = $listener.GetContext()
        $request = $context.Request
        $queryParams = $request.QueryString

        # Check if this is the real callback (has 'code' or 'error' param)
        if ($queryParams['code'] -or $queryParams['error']) {
            # Send a success page back to the browser
            $responseHtml = "<html><body><h2>Authorization successful!</h2><p>You can close this tab and return to your terminal.</p></body></html>"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseHtml)
            $context.Response.ContentLength64 = $buffer.Length
            $context.Response.ContentType = "text/html"
            $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
            $context.Response.OutputStream.Close()

            # Validate state to prevent CSRF
            $returnedState = $queryParams['state']
            if ($returnedState -ne $state) {
                throw "State mismatch! Expected '$state' but got '$returnedState'. Possible CSRF attack."
            }

            $authCode = $queryParams['code']
            if ([string]::IsNullOrEmpty($authCode)) {
                $errorCode = $queryParams['error']
                $errorDesc = $queryParams['error_description']
                throw "Authorization failed: $errorCode - $errorDesc"
            }
        }
        else {
            # Not the callback — send empty response and keep listening (e.g. favicon.ico)
            $context.Response.StatusCode = 204
            $context.Response.OutputStream.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}

Write-Host "Authorization code received!" -ForegroundColor Green

# ============================================================================
# Step 4: Exchange the authorization code for an access token
# ============================================================================
Write-Host "Exchanging code for access token..." -ForegroundColor Cyan

$tokenResponse = Invoke-RestMethod -Uri "https://www.linkedin.com/oauth/v2/accessToken" -Method Post -Body @{
    grant_type    = "authorization_code"
    code          = $authCode
    redirect_uri  = $redirectUri
    client_id     = $ClientId
    client_secret = $ClientSecret
}

$accessToken = $tokenResponse.access_token
$expiresIn = $tokenResponse.expires_in
$expiryDate = (Get-Date).AddSeconds($expiresIn).ToString('yyyy-MM-dd')

Write-Host "Access token obtained! Expires in $expiresIn seconds (~$expiryDate)" -ForegroundColor Green

# ============================================================================
# Step 5: Retrieve Person URN via userinfo endpoint
# ============================================================================
Write-Host "Fetching LinkedIn Person URN..." -ForegroundColor Cyan

$userInfo = Invoke-RestMethod -Uri "https://api.linkedin.com/v2/userinfo" -Headers @{
    Authorization = "Bearer $accessToken"
}

$personUrn = "urn:li:person:$($userInfo.sub)"

# ============================================================================
# Output results
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " LinkedIn OAuth Setup Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Name:        $($userInfo.name)" -ForegroundColor White
Write-Host "  Person URN:  $personUrn" -ForegroundColor White
Write-Host "  Token expiry: ~$expiryDate" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Add these as Azure Function App Settings:" -ForegroundColor Yellow
Write-Host "  linkedInAccessToken = $accessToken" -ForegroundColor White
Write-Host "  linkedInPersonUrn   = $personUrn" -ForegroundColor White
Write-Host ""

# Return as object for pipeline use
[PSCustomObject]@{
    AccessToken = $accessToken
    PersonUrn   = $personUrn
    Name        = $userInfo.name
    ExpiresIn   = $expiresIn
    ExpiryDate  = $expiryDate
}
