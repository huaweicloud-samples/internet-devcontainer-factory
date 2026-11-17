# 部署指南 / Deployment Guide

本文档说明如何将本仓库部署到华为云。所有操作均通过命令行完成，请以具有 Tenant Administrator 或等效权限的账号执行。

## 0. 准备工作

| 项目 | 说明 |
|---|---|
| 访问密钥 | 在「我的凭证 → 访问密钥」创建 AK/SK，通过环境变量 `TF_VAR_access_key` / `TF_VAR_secret_key` 注入 |
| 区域 | 默认 `cn-north-4`，需支持 OBS / SWR / CodeArts / FunctionGraph / KMS |
| CodeArts 项目 | 在 CodeArts 控制台创建项目，记录项目 ID（`codearts_project_id`） |
| 构建委托 | 预先创建 IAM 委托（详见第 1 步），记录委托名称（`build_agency_name`） |

## 1. 创建 IAM 委托（Agency）

1. 进入「统一身份认证 → 委托」，点击「新建委托」。
2. 委托类型选择「云服务」，被委托的云服务勾选 **函数工作流 FunctionGraph** 与 **CodeArts 构建**。
3. 权限选择：**SWR Administrator**、**OBS OperateAccess**、**KMS DecryptAccess**。
4. 记录该委托的名称，部署时填入 `build_agency_name`。

## 2. 部署基础设施

```bash
cd <本仓库根目录>/infra
terraform init
terraform plan
terraform apply -auto-approve
```

部署完成后执行 `terraform output` 记录以下信息：

- `source_bucket`：源对象存储桶名
- `swr_login_endpoint`：SWR 登录端点（形如 `swr.cn-north-4.myhuaweicloud.com`）
- `swr_organization`：容器镜像组织名
- `image_pipeline_names` / `feature_pipeline_names`：流水线名称列表

## 3. 打包函数代码

将 `src/obs_trigger_bridge/` 目录打包为 `obs_trigger_bridge.zip`，上传至产物桶的 `function-code/` 路径：

```bash
cd <本仓库根目录>/src/obs_trigger_bridge
zip -r obs_trigger_bridge.zip .
obsutil cp ./obs_trigger_bridge.zip obs://<artifact_bucket>/function-code/obs_trigger_bridge.zip
```

> 也可在 FunctionGraph 控制台直接上传 ZIP 创建函数，函数入口为 `index.handler`。

## 4. 配置 OBS 事件通知

在 OBS 源桶的「事件通知」中新增规则：

- 事件类型：PutObject
- 对象名前缀：`devcontainers/`
- 触发函数：选择本仓库创建的 FunctionGraph 桥接函数

## 5. 配置 CodeArts 构建参数

在各条 CodeArts 流水线的构建任务中，配置以下构建参数（加密保存，禁止明文写入仓库）：

| 参数 | 示例 | 说明 |
|---|---|---|
| `SWR_ENDPOINT` | `swr.cn-north-4.myhuaweicloud.com` | 容器镜像仓库登录端点 |
| `SWR_USER` | `<组织名>@<账号名>` 或访问密钥 ID | SWR 登录用户名 |
| `SWR_PASSWORD` | SWR 登录密码 | 控制台「我的凭证」获取 |
| `SWR_ORG` | `devcontainers` | 容器镜像组织名 |
| `SWR_REPO` | `base` | 当前流水线对应的镜像 / 特性仓库名 |
| `IMAGE_TAG` | `20261013` | 镜像标签后缀 |
| `TARGET_ARCH` | `amd64` 或 `arm64` | 当前构建任务的架构 |

## 6. 触发构建

将某个 DevContainer 配置目录打包并上传到对应路径即可触发：

```bash
zip -r base.zip ./devcontainer-base
obsutil cp ./base.zip obs://<source_bucket>/devcontainers/images/base.zip
```

随后在 CodeArts 控制台观察对应镜像流水线自动启动并完成构建发布。

## 7. 验证

参见仓库根目录 `README.md` 第 9 节「使用方法 / 验证」，部署完成后请逐项自行验证，确认镜像可正常拉取与启动。

## 8. 释放资源

```bash
cd <本仓库根目录>/infra
terraform destroy -auto-approve
```
