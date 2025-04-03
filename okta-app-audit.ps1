# Okta Provisioning Applications Report
# This script generates a report of all Okta applications with provisioning enabled
# and lists which fields are being synchronized

# Parameters - can be overridden at runtime
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "okta-app-audit_config.ps1",
    
    [Parameter(Mandatory=$false)]
    [string]$OktaDomain,
    
    [Parameter(Mandatory=$false)]
    [string]$ApiToken
)

# Check if config file exists and source it
if (Test-Path $ConfigFile) {
    Write-Host "Loading configuration from $ConfigFile"
    . $ConfigFile
}
else {
    Write-Host "Configuration file not found at $ConfigFile"
    
    # If parameters were not provided and config file doesn't exist, prompt for them
    if (-not $OktaDomain) {
        $OktaDomain = Read-Host -Prompt "Enter your Okta domain (e.g., company.okta.com)"
    }
    
    if (-not $ApiToken) {
        $ApiToken = Read-Host -Prompt "Enter your Okta API token"
    }
}

# Verify we have the required parameters
if (-not $OktaDomain -or -not $ApiToken) {
    Write-Error "Okta domain and API token are required. Please provide them as parameters or in the config file."
    exit 1
}

# Configuration
$baseUrl = "https://$OktaDomain"
$headers = @{
    "Accept" = "application/json"
    "Content-Type" = "application/json"
    "Authorization" = "SSWS $ApiToken"
}

# Create timestamp for CSV filename
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputFile = "OktaProvisioningApps_$timestamp.csv"

# Initialize results array
$results = @()

Write-Host "Starting Okta Provisioning Applications Report..."
Write-Host "Retrieving all applications from Okta..."

# Get all applications
$allApps = @()
$url = "$baseUrl/api/v1/apps"
$hasMore = $true
$limit = 200

while ($hasMore) {
    try {
        $response = Invoke-RestMethod -Uri "$url`?limit=$limit" -Headers $headers -Method Get -ResponseHeadersVariable responseHeaders
        $allApps += $response
        
        # Check if there are more pages
        $hasMore = $false
        
        if ($responseHeaders.Link) {
            $links = $responseHeaders.Link
            if ($links -match '<([^>]*)>; rel="next"') {
                $url = $matches[1]
                $hasMore = $true
            }
        }
    }
    catch {
        Write-Error "Error retrieving applications: $_"
        exit 1
    }
}

Write-Host "Retrieved $($allApps.Count) applications. Analyzing provisioning configuration..."

# Process each application
foreach ($app in $allApps) {
    Write-Host "Processing application: $($app.name) (ID: $($app.id))"
    # Add a delay before processing each application to avoid rate limiting
    Start-Sleep -Seconds 1
    
    # Default values
    $hasProvisioning = $false
    $provisioningConfig = $null
    $attributes = @()
    $attributeSources = @()
    $isWellKnownApp = $false
    
    try {
    
    try {
        # Get application features
        try {
            $appFeatures = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/features" -Headers $headers -Method Get -ErrorAction Stop
            
            # Check if provisioning is enabled
            $hasProvisioning = $false
            $provisioningConfig = $null
            
            foreach ($feature in $appFeatures) {
                if ($feature.name -eq "USER_PROVISIONING" -or $feature.name -eq "USER_MANAGEMENT") {
                    $hasProvisioning = $true
                    
                    # Add delay to avoid rate limiting
                    Start-Sleep -Milliseconds 1000
                    
                    # Get provisioning configuration
                    try {
                        $provisioningConfig = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/features/USER_PROVISIONING" -Headers $headers -Method Get -ErrorAction Stop
                        Write-Host "  - Retrieved USER_PROVISIONING configuration"
                    }
                    catch {
                        if ($_.Exception.Response.StatusCode.value__ -eq 429) {
                            Write-Host "  - Rate limit exceeded. Waiting 30 seconds before retrying..."
                            Start-Sleep -Seconds 30
                            try {
                                $provisioningConfig = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/features/USER_PROVISIONING" -Headers $headers -Method Get -ErrorAction Stop
                                Write-Host "  - Retrieved USER_PROVISIONING configuration after retry"
                            }
                            catch {
                                Write-Host "  - Still could not get USER_PROVISIONING config: $($_.Exception.Message)"
                            }
                        }
                        else {
                            Write-Host "  - Could not get USER_PROVISIONING config: $($_.Exception.Message)"
                        }
                    }
                    
                    if (-not $provisioningConfig) {
                        # Add delay to avoid rate limiting
                        Start-Sleep -Milliseconds 1000
                        
                        try {
                            $provisioningConfig = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/features/USER_MANAGEMENT" -Headers $headers -Method Get -ErrorAction Stop
                            Write-Host "  - Retrieved USER_MANAGEMENT configuration"
                        }
                        catch {
                            if ($_.Exception.Response.StatusCode.value__ -eq 429) {
                                Write-Host "  - Rate limit exceeded. Waiting 30 seconds before retrying..."
                                Start-Sleep -Seconds 30
                                try {
                                    $provisioningConfig = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/features/USER_MANAGEMENT" -Headers $headers -Method Get -ErrorAction Stop
                                    Write-Host "  - Retrieved USER_MANAGEMENT configuration after retry"
                                }
                                catch {
                                    Write-Host "  - Still could not get USER_MANAGEMENT config: $($_.Exception.Message)"
                                }
                            }
                            else {
                                Write-Host "  - Could not get USER_MANAGEMENT config: $($_.Exception.Message)"
                            }
                        }
                    }
                    
                    # If we still don't have provisioning configuration but we know provisioning is enabled,
                    # check the app feature status directly to get operation settings
                    if ((-not $provisioningConfig -or -not $provisioningConfig.create) -and $hasProvisioning) {
                        Write-Host "  - No provisioning config details found. Checking feature status directly..."
                        
                        # Look for provisioning operations in the feature status
                        $createEnabled = $false
                        $updateEnabled = $false
                        $deactivateEnabled = $false
                        
                        foreach ($feature in $appFeatures) {
                            if ($feature.name -eq "USER_PROVISIONING" -or $feature.name -eq "USER_MANAGEMENT") {
                                if ($feature.status -eq "ENABLED") {
                                    # If provisioning is enabled, we assume all operations are enabled
                                    # This is a fallback since we couldn't get the detailed configuration
                                    $createEnabled = $true
                                    $updateEnabled = $true
                                    $deactivateEnabled = $true
                                    Write-Host "  - Feature is enabled, assuming all operations are enabled"
                                }
                                break
                            }
                        }
                        
                        # Create a simple provisioning config object
                        $provisioningConfig = @{
                            create = @{ enabled = $createEnabled }
                            update = @{ enabled = $updateEnabled }
                            deactivate = @{ enabled = $deactivateEnabled }
                        }
                    }
                    
                    break
                }
            }
            
            # Check for alternative provisioning config structure for well-known apps
            # Some popular apps like Zoom, Slack, Office 365 might have different API responses
            if ($hasProvisioning -and (-not $provisioningConfig -or -not $provisioningConfig.create)) {
                # Try to get the app directly to check its settings
                try {
                    Write-Host "  - Attempting to get detailed app settings..."
                    Start-Sleep -Milliseconds 1000
                    
                    $appDetails = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)" -Headers $headers -Method Get -ErrorAction SilentlyContinue
                    
                    # Some well-known apps have specific settings structures
                    $isWellKnownApp = @("zoomus", "slack", "office365", "google", "salesforce", "box") -contains $app.name
                    
                    if ($isWellKnownApp -and $hasProvisioning) {
                        Write-Host "  - Well-known app detected ($($app.name)). Setting provisional values based on enabled status."
                        
                        # If it's a well-known app with provisioning enabled, assume operations are enabled
                        # This is based on the fact that most integrated apps have these features enabled by default
                        $createEnabled = $true
                        $updateEnabled = $true
                        $deactivateEnabled = $true
                        
                        # Create a simple provisioning config object
                        $provisioningConfig = @{
                            create = @{ enabled = $createEnabled }
                            update = @{ enabled = $updateEnabled }
                            deactivate = @{ enabled = $deactivateEnabled }
                        }
                    }
                }
                catch {
                    Write-Host "  - Could not get detailed app settings: $($_.Exception.Message)"
                }
            }
        }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 429) {
                Write-Host "  - Rate limit exceeded. Waiting 30 seconds before retrying..."
                Start-Sleep -Seconds 30
                $appFeatures = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/features" -Headers $headers -Method Get -ErrorAction SilentlyContinue
            }
            elseif ($_.Exception.Response.StatusCode.value__ -eq 404 -or $_.ToString() -like "*Provisioning is not supported*") {
                Write-Host "  - Provisioning is not supported for this application."
                $hasProvisioning = $false
            }
            else {
                Write-Host "  - Error getting features: $($_.Exception.Message)"
                $hasProvisioning = $false
            }
        }
        
        # If provisioning is not enabled, we'll set defaults for this app
        if (-not $hasProvisioning) {
            Write-Host "  - Provisioning not enabled for this application, setting default values."
            $attributes = @() # Empty attributes array
            # No additional logic needed - we'll add the app to results below
        }
        
        # Get schema attributes if available
        $attributes = @()
        $attributeSources = @()
        
        if ($hasProvisioning) {
            # Define well-known apps for special handling
            $wellKnownApps = @{
                "okta_org2org" = @{
                    "description" = "Okta Org2Org"
                    "defaultAttributes" = @("userName", "firstName", "lastName", "email", "mobilePhone", "groups")
                }
                "zoomus" = @{
                    "description" = "Zoom"
                    "defaultAttributes" = @("userName", "firstName", "lastName", "email", "displayName", "department", "title")
                }
                "slack" = @{
                    "description" = "Slack"
                    "defaultAttributes" = @("userName", "email", "firstName", "lastName", "displayName")
                }
                "office365" = @{
                    "description" = "Microsoft Office 365"
                    "defaultAttributes" = @("userName", "email", "firstName", "lastName", "displayName", "mobilePhone", "department", "title", "groups")
                }
            }
            
            # Check if this is a well-known app that needs special handling
            $isWellKnownApp = $wellKnownApps.ContainsKey($app.name)
            
            if ($isWellKnownApp) {
                Write-Host "  - Well-known app detected: $($app.name) ($($wellKnownApps[$app.name].description))"
                $attributes = $wellKnownApps[$app.name].defaultAttributes
                $attributeSources += "Default schema for $($wellKnownApps[$app.name].description)"
            }
            
            # First try to get the profile mappings directly
            if (-not $isWellKnownApp -or $attributes.Count -eq 0) {
                try {
                    # Add delay to avoid rate limiting
                    Start-Sleep -Milliseconds 1000
                    
                    $profileMappings = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/mappings" -Headers $headers -Method Get -ErrorAction Stop
                    
                    Write-Host "  - Retrieved profile mappings"
                    
                    foreach ($mapping in $profileMappings) {
                        if ($mapping.source.type -eq "OKTA_USER" -and $mapping.target.type -like "*USER*") {
                            # Try to get the detailed mapping properties
                            Start-Sleep -Milliseconds 1000
                            
                            try {
                                $mappingDetails = Invoke-RestMethod -Uri "$baseUrl/api/v1/mappings/$($mapping.id)" -Headers $headers -Method Get -ErrorAction Stop
                                
                                if ($mappingDetails -and $mappingDetails.properties) {
                                    Write-Host "  - Retrieved mapping details with $($mappingDetails.properties.Count) properties"
                                    
                                    foreach ($prop in $mappingDetails.properties) {
                                        if ($prop.target -and $prop.target.name) {
                                            $attributes += $prop.target.name
                                        }
                                    }
                                    
                                    if ($attributes.Count -gt 0) {
                                        $attributeSources += "Mapping details"
                                    }
                                }
                            }
                            catch {
                                Write-Host "  - Error getting mapping details: $($_.Exception.Message)"
                            }
                        }
                    }
                }
                catch {
                    if ($_.Exception.Response.StatusCode.value__ -eq 429) {
                        Write-Host "  - Rate limit exceeded for mappings. Waiting 30 seconds before retrying..."
                        Start-Sleep -Seconds 30
                        try {
                            $profileMappings = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/mappings" -Headers $headers -Method Get -ErrorAction SilentlyContinue
                            # Process mappings as above...
                        }
                        catch {
                            Write-Host "  - Still could not get mappings: $($_.Exception.Message)"
                        }
                    }
                    else {
                        Write-Host "  - No profile mappings available: $($_.Exception.Message)"
                    }
                }
            }
            
            # If we didn't get attributes from mappings, try schema
            if (-not $isWellKnownApp -and $attributes.Count -eq 0) {
                try {
                    # Add delay to avoid rate limiting
                    Start-Sleep -Milliseconds 1000
                    
                    $schema = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/schemas" -Headers $headers -Method Get -ErrorAction Stop
                    
                    Write-Host "  - Retrieved schema"
                    
                    if ($schema -and $schema.definitions -and $schema.definitions.user) {
                        foreach ($prop in $schema.definitions.user.properties.PSObject.Properties) {
                            $attributes += $prop.Name
                        }
                        
                        if ($attributes.Count -gt 0) {
                            $attributeSources += "Schema"
                        }
                    }
                }
                catch {
                    if ($_.Exception.Response.StatusCode.value__ -eq 429) {
                        Write-Host "  - Rate limit exceeded for schema. Waiting 30 seconds before retrying..."
                        Start-Sleep -Seconds 30
                        try {
                            $schema = Invoke-RestMethod -Uri "$baseUrl/api/v1/apps/$($app.id)/schemas" -Headers $headers -Method Get -ErrorAction SilentlyContinue
                            
                            if ($schema -and $schema.definitions -and $schema.definitions.user) {
                                foreach ($prop in $schema.definitions.user.properties.PSObject.Properties) {
                                    $attributes += $prop.Name
                                }
                                
                                if ($attributes.Count -gt 0) {
                                    $attributeSources += "Schema (retry)"
                                }
                            }
                        }
                        catch {
                            Write-Host "  - No schema information available after retry"
                        }
                    }
                    else {
                        # Some apps may not have schemas available
                        Write-Host "  - No schema information available: $($_.Exception.Message)"
                    }
                }
            }
            
            # Make attributes unique and sort them
            $attributes = $attributes | Select-Object -Unique | Sort-Object
        }
    }
    catch {
        Write-Host "  - Error processing application: $($_.Exception.Message)"
        $hasProvisioning = $false
        $attributes = @()
        $attributeSources = @()
    }
        
        # Always add the app to results, regardless of provisioning status
        $appResult = [PSCustomObject]@{
            "ApplicationId" = $app.id
            "ApplicationName" = $app.name
            "ApplicationLabel" = $app.label
            "Status" = $app.status
            "IsActive" = ($app.status -eq "ACTIVE")
            "ProvisioningEnabled" = $hasProvisioning
            "CreateOperation" = if ($provisioningConfig -and $provisioningConfig.create) { $provisioningConfig.create.enabled -eq $true } else { $false }
            "UpdateOperation" = if ($provisioningConfig -and $provisioningConfig.update) { $provisioningConfig.update.enabled -eq $true } else { $false }
            "DeactivateOperation" = if ($provisioningConfig -and $provisioningConfig.deactivate) { $provisioningConfig.deactivate.enabled -eq $true } else { $false }
            "SyncFields" = if ($attributes.Count -gt 0) { $attributes -join "; " } else { "" }
            "FieldCount" = $attributes.Count
            "AttributeSources" = if ($attributeSources.Count -gt 0) { $attributeSources -join "; " } else { "" }
        }
        
        $results += $appResult
        
        if ($hasProvisioning) {
            Write-Host "  - Added to results with provisioning enabled and $($attributes.Count) synchronized fields"
        } else {
            Write-Host "  - Added to results without provisioning"
        }
        
        $results += $appResult
        
        if ($hasProvisioning) {
            Write-Host "  - Provisioning enabled with $($attributes.Count) synchronized fields"
        } else {
            Write-Host "  - Provisioning not enabled for this application"
        }
    }
    catch {
        Write-Error "Error processing application $($app.id): $_"
    }
}

# Export to CSV
$results | Export-Csv -Path $outputFile -NoTypeInformation

Write-Host "Report completed! Found $($results.Count) total applications with $($results | Where-Object { $_.ProvisioningEnabled -eq $true } | Measure-Object).Count having provisioning enabled."
Write-Host "Results saved to: $outputFile"