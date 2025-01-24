# Filter instances using AWS CLI and save instance IDs to a file
resource "null_resource" "filter_instances" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = <<EOT
aws ec2 describe-instances \
  --filters "Name=tag:${var.filter_tag_key},Values=${var.filter_tag_value}" \
           "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text > filtered_instance_ids.txt
EOT
  }

  triggers = {
    tag_key   = var.filter_tag_key
    tag_value = var.filter_tag_value
    region    = var.region
  }
}

# Read filtered instance IDs into Terraform
data "external" "filtered_instance_ids" {
  program = ["bash", "-c", <<EOT
#!/bin/bash
if [ -f filtered_instance_ids.txt ]; then
  ids=$(cat filtered_instance_ids.txt | tr '\\n' ',' | sed 's/,$//')
  echo "{\"result\": \"$ids\"}"
else
  echo "{\"result\": \"\"}"
fi
EOT
  ]
}

# Get instance details for filtered instance IDs
data "aws_instance" "filtered_instances" {
  for_each   = toset(split(",", jsondecode(data.external.filtered_instance_ids.result).result))
  instance_id = each.key
}

# Calculate the cutoff date for snapshot deletion
locals {
  cutoff_date_local = timeadd(timestamp(), "${-(var.cutoff_days * 86400)}s")
}

# Create EBS snapshots for filtered instances
resource "aws_ebs_snapshot" "snapshots" {
  for_each = toset(flatten([
    for instance in data.aws_instance.filtered_instances :
    concat(
      [for root in instance.root_block_device : root.volume_id],
      [for ebs in instance.ebs_block_device : ebs.volume_id]
    )
  ]))
  
  volume_id = each.value
  tags = {
    "${var.filter_tag_key}" = var.filter_tag_value
  }
  timeouts {
    create = var.timeoutssettings
  }
}

# Delete old snapshots using a Python script
resource "null_resource" "delete_old_snapshots" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = <<-EOF
#!/bin/bash
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python get-pip.py
python -m pip install boto3
python3 delete_snapshots.py ${local.cutoff_date_local} ${var.filter_tag_key} ${var.filter_tag_value} ${var.region}
EOF
  }
}

# Outputs
output "instance_ids" {
  value = split(",", jsondecode(data.external.filtered_instance_ids.result).result)
}

output "volume_ids" {
  value = flatten([
    for inst in data.aws_instance.filtered_instances : 
    [for bd in inst.ebs_block_device : bd.volume_id]
  ])
}

output "snapshot_ids" {
  value = [for snapshot in aws_ebs_snapshot.snapshots : snapshot.id]
}

output "cutoff_date" {
  value = local.cutoff_date_local
}
