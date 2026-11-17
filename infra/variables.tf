variable "region" {
  description = "华为云区域"
  type        = string
  default     = "cn-north-4"
}

variable "project_name" {
  description = "项目名称，用于资源命名前缀"
  type        = string
  default     = "devcontainer-factory"
}

variable "namespace" {
  description = "资源命名空间，用于 SWR 组织与对象存储路径前缀"
  type        = string
  default     = "devcontainers"
}

variable "build_agency_name" {
  description = "预先创建并绑定给 FunctionGraph 与 CodeArts 构建的 IAM 委托名称（详见部署指南）。该委托需具备 SWR Administrator、OBS OperateAccess、KMS DecryptAccess 权限"
  type        = string
}

variable "codearts_project_id" {
  description = "CodeArts 项目 ID（流水线被创建到该项目中）"
  type        = string
}

variable "obs_source_bucket_name" {
  description = "源对象存储桶名（存放 devcontainer 配置 .zip，全局唯一）"
  type        = string
  default     = "devcontainer-factory-source"
}

variable "obs_artifact_bucket_name" {
  description = "产物对象存储桶名（存放构建产物 / 函数代码包，全局唯一）"
  type        = string
  default     = "devcontainer-factory-artifacts"
}

variable "swr_organization" {
  description = "容器镜像组织名（Software Repository for Containers）"
  type        = string
  default     = "devcontainers"
}

variable "images" {
  description = "需要构建的 devcontainer 镜像标识符列表（如 base, base-extended）"
  type        = list(string)
  default     = ["base", "base-extended"]
}

variable "features" {
  description = "需要发布的 devcontainer 特性标识符列表（如 git-cli, docker-cli）"
  type        = list(string)
  default     = ["git-cli", "docker-cli"]
}
