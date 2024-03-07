terraform {
  required_providers {
    google = {
      source    = "hashicorp/google"
      version   = "4.47.0"
    }
  }
}

provider "google" {
  project   = var.project_id
  region    = var.region
  zone      = var.zone
}

# API
resource "google_project_service" "compute" {
  service = "compute.googleapis.com"
}
resource "google_project_service" "container" {
  service = "container.googleapis.com"
}
resource "google_project_service" "cloudresourcemanager" {
  service = "cloudresourcemanager.googleapis.com"
}

# Service Account For Bastion Host
resource "google_service_account" "bastion_svc_account" {
    account_id      = "bastion-svc-account"
    display_name   = "bastion-svc-account"
}
# Service Account For GKE
resource "google_service_account" "k8s_svc_account" {
  account_id   = "k8s-svc-account"
  display_name = "k8s-svc-account"
}

# VPC
resource "google_compute_network" "private_vpc" {
  name                      = "private-vpc"
  auto_create_subnetworks   = false
  project                   = var.project_id
  routing_mode              = "REGIONAL"

  depends_on = [ 
    google_project_service.compute,
    google_project_service.container,
    google_project_service.cloudresourcemanager
  ]
}

# Subnet for bastion host
resource "google_compute_subnetwork" "bastion_subnet" {
  name          = "k8s-subnet"
  project       = var.project_id
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.private_vpc.id
}

# Subnet for k8s
resource "google_compute_subnetwork" "k8s_subnet" {
  name          = "k8s-subnet"
  project       = var.project_id
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.private_vpc.id
}

# Router for Nat Gateway
resource "google_compute_router" "router" {
  name    = "router"
  region  = var.region
  project = var.project_id
  network = google_compute_network.private_vpc.id
}

# NAT GateWay
resource "google_compute_router_nat" "nat" {
  name                               = "router-nat"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  depends_on = [ google_compute_subnetwork.k8s_subnet, google_compute_subnetwork.bastion_subnet ]
}



# GKE Control Plane
resource "google_container_cluster" "private_gke" {
  name     = var.gke_name
  location = var.region

  networking_mode   = "VPC_NATIVE"
  network           = google_compute_network.private_vpc.self_link
  subnetwork        = google_compute_subnetwork.k8s_subnet.self_link

  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = "REGULAR"
  }

  private_cluster_config {
      enable_private_nodes      = true
      enable_private_endpoint   = false
      master_ipv4_cidr_block    = "172.16.0.0/28"
  }
}

data "google_container_cluster" "private_gke_data" {
  name = var.gke_name
  project = var.project_id
  location = var.region

  depends_on = [ google_container_cluster.private_gke ]
}

# GKE pool nodes
resource "google_container_node_pool" "nodes_pool" {
  name          = "gke-node-pool"
  location      = var.region
  project       = var.project_id
  cluster       = google_container_cluster.private_gke.name
  node_count    = 1

  management {
    auto_repair = true
    auto_upgrade = true
  }

  node_config {
    machine_type = "n1-standard-2"

    service_account = google_service_account.k8s_svc_account.email
    oauth_scopes    = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

# FireWall
resource "google_compute_firewall" "bastion_firewall" {
  name    = "bastion-firewall"
  network = google_compute_network.private_vpc.name
  source_ranges = ["0.0.0.0/0"]

  allow {
      protocol = "tcp"
      ports = ["22"]
  }
}

# Bastion Host
resource "google_compute_instance" "bastion_host" {
    name = var.bastion_name
    machine_type = "e2-medium"

    boot_disk {
        initialize_params {
            image = "debian-cloud/debian-11"
        }
    }
    scratch_disk {
        interface = "NVME"
    }

    network_interface {
        network     = google_compute_network.private_vpc.self_link
        subnetwork  = google_compute_subnetwork.bastion_subnet.self_link 
        access_config {} # Enable Public IP Address
    }

    metadata_startup_script = <<EOF
    #!/bin/bash
    apt update -y
    apt install curl -y
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

    # KUBECONFIG 
    echo '${base64decode(data.google_container_cluster.private_gke_data.master_auth.0.cluster_ca_certificate)}' > /home/$USER/.kube/config
    chown $USER: /home/$USER/.kube/config
    EOF

    service_account {
        email  = google_service_account.bastion_svc_account.email
        scopes = ["cloud-platform"]
    }

    depends_on = [ google_compute_firewall.bastion_firewall, google_container_node_pool.nodes_pool ]
}
