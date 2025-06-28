@description('Lokacija za resurse')
param location string = 'westeurope'

@description('Tag za projekt')
param courseTag string = 'muvodic-irou'

@description('Popis korisnika (ime, prezime, rola)')
param users array = [
  {
    ime: 'pero'
    prezime: 'peric'
    rola: 'student'
  }
  {
    ime: 'iva'
    prezime: 'ivic'
    rola: 'student'
  }
  {
    ime: 'mario'
    prezime: 'maric'
    rola: 'instruktor'
  }
]

@description('SSH public key')
param sshKey string

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'muvodic-irou'
  location: location
  tags: { course: courseTag }
}

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: 'vnet-muvodic-irou'
  location: location
  tags: { course: courseTag }
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [for (user, idx) in users: {
      name: 'subnet-${user.ime}.${user.prezime}'
      properties: {
        addressPrefix: '10.0.${idx + 1}.0/24'
        networkSecurityGroup: {
          id: nsgs[idx].id
        }
      }
    }]
  }
}

resource nsgs 'Microsoft.Network/networkSecurityGroups@2022-07-01' = [for (user, idx) in users: {
  name: 'nsg-${user.ime}.${user.prezime}'
  location: location
  tags: { course: courseTag }
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-JumpHost'
        priority: 1000
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        sourcePortRange: '*'
        destinationPortRange: '22'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
      }
    ]
  }
}]

resource storage 'Microsoft.Storage/storageAccounts@2022-09-01' = [for (user, idx) in users: {
  name: toLower('st${user.ime}${user.prezime}${uniqueString(user.ime,user.prezime)}')
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  tags: { course: courseTag }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}]

resource jumphostPIP 'Microsoft.Network/publicIPAddresses@2022-11-01' = [for (user, idx) in users: {
  name: 'jumphost-${user.ime}.${user.prezime}-pip'
  location: location
  sku: { name: 'Basic' }
  properties: {
    publicIPAllocationMethod: 'Dynamic'
  }
}]

resource jumphostNic 'Microsoft.Network/networkInterfaces@2022-11-01' = [for (user, idx) in users: {
  name: 'jumphost-${user.ime}.${user.prezime}-nic'
  location: location
  ipConfigurations: [
    {
      name: 'ipconfig1'
      properties: {
        privateIPAllocationMethod: 'Dynamic'
        publicIPAddress: {
          id: jumphostPIP[idx].id
        }
        subnet: {
          id: vnet::subnets[idx].id
        }
      }
    }
  ]
  tags: { course: courseTag }
}]

resource jumphostVM 'Microsoft.Compute/virtualMachines@2023-03-01' = [for (user, idx) in users: {
  name: 'jumphost-${user.ime}.${user.prezime}'
  location: location
  tags: { course: courseTag }
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1s' }
    osProfile: {
      computerName: 'jumphost-${user.ime}.${user.prezime}'
      adminUsername: 'azureuser'
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [
          {
            path: '/home/azureuser/.ssh/authorized_keys'
            keyData: sshKey
          }
        ]}
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: jumphostNic[idx].id
        }
      ]
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-focal'
        sku: '20_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
      }
    }
  }
}]

resource wpNic 'Microsoft.Network/networkInterfaces@2022-11-01' = [for (user, idx) in users: [
  for vm in range(1,5): {
    name: 'wp${vm}-${user.ime}.${user.prezime}-nic'
    location: location
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet::subnets[idx].id
          }
        }
      }
    ]
    tags: { course: courseTag }
  }
]]

resource wpVM 'Microsoft.Compute/virtualMachines@2023-03-01' = [for (user, idx) in users: [
  for vm in range(1,5): {
    name: 'wp${vm}-${user.ime}.${user.prezime}'
    location: location
    tags: { course: courseTag }
    properties: {
      hardwareProfile: { vmSize: 'Standard_B1s' }
      osProfile: {
        computerName: 'wp${vm}-${user.ime}.${user.prezime}'
        adminUsername: 'azureuser'
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: { publicKeys: [
            {
              path: '/home/azureuser/.ssh/authorized_keys'
              keyData: sshKey
            }
          ]}
        }
        customData: base64(loadTextContent('cloud-init-blob.yaml'))
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: wpNic[idx * 4 + (vm-1)].id
          }
        ]
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-focal'
          sku: '20_04-lts'
          version: 'latest'
        }
        osDisk: { createOption: 'FromImage' }
        dataDisks: [
          for d in range(1, 3): {
            lun: d-1
            createOption: 'Empty'
            diskSizeGB: 1
          }
        ]
      }
    }
  }
]]

output jumphostPublicIPs array = [for (user, idx) in users: {
  user: '${user.ime}.${user.prezime}'
  publicIP: jumphostPIP[idx].properties.ipAddress
}]

output wpPrivateIPs array = [for (user, idx) in users: [
  for vm in range(1,5): {
    vm: 'wp${vm}-${user.ime}.${user.prezime}'
    privateIP: wpNic[idx * 4 + (vm-1)].properties.ipConfigurations[0].properties.privateIPAddress
  }
]]

output storageAccounts array = [for (user, idx) in users: {
  user: '${user.ime}.${user.prezime}'
  storageAccount: storage[idx].name
}]
