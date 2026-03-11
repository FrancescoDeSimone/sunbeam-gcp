# =============================================================================
# Sunbeam-on-GCP — Multi-Node Cluster with Floating IP Access
#
# Architecture:
#   - N Canonical OpenStack (Sunbeam) nodes with control,compute,storage roles
#   - Dual-NIC: nic0 = control plane (SSH), nic1 = raw interface for OVS br-ex
#   - Standard OpenStack networking: SNAT for outbound, floating IPs for inbound
#   - Custom VM image with MULTI_IP_SUBNET allows VMs to handle any IP within
#     the subnet — no GCP alias IPs needed for floating IP traffic
#   - A lightweight GCP test VM (Spot) can reach OpenStack VMs via floating IPs
#   - Node-1 bootstraps the cluster, generates join tokens for nodes 2+
#   - Join nodes SSH-poll node-1 for their token, then join the cluster
#   - After all nodes join: configure, enable features, launch test VM
#
# Features enabled (post-bootstrap, all toggleable via variables):
#   - Telemetry (aodh, gnocchi, ceilometer, openstack-exporter)
#   - DNS (Designate)
#   - Resource Optimization (Watcher)
#   - Observability Embedded (COS Lite: Grafana, Prometheus, Loki, etc.)
#   - Validation (Tempest) — disabled by default
#
# Cost notes:
#   - Sunbeam nodes use standard on-demand VMs (no preemption risk during
#     the ~60-90min bootstrap+join+features pipeline)
#   - Boot disks: 100GB pd-balanced (10x better IOPS than pd-standard,
#     significantly faster snap installs and K8s bootstrap)
#   - Ceph disks: 30GB pd-standard (demo workloads only)
#   - Test VM: Spot e2-micro (disposable)
#   - REMEMBER to 'terraform destroy' after demos to avoid idle costs!
# =============================================================================

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# VARIABLES
# -----------------------------------------------------------------------------

variable "project_id" {
  description = "Your GCP Project ID."
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources in."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone to deploy resources in."
  type        = string
  default     = "us-central1-a"
}

variable "ssh_user" {
  description = "The username to create on the instances (e.g., 'ubuntu')."
  type        = string
}

variable "ssh_key_path" {
  description = "Path to your *private* SSH key. The .pub extension is appended automatically."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "node_count" {
  description = "Number of Sunbeam nodes. Use 3 for HA (minimum for quorum)."
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 10
    error_message = "node_count must be between 1 and 10."
  }
}

variable "machine_type" {
  description = "GCE machine type. Must be N1-series for nested virtualisation + GVNIC."
  type        = string
  default     = "n1-standard-8"
}

variable "boot_disk_size" {
  description = "Boot disk size in GB. 100GB minimum recommended — Sunbeam's rawfile-csi reserves full PVC capacity (Juju controller alone claims 20Gi)."
  type        = number
  default     = 100
}

variable "boot_disk_type" {
  description = "Boot disk type (pd-standard, pd-balanced, pd-ssd). pd-balanced recommended for 10x better IOPS during deployment."
  type        = string
  default     = "pd-balanced"
}

variable "ceph_disk_size" {
  description = "Ceph OSD disk size in GB."
  type        = number
  default     = 30
}

variable "ceph_disk_type" {
  description = "Ceph OSD disk type (pd-standard, pd-balanced, pd-ssd)."
  type        = string
  default     = "pd-standard"
}

variable "snap_channel" {
  description = "Snap channel for the openstack snap (e.g. 2024.1/stable, 2025.1/edge)."
  type        = string
  default     = "2024.1/stable"
}

variable "os_tenant_cidr" {
  description = "The OpenStack tenant subnet CIDR (used by Sunbeam demo setup). With SNAT enabled, this is only used internally by OpenStack — no GCP route needed."
  type        = string
  default     = "192.168.100.0/24"
}

variable "provider_fip_cidr" {
  description = <<-EOT
    CIDR for OpenStack's external network (floating IPs). Must be OUTSIDE the
    GCP external subnet range (10.10.20.0/26) so GCP treats it as routed traffic
    rather than intra-subnet. A GCP route sends this CIDR to node-1, whose kernel
    forwards it into OVS br-ex where OVN handles DNAT to tenant VMs.
  EOT
  type        = string
  default     = "10.20.20.0/24"
}

variable "enable_tempest" {
  description = "Enable Tempest validation (adds ~15-20 min to setup). Set to true to run refstack suite."
  type        = bool
  default     = false
}

variable "enable_telemetry" {
  description = "Enable Telemetry (Aodh, Gnocchi, Ceilometer, openstack-exporter). Adds ~10-15 min. Required before observability and resource-optimization."
  type        = bool
  default     = true
}

variable "enable_dns" {
  description = "Enable DNS (Designate). Adds ~5-10 min."
  type        = bool
  default     = true
}

variable "enable_resource_optimization" {
  description = "Enable Resource Optimization (Watcher). Adds ~5-10 min. Requires telemetry."
  type        = bool
  default     = true
}

variable "enable_observability" {
  description = "Enable Observability Embedded (COS Lite: Grafana, Prometheus, Loki). Adds ~15-25 min. Requires telemetry."
  type        = bool
  default     = true
}

variable "enable_shared_filesystem" {
  description = "Enable Shared Filesystem (Manila with CephFS NFS backend). Adds ~10-15 min. Experimental feature gate."
  type        = bool
  default     = true
}

variable "enable_loadbalancer" {
  description = "Enable Load Balancer (Octavia with OVN provider driver). Adds ~10-15 min."
  type        = bool
  default     = true
}

variable "enable_demo_env" {
  description = "Deploy a full demo environment (domains, projects, users, VMs, networks, LB, DNS zones, volumes, shares, object storage) using OpenStack Terraform provider on node-1. Adds ~10-15 min after all features are enabled."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# LOCALS — Derived values used across resources
# -----------------------------------------------------------------------------

locals {
  # Hostnames for all nodes (used in manifest nics + microceph_config)
  all_hostnames = [
    for i in range(var.node_count) :
    "sunbeam-node-${i + 1}.cluster.local"
  ]

  # Deterministic control-plane IPs — reserved via google_compute_address
  # so we know them at plan time (before instances are created).
  # GCP DHCP does NOT assign IPs sequentially — we MUST reserve them.
  all_control_ips = [
    for i in range(var.node_count) :
    google_compute_address.sunbeam_control_ip[i].address
  ]

  # Floating IP network — derived from provider_fip_cidr
  # Gateway is .1 (first usable host), allocation pool starts at .20 to .50
  fip_prefix  = split("/", var.provider_fip_cidr)[1]
  fip_gateway = cidrhost(var.provider_fip_cidr, 1)
  fip_range   = "${cidrhost(var.provider_fip_cidr, 20)}-${cidrhost(var.provider_fip_cidr, 50)}"
}

# NOTE: No GCP alias IPs are needed for floating IPs. MULTI_IP_SUBNET on the
# VM image + can_ip_forward allows VMs to handle any IP within the subnet.
# OVN manages floating IP assignment and ARP responses internally.

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------

data "local_file" "ssh_key_pub" {
  filename = "${var.ssh_key_path}.pub"
}

# Read the private key so we can embed it in cloud-init for inter-node SSH
data "local_file" "ssh_key_priv" {
  filename = var.ssh_key_path
}

data "google_compute_image" "ubuntu_noble" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

# Custom image with MULTI_IP_SUBNET — allows the VM to send/receive packets
# with IPs outside its GCP-assigned range (required for nested OpenStack VMs).
resource "google_compute_image" "sunbeam_image" {
  name         = "ubuntu-2404-multi-ip-subnet"
  source_image = data.google_compute_image.ubuntu_noble.self_link

  guest_os_features {
    type = "MULTI_IP_SUBNET"
  }

  depends_on = [data.google_compute_image.ubuntu_noble]
}

# -----------------------------------------------------------------------------
# NETWORKING — VPCs & SUBNETS
# -----------------------------------------------------------------------------

# Control-plane VPC (Sunbeam internal + SSH access)
resource "google_compute_network" "sunbeam_control_vpc" {
  name                    = "sunbeam-control-vpc"
  auto_create_subnetworks = false
}

# External/provider VPC (OpenStack north-south traffic)
resource "google_compute_network" "sunbeam_external_vpc" {
  name                    = "sunbeam-external-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "sunbeam_control_plane" {
  name          = "sunbeam-control-plane-subnet"
  ip_cidr_range = "10.10.10.0/26"
  region        = var.region
  network       = google_compute_network.sunbeam_control_vpc.id
}

resource "google_compute_subnetwork" "sunbeam_external" {
  name          = "sunbeam-external-subnet"
  ip_cidr_range = "10.10.20.0/26"
  region        = var.region
  network       = google_compute_network.sunbeam_external_vpc.id
}

# -----------------------------------------------------------------------------
# RESERVED INTERNAL IPs — Control-plane (deterministic assignment)
#
# GCP DHCP does NOT assign IPs sequentially — without reservations, node-1
# might get .3 while node-3 gets .2. We reserve static internal IPs so
# cloud-init templates can reference correct IPs at plan time.
# -----------------------------------------------------------------------------

resource "google_compute_address" "sunbeam_control_ip" {
  count        = var.node_count
  name         = "sunbeam-node-${count.index + 1}-control-ip"
  subnetwork   = google_compute_subnetwork.sunbeam_control_plane.id
  address_type = "INTERNAL"
  region       = var.region
}

# -----------------------------------------------------------------------------
# FIREWALL RULES
# -----------------------------------------------------------------------------

# --- Control-plane VPC ---

# Allow all internal traffic between Sunbeam nodes
resource "google_compute_firewall" "allow_internal_control" {
  name    = "sunbeam-allow-internal-control"
  network = google_compute_network.sunbeam_control_vpc.name
  allow {
    protocol = "all"
  }
  source_tags = ["sunbeam-node"]
  target_tags = ["sunbeam-node"]
}

# Allow SSH from anywhere into the control-plane NIC
resource "google_compute_firewall" "allow_ssh_control" {
  name    = "sunbeam-allow-ssh-control"
  network = google_compute_network.sunbeam_control_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["sunbeam-node"]
}

# --- External VPC ---

# Allow all traffic between Sunbeam nodes on the external VPC (tag-based)
resource "google_compute_firewall" "allow_internal_external" {
  name    = "sunbeam-allow-internal-external"
  network = google_compute_network.sunbeam_external_vpc.name
  allow {
    protocol = "all"
  }
  source_tags = ["sunbeam-node"]
  target_tags = ["sunbeam-node"]
}

# Allow traffic FROM the external subnet CIDR and floating IP CIDR.
resource "google_compute_firewall" "allow_provider_net_traffic" {
  name    = "sunbeam-allow-provider-net"
  network = google_compute_network.sunbeam_external_vpc.name
  allow {
    protocol = "all"
  }
  source_ranges = ["10.10.20.0/26", var.provider_fip_cidr]
}

# Allow SSH into the test VM
resource "google_compute_firewall" "allow_ssh_test_vm" {
  name    = "sunbeam-allow-ssh-test-vm"
  network = google_compute_network.sunbeam_external_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["test-vm"]
}

# Allow ICMP into the external VPC from anywhere (for ping testing)
resource "google_compute_firewall" "allow_icmp_external" {
  name    = "sunbeam-allow-icmp-external"
  network = google_compute_network.sunbeam_external_vpc.name
  allow {
    protocol = "icmp"
  }
  source_ranges = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# CEPH DISKS
# -----------------------------------------------------------------------------

resource "google_compute_disk" "ceph_disk" {
  count = var.node_count
  name  = "sunbeam-ceph-disk-${count.index + 1}"
  type  = var.ceph_disk_type
  size  = var.ceph_disk_size
  zone  = var.zone
}

# -----------------------------------------------------------------------------
# SUNBEAM COMPUTE INSTANCES
# -----------------------------------------------------------------------------

resource "google_compute_instance" "sunbeam_node" {
  count        = var.node_count
  name         = "sunbeam-node-${count.index + 1}"
  hostname     = "sunbeam-node-${count.index + 1}.cluster.local"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["sunbeam-node"]

  can_ip_forward = true

  scheduling {
    automatic_restart = true
  }

  boot_disk {
    initialize_params {
      image = google_compute_image.sunbeam_image.self_link
      size  = var.boot_disk_size
      type  = var.boot_disk_type
    }
  }

  attached_disk {
    source      = google_compute_disk.ceph_disk[count.index].id
    device_name = "ceph-disk"
  }

  # NIC 0 — Control-plane network (reserved static internal IP + ephemeral external IP for SSH)
  network_interface {
    subnetwork = google_compute_subnetwork.sunbeam_control_plane.id
    network_ip = google_compute_address.sunbeam_control_ip[count.index].address
    nic_type   = "GVNIC"
    access_config {}
  }

  # NIC 1 — External/provider network (no external IP, raw L2 for OVS)
  # No alias IPs needed — MULTI_IP_SUBNET on the image allows the VM to
  # handle floating IP traffic. OVN manages the IP assignment internally.
  network_interface {
    subnetwork = google_compute_subnetwork.sunbeam_external.id
    nic_type   = "GVNIC"
  }

  metadata = {
    # Node-1 (index 0) gets the bootstrap template; nodes 2+ get the join template
    user-data = count.index == 0 ? templatefile("${path.module}/bootstrap.yaml.tftpl", {
      hostname                     = "sunbeam-node-1.cluster.local"
      management_cidr              = google_compute_subnetwork.sunbeam_control_plane.ip_cidr_range
      provider_nic                 = "ens5"
      provider_cidr                = google_compute_subnetwork.sunbeam_external.ip_cidr_range
      provider_gateway             = cidrhost(google_compute_subnetwork.sunbeam_external.ip_cidr_range, 1)
      provider_range               = "${cidrhost(google_compute_subnetwork.sunbeam_external.ip_cidr_range, 20)}-${cidrhost(google_compute_subnetwork.sunbeam_external.ip_cidr_range, 50)}"
      fip_cidr                     = var.provider_fip_cidr
      fip_prefix                   = local.fip_prefix
      fip_gateway                  = local.fip_gateway
      fip_range                    = local.fip_range
      physnet_name                 = "physnet1"
      tenant_cidr                  = var.os_tenant_cidr
      snap_channel                 = var.snap_channel
      all_hostnames                = local.all_hostnames
      node_count                   = var.node_count
      ssh_user                     = var.ssh_user
      ssh_private_key              = data.local_file.ssh_key_priv.content
      all_control_ips              = local.all_control_ips
      enable_tempest               = var.enable_tempest
      enable_telemetry             = var.enable_telemetry
      enable_dns                   = var.enable_dns
      enable_resource_optimization = var.enable_resource_optimization
      enable_observability         = var.enable_observability
      enable_shared_filesystem     = var.enable_shared_filesystem
      enable_loadbalancer          = var.enable_loadbalancer
      enable_demo_env              = var.enable_demo_env
      demo_terraform_config = var.enable_demo_env ? templatefile("${path.module}/demo-openstack.tf.tftpl", {
        enable_shared_filesystem = var.enable_shared_filesystem
        enable_loadbalancer      = var.enable_loadbalancer
        enable_dns               = var.enable_dns
        all_hostnames            = local.all_hostnames
      }) : ""
      }) : templatefile("${path.module}/join.yaml.tftpl", {
      provider_nic         = "ens5"
      provider_cidr        = google_compute_subnetwork.sunbeam_external.ip_cidr_range
      fip_gateway          = local.fip_gateway
      fip_prefix           = local.fip_prefix
      snap_channel         = var.snap_channel
      node_index           = count.index + 1
      ssh_user             = var.ssh_user
      ssh_private_key      = data.local_file.ssh_key_priv.content
      bootstrap_control_ip = google_compute_address.sunbeam_control_ip[0].address
    })

    ssh-keys       = "${var.ssh_user}:${data.local_file.ssh_key_pub.content}"
    enable-oslogin = "FALSE"
  }

  allow_stopping_for_update = true

  depends_on = [
    google_compute_image.sunbeam_image,
    google_compute_disk.ceph_disk,
    google_compute_address.sunbeam_control_ip
  ]
}

# -----------------------------------------------------------------------------
# GCP STATIC ROUTE — K8s Services (MetalLB) Reachability
#
# After bootstrap, Sunbeam deploys a K8s cluster with MetalLB assigning
# LoadBalancer IPs from 172.16.1.201-172.16.1.240. Join nodes must reach
# the Juju controller (172.16.1.201:17070) during 'sunbeam cluster join'.
#
# IMPORTANT: Only ONE route pointing to the bootstrap node (node-1).
# GCP ECMP doesn't work here because:
#   1. During bootstrap, only node-1 has K8s/Cilium — other nodes can't
#      handle MetalLB VIP traffic yet.
#   2. MetalLB L2 mode announces each VIP from exactly one node. GCP has
#      no way to track which node owns a VIP, so ECMP sends 2/3 of
#      traffic to wrong nodes.
#   3. Join nodes also add a local static route (ip route add) pointing
#      172.16.1.0/24 via the bootstrap node's control IP for reliability.
# -----------------------------------------------------------------------------

resource "google_compute_route" "k8s_services_route" {
  name              = "sunbeam-k8s-services-route"
  network           = google_compute_network.sunbeam_control_vpc.name
  dest_range        = "172.16.1.0/24"
  priority          = 100
  next_hop_instance = google_compute_instance.sunbeam_node[0].self_link
  depends_on        = [google_compute_instance.sunbeam_node]
}

# -----------------------------------------------------------------------------
# GCP STATIC ROUTE — Floating IP Reachability (External VPC)
#
# OpenStack's external network uses a CIDR (default 10.20.20.0/24) that is
# OUTSIDE the GCP external subnet (10.10.20.0/26). This is intentional:
#
# - GCP delivers intra-subnet traffic only to IPs assigned to VM NICs.
#   Floating IPs are virtual (managed by OVN) and not assigned to any NIC,
#   so intra-subnet delivery fails silently.
#
# - By using a separate CIDR, traffic to floating IPs is ROUTED by GCP
#   (via this custom route) to node-1's ens5 NIC.
#
# - On node-1, the hypervisor charm adds the gateway IP (10.20.20.1/24)
#   to br-ex in "local mode". The kernel receives the GCP-routed packet,
#   ARPs on br-ex (where OVN responds), and forwards to OVN for DNAT.
#
# - This is a single route to node-1 only (not ECMP) because node-1 is
#   where we set external-bridge-address. In a production setup, this
#   would be HA via OVN gateway chassis failover.
# -----------------------------------------------------------------------------

resource "google_compute_route" "fip_route" {
  name              = "sunbeam-fip-route"
  network           = google_compute_network.sunbeam_external_vpc.name
  dest_range        = var.provider_fip_cidr
  priority          = 100
  next_hop_instance = google_compute_instance.sunbeam_node[0].self_link
  depends_on        = [google_compute_instance.sunbeam_node]
}

# -----------------------------------------------------------------------------
# TEST VM — Lightweight Spot instance to verify floating IP connectivity
# -----------------------------------------------------------------------------

resource "google_compute_instance" "test_vm" {
  name         = "gcp-test-vm"
  machine_type = "e2-micro"
  zone         = var.zone
  tags         = ["test-vm"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu_noble.self_link
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.sunbeam_external.id
    access_config {}
  }

  metadata = {
    ssh-keys       = "${var.ssh_user}:${data.local_file.ssh_key_pub.content}"
    enable-oslogin = "FALSE"
  }

  scheduling {
    preemptible                 = true
    automatic_restart           = false
    provisioning_model          = "SPOT"
    instance_termination_action = "STOP"
  }

  depends_on = [google_compute_subnetwork.sunbeam_external]
}

# -----------------------------------------------------------------------------
# WAIT FOR SUNBEAM — Full Cluster Setup
#
# Polls node-1 for the sentinel file that indicates ALL phases are complete:
# bootstrap, join, configure, features, tempest, GCP fixes, test VM.
# Expected total time: ~60-90 minutes.
# -----------------------------------------------------------------------------

resource "null_resource" "wait_for_sunbeam" {
  triggers = {
    instance_ids = join(",", google_compute_instance.sunbeam_node[*].instance_id)
  }

  connection {
    type        = "ssh"
    user        = var.ssh_user
    private_key = file(var.ssh_key_path)
    host        = google_compute_instance.sunbeam_node[0].network_interface[0].access_config[0].nat_ip
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for ${var.node_count}-node Sunbeam cluster setup to complete...'",
      "echo 'Bootstrap logs: sudo journalctl -u sunbeam-setup.service -f'",
      "echo 'Join node logs: sudo journalctl -u sunbeam-join.service -f'",
      "echo 'Started polling at '$(date -u)",
      "for i in $(seq 1 360); do if [ -f /opt/sunbeam/.all-complete ]; then echo 'All phases complete!'; break; fi; echo \"[$i/360] Still waiting... ($(date -u))\"; sleep 30; done",
      "if [ ! -f /opt/sunbeam/.all-complete ]; then echo 'TIMEOUT: Setup did not complete in 3 hours'; exit 1; fi",
      "echo '=== Final Status ==='",
      "echo '--- Cluster members ---'",
      "sg snap_daemon -c 'sunbeam cluster list' 2>/dev/null || echo 'Could not list cluster'",
      "echo '--- OpenStack servers ---'",
      "source /home/ubuntu/demo-openrc && openstack server list 2>/dev/null || echo 'Could not list servers'",
      "echo '--- OpenStack networks ---'",
      "source /home/ubuntu/demo-openrc && openstack network list 2>/dev/null || echo 'Could not list networks'",
      "echo '--- Router SNAT status ---'",
      "source /home/ubuntu/demo-openrc && openstack router show demo-router -f value -c external_gateway_info 2>/dev/null || echo 'Could not show router'",
      "echo '--- Tempest results ---'",
      "cat /opt/sunbeam/tempest-results.txt 2>/dev/null || echo 'No tempest results file'",
      "echo '=== ${var.node_count}-node Sunbeam cluster fully operational ==='",
      "echo ''",
      "echo 'REMINDER: Run terraform destroy -var-file=var.tfvars when done!'",
    ]
  }

  depends_on = [
    google_compute_instance.sunbeam_node,
  ]
}

# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------

output "sunbeam_node_ssh" {
  description = "SSH commands to connect to each Sunbeam node"
  value = [
    for instance in google_compute_instance.sunbeam_node :
    "ssh -i ${var.ssh_key_path} ${var.ssh_user}@${instance.network_interface[0].access_config[0].nat_ip}"
  ]
}

output "sunbeam_node_external_ips" {
  description = "External (NAT) IPs of the Sunbeam nodes for SSH access"
  value = [
    for instance in google_compute_instance.sunbeam_node :
    instance.network_interface[0].access_config[0].nat_ip
  ]
}

output "sunbeam_node_control_ips" {
  description = "Control-plane IPs (nic0) of the Sunbeam nodes"
  value = [
    for instance in google_compute_instance.sunbeam_node :
    instance.network_interface[0].network_ip
  ]
}

output "sunbeam_node_provider_ips" {
  description = "Provider network IPs (nic1) of the Sunbeam nodes"
  value = [
    for instance in google_compute_instance.sunbeam_node :
    instance.network_interface[1].network_ip
  ]
}

output "test_vm_ssh" {
  description = "SSH command to connect to the GCP test VM"
  value       = "ssh -i ${var.ssh_key_path} ${var.ssh_user}@${google_compute_instance.test_vm.network_interface[0].access_config[0].nat_ip}"
}

output "test_vm_internal_ip" {
  description = "Internal IP of the GCP test VM on the external VPC"
  value       = google_compute_instance.test_vm.network_interface[0].network_ip
}

output "os_tenant_cidr" {
  description = "The OpenStack tenant CIDR (internal to OpenStack, SNATted for outbound)"
  value       = var.os_tenant_cidr
}

output "floating_ip_range" {
  description = "Floating IP range available for OpenStack instances"
  value       = local.fip_range
}

output "horizon_access" {
  description = "How to access the Horizon dashboard via SSH tunnel"
  value       = "Run: ssh -i ${var.ssh_key_path} -L 8443:172.16.1.80:443 ${var.ssh_user}@${google_compute_instance.sunbeam_node[0].network_interface[0].access_config[0].nat_ip} — then open https://localhost:8443 (the actual dashboard IP may differ — check 'sunbeam dashboard-url' on node-1)"
}

output "cost_reminder" {
  description = "Cost reminder — displayed after apply"
  value       = format("REMINDER: %dx %s (~$%.2f/hr). Run 'terraform destroy -var-file=var.tfvars' when done!", var.node_count, var.machine_type, var.node_count * 0.38)
}
