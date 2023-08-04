############################################################################################################################
# Terraform Module to install a ASAv using BYOL in Multiple AZ using BYOL Image with Mgmt + Three Subnets
############################################################################################################################

#########################################################################################################################
# Data
#########################################################################################################################

data "azurerm_virtual_network" "asav" {
  count               = var.create_vn ? 0 : 1
  name                = local.vn_name
  resource_group_name = local.rg_name
}

locals {
  rg_name = var.create_rg ? azurerm_resource_group.asav[0].name : var.rg_name
  vn_name = var.create_vn ? azurerm_virtual_network.asav[0].name : var.vn_name
  subnet_list = {
    "mgmt"     = 0
    "external" = 1
    "internal" = 2
  }
  az_distribution = chunklist(sort(flatten(chunklist(setproduct(range(var.instances), var.azs), var.instances)[0])), var.instances)[1]
  vn_cidr         = var.create_vn ? var.vn_cidr : data.azurerm_virtual_network.asav[0].address_space
  subnet_newbits  = var.subnet_size - tonumber(split("/", local.vn_cidr)[1])
}

################################################################################################################################
# Resource Group Creation
################################################################################################################################

resource "azurerm_resource_group" "asav" {
  count    = var.create_rg ? 1 : 0
  name     = var.rg_name
  location = var.location
}

#########################################################################################################################
# Virtual Network and Subnet Creation
#########################################################################################################################

resource "azurerm_virtual_network" "asav" {
  count               = var.vn_name == "" ? 1 : 0
  name                = "${var.prefix}-network"
  location            = var.location
  resource_group_name = local.rg_name
  address_space       = [var.vn_cidr]
}

resource "azurerm_subnet" "subnets" {
  for_each             = local.subnet_list
  name                 = "${each.key}-subnet"
  resource_group_name  = local.rg_name
  virtual_network_name = local.vn_name
  address_prefixes     = var.subnets == [] ? [cidrsubnet(local.vn_cidr, local.subnet_newbits, each.value + 2)] : [var.subnets[each.value]]
}

################################################################################################################################
# Route Table Creation and Route Table Association
################################################################################################################################

resource "azurerm_route_table" "asav" {
  for_each            = local.subnet_list
  name                = "${var.prefix}-${each.key}"
  location            = var.location
  resource_group_name = local.rg_name
}

resource "azurerm_route" "internal" {
  name                   = "internal"
  resource_group_name    = local.rg_name
  route_table_name       = azurerm_route_table.asav["internal"].name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.instances > 1 ? (azurerm_lb.asa-ilb[0].private_ip_address) : (azurerm_network_interface.asav-inside[0].private_ip_address)
}

resource "azurerm_subnet_route_table_association" "asav" {
  for_each       = local.subnet_list
  subnet_id      = azurerm_subnet.subnets[each.key].id
  route_table_id = azurerm_route_table.asav[each.key].id
}

################################################################################################################################
# Network Security Group Creation
################################################################################################################################

resource "azurerm_network_security_group" "allow-all" {
  name                = "${var.prefix}-allow-all"
  location            = var.location
  resource_group_name = local.rg_name

  security_rule {
    name                       = "TCP-Allow-All"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.source_address
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "ilb-allow-all" {
  name                = "${var.prefix}-ilb-allow-all"
  location            = var.location
  resource_group_name = local.rg_name

  security_rule {
    name                       = "TCP-Allow-All-Internal-Inbound"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.source_address
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "TCP-Allow-All-Internal-Outbound"
    priority                   = 1001
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.source_address
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "elb-allow-all" {
  name                = "${var.prefix}-elb-allow-all"
  location            = var.location
  resource_group_name = local.rg_name

  security_rule {
    name                       = "TCP-Allow-All-External-Inbound"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.source_address
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "TCP-Allow-All-External-Outbound"
    priority                   = 1001
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.source_address
    destination_address_prefix = "*"
  }
}


################################################################################################################################
# Network Interface Creation, Public IP Creation and Network Security Group Association
################################################################################################################################

resource "azurerm_public_ip" "asav-mgmt-interface" {
  name                = "${var.prefix}-instance-public-ip%{if var.instances > 1}${count.index}%{endif}"
  count               = var.instances
  location            = var.location
  sku                 = var.instances > 1 ? "Standard" : "Basic"
  resource_group_name = local.rg_name
  allocation_method   = var.instances > 1 ? "Static" : "Dynamic"
}

resource "azurerm_network_interface" "asav-mgmt" {
  name                = "${var.prefix}-mgmt%{if var.instances > 1}${count.index}%{endif}"
  count               = var.instances
  location            = var.location
  resource_group_name = local.rg_name

  ip_configuration {
    name                          = "mgmt%{if var.instances > 1}${count.index}%{endif}"
    subnet_id                     = azurerm_subnet.subnets["mgmt"].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.asav-mgmt-interface[count.index].id
  }
}


resource "azurerm_network_interface_security_group_association" "ASAv_MGMT_NSG" {
  count                     = var.instances
  network_interface_id      = azurerm_network_interface.asav-mgmt[count.index].id
  network_security_group_id = azurerm_network_security_group.allow-all.id
}


resource "azurerm_network_interface" "asav-outside" {
  name                 = "${var.prefix}-outside%{if var.instances > 1}${count.index}%{endif}"
  count                = var.instances
  location             = var.location
  resource_group_name  = local.rg_name
  enable_ip_forwarding = true
  ip_configuration {
    name                          = "Outside%{if var.instances > 1}${count.index}%{endif}"
    subnet_id                     = azurerm_subnet.subnets["external"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "ASAv_Outside_NSG" {
  count                     = var.instances
  network_interface_id      = azurerm_network_interface.asav-outside[count.index].id
  network_security_group_id = azurerm_network_security_group.elb-allow-all.id
}

resource "azurerm_network_interface" "asav-inside" {
  name                 = "${var.prefix}-inside%{if var.instances > 1}${count.index}%{endif}"
  count                = var.instances
  location             = var.location
  resource_group_name  = local.rg_name
  enable_ip_forwarding = true
  ip_configuration {
    name                          = "Inside%{if var.instances > 1}${count.index}%{endif}"
    subnet_id                     = azurerm_subnet.subnets["internal"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "ASAv_Inside_NSG" {
  count                     = var.instances
  network_interface_id      = azurerm_network_interface.asav-inside[count.index].id
  network_security_group_id = azurerm_network_security_group.ilb-allow-all.id
}

################################################################################################################################
# ASAv Instance Creation
################################################################################################################################

resource "azurerm_virtual_machine" "asav-instance" {
  name                = "${var.prefix}-vm%{if var.instances > 1}${count.index}%{endif}"
  count               = var.instances
  location            = var.location
  resource_group_name = local.rg_name

  primary_network_interface_id = azurerm_network_interface.asav-mgmt[count.index].id
  network_interface_ids = [azurerm_network_interface.asav-mgmt[count.index].id, azurerm_network_interface.asav-outside[count.index].id,
  azurerm_network_interface.asav-inside[count.index].id]
  vm_size = var.vm_size


  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true

  plan {
    name      = "asav-azure-byol"
    publisher = "cisco"
    product   = "cisco-asav"
  }

  storage_image_reference {
    publisher = "cisco"
    offer     = "cisco-asav"
    sku       = "asav-azure-byol"
    version   = var.image_version
  }
  storage_os_disk {
    name              = "${var.prefix}-myosdisk%{if var.instances > 1}${count.index}%{endif}"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "${var.instancename}%{if var.instances > 1}${count.index}%{endif}"
    admin_username = var.username
    admin_password = var.password
    custom_data    = templatefile("ASA_Running_Config.txt", {})
  }
  os_profile_linux_config {
    disable_password_authentication = false

  }
  zones = var.instances == 1 ? [] : [local.az_distribution[count.index]]
}

################################################################################################################################
# Internal LB Creation
################################################################################################################################

resource "azurerm_lb" "asa-ilb" {
  count               = var.instances > 1 ? 1 : 0
  name                = "ASA-ILB"
  location            = var.location
  resource_group_name = local.rg_name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "InternalIPAddress"
    subnet_id                     = azurerm_subnet.subnets["internal"].id
    private_ip_address            = cidrhost(azurerm_subnet.subnets["internal"].address_prefixes[0], 100)
    private_ip_address_allocation = "Static"
  }
}

resource "azurerm_lb_backend_address_pool" "ILB-Backend-Pool" {
  count           = var.instances > 1 ? 1 : 0
  loadbalancer_id = azurerm_lb.asa-ilb[0].id
  name            = "BackEndAddressPool"
}

resource "azurerm_lb_backend_address_pool_address" "ILB-Backend-Address" {
  count                   = var.instances > 1 ? var.instances : 0
  name                    = "ILB-Backend-Address%{if var.instances > 1}${count.index}%{endif}"
  backend_address_pool_id = azurerm_lb_backend_address_pool.ILB-Backend-Pool[0].id
  virtual_network_id      = var.create_vn ? azurerm_virtual_network.asav[0].id : data.azurerm_virtual_network.asav[0].id
  ip_address              = azurerm_network_interface.asav-inside[count.index].private_ip_address
}

resource "azurerm_lb_probe" "ASA-ILB-Probe" {
  count               = var.instances > 1 ? 1 : 0
  resource_group_name = local.rg_name
  loadbalancer_id     = azurerm_lb.asa-ilb[0].id
  name                = "ssh-running-probe"
  port                = 22
}

resource "azurerm_lb_rule" "ilbrule" {
  count                          = var.instances > 1 ? 1 : 0
  resource_group_name            = local.rg_name
  loadbalancer_id                = azurerm_lb.asa-ilb[0].id
  name                           = "ILBRule"
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "InternalIPAddress"
  //backend_address_pool_ids       = [azurerm_lb_backend_address_pool.ILB-Backend-Pool[0].id]
  probe_id = azurerm_lb_probe.ASA-ILB-Probe[0].id
}

################################################################################################################################
# External LB Creation
################################################################################################################################

resource "azurerm_public_ip" "ELB-PublicIP" {
  count               = var.instances > 1 ? 1 : 0
  name                = "PublicIPForLB"
  location            = var.location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "asa-elb" {
  count               = var.instances > 1 ? 1 : 0
  name                = "ASA-ELB"
  location            = var.location
  resource_group_name = local.rg_name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "ExternalIPAddress"
    public_ip_address_id = azurerm_public_ip.ELB-PublicIP[0].id
  }
}

resource "azurerm_lb_backend_address_pool" "ELB-Backend-Pool" {
  count           = var.instances > 1 ? 1 : 0
  loadbalancer_id = azurerm_lb.asa-elb[0].id
  name            = "BackEndAddressPool"
}

resource "azurerm_lb_backend_address_pool_address" "ELB-Backend-Address" {
  count                   = var.instances > 1 ? var.instances : 0
  name                    = "ELB-Backend-Address%{if var.instances > 1}${count.index}%{endif}"
  backend_address_pool_id = azurerm_lb_backend_address_pool.ELB-Backend-Pool[0].id
  virtual_network_id      = var.create_vn ? azurerm_virtual_network.asav[0].id : data.azurerm_virtual_network.asav[0].id
  ip_address              = azurerm_network_interface.asav-outside[count.index].private_ip_address
}

resource "azurerm_lb_probe" "ASA-ELB-Probe" {
  count               = var.instances > 1 ? 1 : 0
  resource_group_name = local.rg_name
  loadbalancer_id     = azurerm_lb.asa-elb[0].id
  name                = "ssh-running-probe"
  port                = 22
}

resource "azurerm_lb_rule" "elbrule" {
  count                          = var.instances > 1 ? 1 : 0
  resource_group_name            = local.rg_name
  loadbalancer_id                = azurerm_lb.asa-elb[0].id
  name                           = "ELBRule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "ExternalIPAddress"
  //backend_address_pool_ids        = [azurerm_lb_backend_address_pool.ELB-Backend-Pool[0].id]
  probe_id = azurerm_lb_probe.ASA-ELB-Probe[0].id
}
