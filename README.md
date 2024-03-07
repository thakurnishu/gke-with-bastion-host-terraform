# GKE with Private VPC and Bastion Host 

#### Configure Google SDK
- `gcloud init`
- `gcloud auth application-default login`

#### Change Variable in terraform.tfvars file
- project-ID
- region
- zone
- gke cluster name
- bastion host name

#### Run terraform
- `terraform init`
- `terraform validate` for validation
- `terraform plan -out=tfplan`
- `terraform apply tfplan`
