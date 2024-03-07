# GKE with Private VPC and Bastion Host 

#### Configure Google SDK
- `gcloud init`
- `gcloud auth application-default login`

#### Change Variable in terraform.tfvars file
- Project-ID
- Region
- Zone
- GKE Cluster Name
- Bastion Host Name

#### Run terraform
- `terraform init`
- `terraform validate` for validation
- `terraform plan -out=tfplan`
- `terraform apply tfplan`
