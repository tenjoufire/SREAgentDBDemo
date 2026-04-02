// ============================================================================
// シナリオ3: Azure SQL / Cosmos DB の遅延増 — 根本原因の特定
// デプロイされるリソース:
//   - Log Analytics Workspace
//   - Application Insights
//   - App Service Plan + App Service
//   - Azure SQL Server + Database (General Purpose vCore)
//   - Cosmos DB Account + Database + Container
//   - Azure Monitor Alert Rules
//   - Action Group
// ============================================================================

@description('リソースのデプロイ先リージョン')
param location string = resourceGroup().location

@description('azd 環境名。envPrefix 未指定時の命名に利用します。')
param environmentName string = ''

@description('環境プレフィックス。未指定時は environmentName から自動生成します。')
param envPrefix string = ''

@description('アラート通知先メールアドレス')
param alertEmail string

@description('Azure SQL 管理者ユーザー名')
param sqlAdminLogin string = 'sqladmin'

@description('Azure SQL 管理者パスワード')
@secure()
param sqlAdminPassword string

@description('Azure SQL の Microsoft Entra 管理者ログイン名')
param sqlAadAdminLogin string

@description('Azure SQL の Microsoft Entra 管理者オブジェクト ID')
param sqlAadAdminObjectId string

@description('Azure SQL の Microsoft Entra テナント ID')
param sqlAadAdminTenantId string = subscription().tenantId

@description('Azure SQL の Microsoft Entra 管理者プリンシパル種別')
@allowed([
  'User'
  'Group'
  'Application'
])
param sqlAadAdminPrincipalType string = 'User'

@description('コンテナイメージ名（初回は mcr のサンプルを使用）')
param containerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

var normalizedEnvironmentName = toLower(replace(empty(environmentName) ? 'local' : environmentName, '_', '-'))
var nameSeed = take(replace(normalizedEnvironmentName, '-', ''), 10)
var uniqueSuffix = take(uniqueString(subscription().subscriptionId, resourceGroup().id, normalizedEnvironmentName), 6)
var resolvedEnvPrefix = !empty(envPrefix) ? envPrefix : 's3-${nameSeed}-${uniqueSuffix}'
var azdTags = empty(environmentName) ? {} : {
  'azd-env-name': environmentName
}
var serviceTags = union(azdTags, {
  'azd-service-name': 'api'
})
var sqlBlockingAlertQuery = 'AzureDiagnostics\n| where ResourceProvider == \'MICROSOFT.SQL\'\n| where Category == \'QueryStoreWaitStatistics\'\n| where _ResourceId =~ \'${sqlDatabase.id}\'\n| where TimeGenerated >= ago(15m)\n| where wait_category_s == \'LOCK\'\n| summarize BlockingWaitMs = sum(todouble(total_query_wait_time_ms_d)) by _ResourceId\n'

// ----------------------------------------------------------------------------
// Log Analytics Workspace
// ----------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${resolvedEnvPrefix}-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ----------------------------------------------------------------------------
// Application Insights
// ----------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${resolvedEnvPrefix}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ----------------------------------------------------------------------------
// Azure SQL Server
// ----------------------------------------------------------------------------
resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: '${resolvedEnvPrefix}-sqlsrv'
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    publicNetworkAccess: 'Enabled'
    administrators: {
      login: sqlAadAdminLogin
      sid: sqlAadAdminObjectId
      tenantId: sqlAadAdminTenantId
      principalType: sqlAadAdminPrincipalType
      azureADOnlyAuthentication: true
    }
    version: '12.0'
  }
}

// Azure SQL — ファイアウォール: Azure サービスからのアクセスを許可
resource sqlFirewall 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ----------------------------------------------------------------------------
// Azure SQL Database — 意図的に低 vCore（General Purpose Gen5 2 vCore）でデプロイ
// デモ中に CPU ボトルネックによる遅延を再現しやすくする
// ----------------------------------------------------------------------------
resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: '${resolvedEnvPrefix}-db'
  location: location
  sku: {
    name: 'GP_Gen5_2'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648 // 2 GB
  }
}

// Azure SQL — 診断設定: Log Analytics に送信
resource sqlDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${resolvedEnvPrefix}-sql-diag'
  scope: sqlDatabase
  properties: {
    workspaceId: logAnalytics.id
    metrics: [
      {
        category: 'Basic'
        enabled: true
      }
    ]
    logs: [
      {
        category: 'SQLInsights'
        enabled: true
      }
      {
        category: 'QueryStoreRuntimeStatistics'
        enabled: true
      }
      {
        category: 'QueryStoreWaitStatistics'
        enabled: true
      }
      {
        category: 'Errors'
        enabled: true
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// Cosmos DB Account
// ----------------------------------------------------------------------------
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-02-15-preview' = {
  name: '${resolvedEnvPrefix}-cosmos'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    publicNetworkAccess: 'Enabled'
    networkAclBypass: 'None'
    ipRules: []
  }
}

// Cosmos DB Database
resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-02-15-preview' = {
  parent: cosmosAccount
  name: 'productcatalog'
  properties: {
    resource: {
      id: 'productcatalog'
    }
  }
}

// Cosmos DB Container
resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-02-15-preview' = {
  parent: cosmosDatabase
  name: 'products'
  properties: {
    resource: {
      id: 'products'
      partitionKey: {
        paths: ['/category']
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/*' }
        ]
      }
    }
  }
}

resource cosmosDataContributorRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-02-15-preview' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, resolvedEnvPrefix, 'cosmos-data-contributor')
  properties: {
    principalId: containerApp.identity.principalId
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: cosmosAccount.id
  }
}

// Cosmos DB — 診断設定
resource cosmosDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${resolvedEnvPrefix}-cosmos-diag'
  scope: cosmosAccount
  properties: {
    workspaceId: logAnalytics.id
    metrics: [
      {
        category: 'Requests'
        enabled: true
      }
    ]
    logs: [
      {
        category: 'DataPlaneRequests'
        enabled: true
      }
      {
        category: 'QueryRuntimeStatistics'
        enabled: true
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// Container Registry
// ----------------------------------------------------------------------------
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: replace('${resolvedEnvPrefix}acr', '-', '')
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// ----------------------------------------------------------------------------
// Container Apps Environment
// ----------------------------------------------------------------------------
resource containerAppEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${resolvedEnvPrefix}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// ----------------------------------------------------------------------------
// Container App
// ----------------------------------------------------------------------------
resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${resolvedEnvPrefix}-app'
  location: location
  tags: serviceTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        traffic: [
          {
            weight: 100
            latestRevision: true
          }
        ]
      }
      registries: [
        {
          server: containerRegistry.properties.loginServer
          username: containerRegistry.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: containerRegistry.listCredentials().passwords[0].value
        }
        {
          name: 'appinsights-connection-string'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'cosmos-key'
          value: cosmosAccount.listKeys().primaryMasterKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'order-api'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              secretRef: 'appinsights-connection-string'
            }
            {
              name: 'SQL_SERVER'
              value: sqlServer.properties.fullyQualifiedDomainName
            }
            {
              name: 'SQL_DATABASE'
              value: sqlDatabase.name
            }
            {
              name: 'AZURE_SQL_CONNECTIONSTRING'
              value: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${sqlDatabase.name};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
            }
            {
              name: 'COSMOS_ENDPOINT'
              value: cosmosAccount.properties.documentEndpoint
            }
            {
              name: 'COSMOS_KEY'
              secretRef: 'cosmos-key'
            }
            {
              name: 'COSMOS_DATABASE'
              value: cosmosDatabase.properties.resource.id
            }
            {
              name: 'COSMOS_CONTAINER'
              value: cosmosContainer.properties.resource.id
            }
            {
              name: 'COSMOS_USE_MANAGED_IDENTITY'
              value: 'true'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 2
      }
    }
  }
}

// ----------------------------------------------------------------------------
// Action Group
// ----------------------------------------------------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: '${resolvedEnvPrefix}-ag'
  location: 'global'
  properties: {
    groupShortName: 'SRE-S3'
    enabled: true
    emailReceivers: [
      {
        name: 'admin'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// Azure Monitor Alert: App Service 応答時間 > 5 秒
// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
// Azure Monitor Alert: SQL CPU percentage > 80%
// ----------------------------------------------------------------------------
resource sqlCpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${resolvedEnvPrefix}-high-sql-cpu'
  location: 'global'
  properties: {
    description: 'Azure SQL Database の CPU percentage が 80% を超過'
    severity: 1
    enabled: true
    scopes: [
      sqlDatabase.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighSqlCpu'
          metricName: 'cpu_percent'
          metricNamespace: 'Microsoft.Sql/servers/databases'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// Azure Monitor Alert: SQL デッドロック
// ----------------------------------------------------------------------------
resource deadlockAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${resolvedEnvPrefix}-deadlocks'
  location: 'global'
  properties: {
    description: 'Azure SQL Database でデッドロックを検出'
    severity: 1
    enabled: true
    scopes: [
      sqlDatabase.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Deadlocks'
          metricName: 'deadlock'
          metricNamespace: 'Microsoft.Sql/servers/databases'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// ----------------------------------------------------------------------------
// Azure Monitor Alert: SQL blocking wait をログから検出
// ----------------------------------------------------------------------------
resource sqlBlockingAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${resolvedEnvPrefix}-sql-blocking-waits'
  location: location
  kind: 'LogAlert'
  properties: {
    description: 'Azure SQL Database の Query Store wait category=LOCK を検出して blocking を通知'
    displayName: '${resolvedEnvPrefix} SQL blocking waits'
    enabled: true
    evaluationFrequency: 'PT5M'
    scopes: [
      logAnalytics.id
    ]
    severity: 2
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: sqlBlockingAlertQuery
          metricMeasureColumn: 'BlockingWaitMs'
          operator: 'GreaterThan'
          threshold: 10
          timeAggregation: 'Total'
          resourceIdColumn: '_ResourceId'
          failingPeriods: {
            minFailingPeriodsToAlert: 1
            numberOfEvaluationPeriods: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
      customProperties: {
        AlertType: 'SqlBlocking'
        WaitCategory: 'LOCK'
      }
    }
    autoMitigate: true
    overrideQueryTimeRange: 'PT15M'
    skipQueryValidation: true
    targetResourceTypes: [
      'Microsoft.Sql/servers/databases'
    ]
  }
}

// ----------------------------------------------------------------------------
// Outputs
// ----------------------------------------------------------------------------
output appServiceName string = containerApp.name
output appServiceUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabase.name
output cosmosAccountName string = cosmosAccount.name
output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint
output appInsightsName string = appInsights.name
output logAnalyticsWorkspaceId string = logAnalytics.id
output resourceGroupName string = resourceGroup().name
output appServicePrincipalId string = containerApp.identity.principalId
output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output AZURE_CONTAINER_APP_NAME string = containerApp.name
output AZURE_CONTAINER_APP_URL string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
output AZURE_RESOURCE_GROUP_NAME string = resourceGroup().name
output AZURE_SQL_SERVER_NAME string = sqlServer.name
output AZURE_SQL_SERVER_FQDN string = sqlServer.properties.fullyQualifiedDomainName
output AZURE_SQL_DATABASE_NAME string = sqlDatabase.name
output AZURE_COSMOS_ACCOUNT_NAME string = cosmosAccount.name
output AZURE_COSMOS_ENDPOINT string = cosmosAccount.properties.documentEndpoint
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.properties.loginServer
