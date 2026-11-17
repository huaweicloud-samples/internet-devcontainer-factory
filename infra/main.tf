terraform {
  required_version = ">= 1.5"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "~> 1.70"
    }
  }

  backend "local" {}
}

provider "huaweicloud" {
  region = var.region
  # AK/SK 从环境变量读取，不写入任何配置文件。
}

# ============================================================================
# Layer 1: 存储与加密
# ============================================================================

# 源对象存储桶：存放 devcontainer 配置 .zip（事件触发源）
resource "huaweicloud_obs_bucket" "source" {
  bucket        = var.obs_source_bucket_name
  acl           = "private"
  force_destroy = true
  versioning    = true

  # 服务端加密：使用华为云 KMS 托管密钥（密钥由 KMS 托管，不暴露明文）
  sse_algorithm = "KMS"
  kms_key_id    = huaweicloud_kms_key.factory.id

  lifecycle_rule {
    name    = "delete-old-source"
    prefix  = "devcontainers/"
    enabled = true
    expiration {
      days = 7
    }
  }

  tags = {
    project   = var.project_name
    namespace = var.namespace
    role      = "source"
  }
}

# 产物对象存储桶：存放构建产物与函数代码包
resource "huaweicloud_obs_bucket" "artifact" {
  bucket        = var.obs_artifact_bucket_name
  acl           = "private"
  force_destroy = true
  versioning    = true

  # 服务端加密：使用华为云 KMS 托管密钥（密钥由 KMS 托管，不暴露明文）
  sse_algorithm = "KMS"
  kms_key_id    = huaweicloud_kms_key.factory.id

  lifecycle_rule {
    name    = "delete-old-artifacts"
    enabled = true
    expiration {
      days = 7
    }
  }

  tags = {
    project   = var.project_name
    namespace = var.namespace
    role      = "artifact"
  }
}

# KMS 密钥：用于桶与镜像仓库服务端加密
resource "huaweicloud_kms_key" "factory" {
  key_alias    = "${var.namespace}-factory-key"
  pending_days = 7
}

# ============================================================================
# Layer 2: 容器镜像仓库（Software Repository for Containers）
# ============================================================================

resource "huaweicloud_swr_organization" "main" {
  name = var.swr_organization
}

resource "huaweicloud_swr_repository" "images" {
  for_each     = toset(var.images)
  organization = huaweicloud_swr_organization.main.name
  name         = each.key
  description  = "DevContainer 镜像：${each.key}"
}

resource "huaweicloud_swr_repository" "features" {
  for_each     = toset(var.features)
  organization = huaweicloud_swr_organization.main.name
  name         = each.key
  description  = "DevContainer 特性：${each.key}"
}

# ============================================================================
# Layer 3: 构建委托（IAM Agency）
#   该委托需在使用本仓库前由管理员在 IAM 控制台预先创建（详见 docs/deployment-guide.md）：
#     - 委托类型：云服务，被委托的云服务选择「函数工作流 FunctionGraph」与「CodeArts 构建」
#     - 权限：SWR Administrator、OBS OperateAccess、KMS DecryptAccess
#   此处通过变量引用其名称，避免在 Terraform 中硬编码与账号强绑定的服务主体。
# ============================================================================

# ============================================================================
# Layer 4: 事件触发桥接函数（OBS 上传 → 启动 CodeArts 流水线）
#   通过 OBS 事件通知触发 FunctionGraph，由函数启动对应的 CodeArts 流水线
#   （OBS 原生触发器配置详见 docs/deployment-guide.md）
# ============================================================================

resource "huaweicloud_fgs_function" "obs_trigger_bridge" {
  # 函数名仅允许字母、数字与下划线，不允许连字符（FunctionGraph 约束）
  name        = "devcontainer_factory_obs_trigger_bridge"
  # 函数分组（package）仅允许字母、数字与下划线；同时作为 OBS 触发器配置的归属分组
  package     = "devcontainer_factory"
  agency      = var.build_agency_name
  handler     = "index.handler"
  memory_size = 256
  timeout     = 30
  runtime     = "Python3.9"

  # 函数代码包需先打包上传至产物桶（详见部署指南）
  code_type = "obs"
  code_url  = "https://${huaweicloud_obs_bucket.artifact.bucket}.obs.${var.region}.myhuaweicloud.com/function-code/obs_trigger_bridge.zip"

  user_data = jsonencode({
    CODEARTS_PROJECT_ID = var.codearts_project_id
    REGION              = var.region
    NAMESPACE           = var.namespace
  })
}

# ============================================================================
# Layer 5: CodeArts 流水线（镜像 / 特性构建发布）
#   流水线由「源拉取 → 多架构构建 → 发布」等阶段组成，
#   构建阶段在 CodeArts 构建任务中完成镜像编译与推送
# ============================================================================

locals {
  # 通用构建流水线定义模板（镜像）
  image_pipeline_definition = jsonencode({
    stages = [
      {
        name       = "Source"
        identifier = "stage_source"
        pre = [
          { task = "official_devcloud_autoTrigger" }
        ]
        jobs = [
          {
            name       = "DownloadSource"
            identifier = "job_source"
            steps = [
              {
                name = "PullConfig"
                task = "official_devcloud_download_file"
                inputs = [
                  { key = "bucket", value = huaweicloud_obs_bucket.source.bucket },
                  { key = "object_key", value = "${var.namespace}/images/${"{identifier}"}.zip" }
                ]
              }
            ]
          }
        ]
      },
      {
        name       = "Build"
        identifier = "stage_build"
        jobs = [
          {
            name       = "MultiArchBuild"
            identifier = "job_build"
            steps = [
              {
                name = "BuildAndPush"
                task = "official_devcloud_build"
                inputs = [
                  { key = "build_yaml", value = "src/buildspec/build.yml" },
                  { key = "swr_org", value = huaweicloud_swr_organization.main.name },
                  { key = "swr_repo", value = "${"{identifier}"}" }
                ]
              }
            ]
          }
        ]
      },
      {
        name       = "Release"
        identifier = "stage_release"
        jobs = [
          {
            name       = "PublishManifest"
            identifier = "job_release"
            steps = [
              {
                name = "Release"
                task = "official_devcloud_build"
                inputs = [
                  { key = "build_yaml", value = "src/buildspec/release.yml" },
                  { key = "swr_org", value = huaweicloud_swr_organization.main.name },
                  { key = "swr_repo", value = "${"{identifier}"}" }
                ]
              }
            ]
          }
        ]
      }
    ]
  })
}

resource "huaweicloud_codearts_pipeline" "image" {
  for_each    = toset(var.images)
  project_id  = var.codearts_project_id
  name        = "${var.namespace}-image-${each.key}"
  is_publish  = false
  description = "DevContainer 镜像构建流水线：${each.key}"
  # identifier 通过环境变量 / 流水线参数传入，构建步骤据此拼接对象键与仓库路径
  definition = replace(local.image_pipeline_definition, "\"${"{identifier}"}\"", each.key)
}

resource "huaweicloud_codearts_pipeline" "feature" {
  for_each    = toset(var.features)
  project_id  = var.codearts_project_id
  name        = "${var.namespace}-feature-${each.key}"
  is_publish  = false
  description = "DevContainer 特性发布流水线：${each.key}"
  definition = jsonencode({
    stages = [
      {
        name       = "Source"
        identifier = "stage_source"
        pre        = [{ task = "official_devcloud_autoTrigger" }]
        jobs = [
          {
            name       = "DownloadSource"
            identifier = "job_source"
            steps = [
              {
                name = "PullConfig"
                task = "official_devcloud_download_file"
                inputs = [
                  { key = "bucket", value = huaweicloud_obs_bucket.source.bucket },
                  { key = "object_key", value = "${var.namespace}/features/${each.key}.zip" }
                ]
              }
            ]
          }
        ]
      },
      {
        name       = "Publish"
        identifier = "stage_publish"
        jobs = [
          {
            name       = "PublishFeature"
            identifier = "job_publish"
            steps = [
              {
                name = "Publish"
                task = "official_devcloud_build"
                inputs = [
                  { key = "build_yaml", value = "src/buildspec/feature.yml" },
                  { key = "swr_org", value = huaweicloud_swr_organization.main.name },
                  { key = "swr_repo", value = each.key }
                ]
              }
            ]
          }
        ]
      }
    ]
  })
}
