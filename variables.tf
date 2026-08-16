variable "github_token" {
  description = "PAT for cloning the private frontend repo"
  type        = string
  sensitive   = true
}

variable "prismic_repo" {
  description = "The Prismic repository name"
  type        = string
}

variable "prismic_access_token" {
  description = "The Prismic API access token"
  type        = string
  sensitive   = true
}

variable "prismic_custom_types_token" {
  description = "The Prismic custom types token"
  type        = string
  sensitive   = true
}

variable "github_oidc_subject" {
  description = "The GitHub repository subject for OIDC federation (e.g., repo:user/repo:ref:refs/heads/branch)"
  type        = string
}
