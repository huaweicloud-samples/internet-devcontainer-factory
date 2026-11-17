# 架构说明 / Architecture

本实践基于华为云构建一套 DevContainer 镜像与特性的自动化构建发布流水线。下文从组件、数据流、构建策略与安全设计四个维度说明。

## 1. 总体架构

| 层 | 组件 | 职责 |
|---|---|---|
| 存储层 | OBS 源桶 / 产物桶 | 存放 DevContainer 配置压缩包与构建产物，启用版本控制与 KMS 服务端加密 |
| 触发层 | FunctionGraph 桥接函数 | 解析 OBS 事件，识别镜像 / 特性类型，启动对应流水线 |
| 构建层 | CodeArts 流水线 | 按镜像 / 特性编排「源拉取 → 多架构构建 → 测试 → 发布」 |
| 仓库层 | SWR 组织与仓库 | 托管最终发布的 DevContainer 镜像与特性 |
| 安全层 | KMS / IAM | KMS 提供加密密钥；IAM 委托授予构建与函数运行所需权限 |

## 2. 数据流

1. 开发者将 DevContainer 配置目录打包为 `.zip`，上传至 OBS 源桶的 `devcontainers/images/<id>.zip` 或 `devcontainers/features/<id>.zip` 路径。
2. OBS 事件通知触发 FunctionGraph 桥接函数。
3. 函数解析对象键，识别类型（images / features）与标识符，调用 CodeArts 流水线启动接口。
4. 流水线依次执行：从源桶拉取配置 → 多架构构建并推送至 SWR → 合并多架构清单 → 冒烟测试 → 发布版本与 latest 标签。

## 3. 多架构构建策略

- 每个架构（AMD64 / ARM64）由独立的构建任务完成原生编译，产物分别推送为 `dev-<IMAGE_TAG>-amd64` 与 `dev-<IMAGE_TAG>-arm64`。
- 单独的合并任务调用 `docker manifest` 将两个架构产物组合为多架构清单 `dev-<IMAGE_TAG>`，实现一次拉取、按需选择架构。
- 发布任务将验证通过的镜像重新打上时间戳版本号与 `latest` 标签。

## 4. 安全设计

- **默认加密**：OBS 桶与 SWR 镜像仓库均启用 KMS 服务端加密，密钥由 KMS 托管，明文不落盘。
- **凭据不下沉**：Terraform 的 AK/SK 在部署前于终端会话中临时设置；CodeArts 构建环境通过构建参数传入 SWR 登录凭据；FunctionGraph 的 AK/SK 通过加密的环境变量提供。仓库内不出现任何真实凭据。
- **最小权限委托**：构建与函数运行统一使用预先创建的 IAM 委托，仅授予 SWR / OBS / KMS 必要权限。

## 5. 可扩展性

- 新增镜像：在 `images` 变量中追加标识符，Terraform 会自动创建对应的 SWR 仓库与 CodeArts 镜像流水线。
- 新增特性：在 `features` 变量中追加标识符，自动创建对应的特性发布流水线。
- 构建逻辑集中维护在 `src/buildspec/` 下的构建 YAML 中，便于统一升级。
