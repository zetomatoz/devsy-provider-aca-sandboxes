targetScope = 'resourceGroup'

@description('Name of the Azure Container Apps sandbox group.')
@minLength(1)
@maxLength(32)
param sandboxGroupName string

@description('Azure region for the sandbox group.')
param location string = resourceGroup().location

@description('Microsoft Entra object ID of the user who will run Devsy.')
param principalId string

@description('Create the sandbox group. Set false to grant access to an existing group without updating its settings.')
param createSandboxGroup bool = true

@description('Grant the data-plane role. Set false if the user already has it.')
param grantDataOwner bool = true

var dataOwnerRoleId = 'c24cf47c-5077-412d-a19c-45202126392c'

resource sandboxGroup 'Microsoft.App/sandboxGroups@2026-07-01' = if (createSandboxGroup) {
  name: sandboxGroupName
  location: location
  // Microsoft.App's deployment preflight requires a properties object.
  properties: {}
  tags: {
    project: 'devsy-aca'
  }
}

resource sandboxGroupScope 'Microsoft.App/sandboxGroups@2026-07-01' existing = {
  name: sandboxGroupName
}

resource dataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantDataOwner) {
  name: guid(sandboxGroupScope.id, principalId, dataOwnerRoleId)
  scope: sandboxGroupScope
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataOwnerRoleId)
    principalId: principalId
    principalType: 'User'
  }
  dependsOn: [
    sandboxGroup
  ]
}

output sandboxGroupId string = sandboxGroupScope.id
