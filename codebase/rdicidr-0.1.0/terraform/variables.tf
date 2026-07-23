# In this file put the variables related to the deployment
variable "environment" {
    type = string
    description = "development environment (devel or stage)"
    default = "devel"
}
