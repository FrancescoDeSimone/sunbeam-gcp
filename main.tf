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
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

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
  description = "Path to your *private* SSH key (e.g., '~/.ssh/id_ed25519'). The .pub will be added automatically."
  type        = string
  default     = "~/.ssh/id_rsa"
}

data "local_file" "ssh_key_pub" {
  filename = "${var.ssh_key_path}.pub"
}

data "google_compute_image" "ubuntu_noble" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

resource "google_compute_image" "sunbeam_image" {
  name         = "ubuntu-2404-multi-ip-subnet"
  source_image = data.google_compute_image.ubuntu_noble.self_link

  guest_os_features {
    type = "MULTI_IP_SUBNET"
  }

  # Ensure the base image is read before trying to create a new one from it
  depends_on = [data.google_compute_image.ubuntu_noble]
}
resource "google_compute_network" "sunbeam_control_vpc" {
  name                    = "sunbeam-control-vpc"
  auto_create_subnetworks = false
}

# VPC for the external network
resource "google_compute_network" "sunbeam_external_vpc" {
  name                    = "sunbeam-external-vpc"
  auto_create_subnetworks = false
}

# Control-plane subnet (internal communication)
resource "google_compute_subnetwork" "sunbeam_control_plane" {
  name          = "sunbeam-control-plane-subnet"
  ip_cidr_range = "10.10.10.0/26"
  region        = var.region
  network       = google_compute_network.sunbeam_control_vpc.id
}

# External subnet (east-west or north-south traffic)
resource "google_compute_subnetwork" "sunbeam_external" {
  name          = "sunbeam-external-subnet"
  ip_cidr_range = "10.10.20.0/26"
  region        = var.region
  network       = google_compute_network.sunbeam_external_vpc.id
}

# -----------------------------------------------------------------------------
# FIREWALL RULES
# -----------------------------------------------------------------------------

# Internal communication within control-plane VPC
resource "google_compute_firewall" "allow_internal_control" {
  name    = "sunbeam-allow-internal-control"
  network = google_compute_network.sunbeam_control_vpc.name
  allow {
    protocol = "all"
  }
  source_tags = ["sunbeam-node"]
  target_tags = ["sunbeam-node"]
}

# Allow SSH into control-plane NICs
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

# Allow all traffic inside external network (optional)
resource "google_compute_firewall" "allow_internal_external" {
  name    = "sunbeam-allow-internal-external"
  network = google_compute_network.sunbeam_external_vpc.name
  allow {
    protocol = "all"
  }
  source_tags = ["sunbeam-node"]
  target_tags = ["sunbeam-node"]
}

# -----------------------------------------------------------------------------
# VIRTUAL MACHINES
# -----------------------------------------------------------------------------

# Create the attachable disks for Ceph
resource "google_compute_disk" "ceph_disk" {
  count = 3
  name  = "sunbeam-ceph-disk-${count.index + 1}"
  type  = "pd-ssd"
  size  = 500 // 500 GiB
  zone  = var.zone
}

# -----------------------------------------------------------------------------
# VIRTUAL MACHINES — FIXED NIC & AUTH CONFIG
# -----------------------------------------------------------------------------

resource "google_compute_instance" "sunbeam_node" {
  count          = 3
  name           = "sunbeam-node-${count.index + 1}"
  hostname       = "sunbeam-node-${count.index + 1}.cluster.local"
  machine_type   = "n1-custom-16-32768" # 16 vCPU, 32 GB RAM
  zone           = var.zone
  tags           = ["sunbeam-node"]
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image = google_compute_image.sunbeam_image.self_link
      size  = 500
      type  = "pd-ssd"
    }
  }

  attached_disk {
    source      = google_compute_disk.ceph_disk[count.index].id
    device_name = "ceph-disk" 
  }

  # NIC 0 — Control-plane network (with external IP for SSH)
  network_interface {
    subnetwork = google_compute_subnetwork.sunbeam_control_plane.id
    nic_type   = "GVNIC"
    access_config {
      # This NIC gets an external IP for SSH access
    }
  }

  # NIC 1 — External network (no external IP)
  network_interface {
    subnetwork = google_compute_subnetwork.sunbeam_external.id
    nic_type   = "GVNIC"
  }

  metadata = {
    # 1. Point to the cloud-init script (which now *only* does networking)
    #user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    #  # Pass only the node_index, which is all it needs
    #  node_index = count.index + 1
    #})

    ssh-keys = "${var.ssh_user}:${data.local_file.ssh_key_pub.content}"

    enable-oslogin = "FALSE"
  }

  allow_stopping_for_update = true

  depends_on = [
    google_compute_image.sunbeam_image,
    google_compute_disk.ceph_disk
  ]
}

# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------

output "sunbeam_node_ips" {
  description = "External IPs of the Sunbeam nodes for SSH access"
  value = [
    for instance in google_compute_instance.sunbeam_node : instance.network_interface[0].access_config[0].nat_ip
  ]
}

output "sunbeam_node_internal_ips" {
  description = "Internal Static IPs of the Sunbeam nodes (Control Plane)"
  value = [
    for i in range(3) : "10.10.10.1${i + 1}"
  ]
}
