variable "tenancy_ocid" {
    description = "OCI tenancy OCID"
    type        = string
}

variable "user_ocid" {
    description = "OCI user OCID"
    type        = string
}

variable "fingerprint" {
    description = "API key fingerprint"
    type        = string
}

variable "private_key_path" {
    description = "Path to OCI API private key"
    type        = string
    default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
    description = "OCI region"
    type        = string
    default     = "eu-stockholm-1"
}

variable "compartment_ocid" {
    description = "Compartment OCID (use tenancy OCID for root compartment)"
    type        = string
}

variable "ssh_public_key_path" {
    description = "Path to SSH public key for instance access"
    type        = string
    default     = "~/.ssh/id_ed25519.pub"
}

variable "instance_shape" {
    description = "Compute shape"
    type        = string
    default     = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
    description = "Number of OCPUs"
    type        = number
    default     = 4
}

variable "instance_memory_gb" {
    description = "Memory in GB"
    type        = number
    default     = 24
}
