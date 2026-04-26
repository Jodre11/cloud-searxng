output "instance_public_ip" {
    description = "Public IP of the SearXNG instance"
    value       = oci_core_instance.searxng.public_ip
}

output "instance_id" {
    description = "OCID of the compute instance"
    value       = oci_core_instance.searxng.id
}
