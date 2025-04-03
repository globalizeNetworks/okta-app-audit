# okta-app-audit

This script creates a timestamped csv inventory of all Okta apps which includes these properties:
ApplicationId	ApplicationName	ApplicationLabel	Status	IsActive	ProvisioningEnabled	CreateOperation	UpdateOperation	DeactivateOperation	SyncFields	FieldCount	AttributeSources

To run this, create a okta-app-audit_config.ps1 file in the same directory with the following variables:

$OktaDomain = "your-company.okta.com"
$ApiToken = "your-api-token-here"


I recommend creating a read-only Okta admin account and logging in as that user, then the API key you create won't have too many permissions to cause issues.  (Not sure if we can do more granular permissions, but it doesn't look like it - weak new school platform compared to Entra - no offense)

to get the api key: admin.okta.com | Security | API | Create Token
