terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
  required_version = ">= 1.5"
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# --- Data sources ---

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# --- Networking ---

resource "oci_core_vcn" "searxng" {
  compartment_id = var.compartment_ocid
  display_name   = "searxng-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "searxng"
}

resource "oci_core_internet_gateway" "searxng" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.searxng.id
  display_name   = "searxng-igw"
  enabled        = true
}

resource "oci_core_route_table" "searxng" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.searxng.id
  display_name   = "searxng-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.searxng.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_security_list" "searxng" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.searxng.id
  display_name   = "searxng-sl"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "searxng" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.searxng.id
  display_name               = "searxng-subnet"
  cidr_block                 = "10.0.1.0/24"
  dns_label                  = "searxng"
  route_table_id             = oci_core_route_table.searxng.id
  security_list_ids          = [oci_core_security_list.searxng.id]
  prohibit_public_ip_on_vnic = false
}

# --- Compute ---

resource "oci_core_instance" "searxng" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "searxng"
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.searxng.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
    user_data           = base64encode(file("${path.module}/cloud-init.yml"))
  }
}
