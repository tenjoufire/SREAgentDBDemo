using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'scenario3')
param location = readEnvironmentVariable('AZURE_LOCATION', 'southeastasia')
param alertEmail = readEnvironmentVariable('ALERT_EMAIL', 'placeholder@example.com')
param sqlAdminPassword = readEnvironmentVariable('SQL_ADMIN_PASSWORD', '')
param sqlAadAdminLogin = readEnvironmentVariable('SQL_AAD_ADMIN_LOGIN', '')
param sqlAadAdminObjectId = readEnvironmentVariable('SQL_AAD_ADMIN_OBJECT_ID', '')
param sqlAadAdminTenantId = readEnvironmentVariable('SQL_AAD_ADMIN_TENANT_ID', '')
