output "source_bucket" {
  description = "源对象存储桶名（存放 devcontainer 配置 .zip）"
  value       = huaweicloud_obs_bucket.source.bucket
}

output "artifact_bucket" {
  description = "产物对象存储桶名"
  value       = huaweicloud_obs_bucket.artifact.bucket
}

output "swr_organization" {
  description = "容器镜像组织名"
  value       = huaweicloud_swr_organization.main.name
}

output "swr_login_endpoint" {
  description = "SWR 登录端点（docker login 使用）"
  value       = "swr.${var.region}.myhuaweicloud.com"
}

output "build_agency_name" {
  description = "构建委托名称（由用户预先创建，CodeArts 构建任务与 FunctionGraph 使用）"
  value       = var.build_agency_name
}

output "image_pipeline_names" {
  description = "镜像构建流水线名称列表"
  value       = [for k in var.images : huaweicloud_codearts_pipeline.image[k].name]
}

output "feature_pipeline_names" {
  description = "特性发布流水线名称列表"
  value       = [for k in var.features : huaweicloud_codearts_pipeline.feature[k].name]
}
