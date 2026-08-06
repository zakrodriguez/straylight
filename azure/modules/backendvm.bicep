// Backend VM for the load-balancing labs: burstable Ubuntu with a tiny
// hostname web server on :80, seeded by cloud-init, and its NIC wired into a
// load balancer or application gateway backend pool. The web server is pure
// stdlib python3 (no package install) so the VM needs NO outbound internet —
// Standard LB backends have none by default. Serving the hostname lets the
// labs prove distribution/routing with a plain `curl`.
param location string
param tags object = {}
param name string
param subnetId string
// Backend pool this VM's NIC joins. For Standard LB pass the LB's
// backendAddressPools[] id; for App Gateway pass the gateway's
// backendAddressPools[] id. Either wires ipconfig -> pool.
param lbBackendPoolIds array = []
param appgwBackendPoolIds array = []
@allowed(['Standard_B2ts_v2', 'Standard_B2als_v2', 'Standard_B1s', 'Standard_B2s'])
param vmSize string = 'Standard_B2ts_v2'
param adminUsername string = 'azureuser'
@secure()
param adminPassword string = newGuid()

// cloud-init: a stdlib hostname web server on :80 via a systemd unit (survives
// reboots; no internet needed). Serving the hostname is what makes `curl` on
// the LB/gateway frontend a real distribution/routing proof.
var cloudInit = '''
#cloud-config
write_files:
  - path: /opt/labweb.py
    permissions: '0755'
    content: |
      import http.server, socket
      host = socket.gethostname()
      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              self.send_response(200)
              self.send_header('Content-Type', 'text/plain')
              self.end_headers()
              self.wfile.write((host + '\n').encode())
          def log_message(self, *a):
              pass
      http.server.HTTPServer(('', 80), H).serve_forever()
  - path: /etc/systemd/system/labweb.service
    content: |
      [Unit]
      Description=lab hostname web server
      After=network.target
      [Service]
      ExecStart=/usr/bin/python3 /opt/labweb.py
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl daemon-reload
  - systemctl enable --now labweb
'''

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${name}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
          loadBalancerBackendAddressPools: [for id in lbBackendPoolIds: { id: id }]
          applicationGatewayBackendAddressPools: [for id in appgwBackendPoolIds: { id: id }]
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(cloudInit)
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

output vmName string = vm.name
output nicId string = nic.id
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
