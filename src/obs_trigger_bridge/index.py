# -*- coding: utf-8 -*-
"""
OBS 事件 → 启动 CodeArts 流水线 桥接函数（FunctionGraph, Python3.9）

功能：
  当开发者向「源对象存储桶」上传 devcontainer 配置压缩包（.zip）时，
  OBS 事件通知触发本函数；函数依据对象键路径识别镜像 / 特性类型与标识符，
  启动对应的 CodeArts 流水线完成构建与发布。

设计要点：
  - 仅依赖 Python 标准库（urllib/hmac/hashlib），无需额外安装第三方 SDK。
  - 访问密钥（AK/SK）由函数环境变量提供，仓库内不写入明文。
    请在 FunctionGraph 控制台将 AK/SK 配置为「加密环境变量」。
  - 签名算法采用华为云 SDK-HMAC-SHA256。

注意：CodeArts 流水线 API 的路径以控制台 / 官方 API 文档为准，
      如下常量 PIPELINE_API_PATH / START_PATH 若与实际不一致，请在部署时校正。
"""

import hashlib
import hmac
import json
import logging
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("obs_trigger_bridge")

# ---------------------------------------------------------------------------
# 配置（来自函数环境变量；AK/SK 必须为加密变量，禁止写入仓库）
# ---------------------------------------------------------------------------
AK = os.environ.get("HW_AK", "")
SK = os.environ.get("HW_SK", "")
REGION = os.environ.get("REGION", "")
NAMESPACE = os.environ.get("NAMESPACE", "")
PROJECT_ID = os.environ.get("CODEARTS_PROJECT_ID", "")
PIPELINE_HOST = os.environ.get("PIPELINE_HOST", "")  # 形如 cloudpipeline.{region}.myhuaweicloud.com

SERVICE = "cloudpipeline"


# ---------------------------------------------------------------------------
# SDK-HMAC-SHA256 签名
# ---------------------------------------------------------------------------
def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _hmac_sha256(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def _build_authorization(method: str, uri: str, query: str, body: bytes,
                         headers: dict, request_time: str) -> str:
    canonical_headers = "".join(
        f"{k.lower()}:{headers[k]}\n" for k in sorted(headers)
    )
    signed_header_names = ";".join(sorted(k.lower() for k in headers))

    canonical_request = "\n".join([
        method.upper(),
        uri,
        query,
        canonical_headers,
        signed_header_names,
        _sha256_hex(body),
    ])

    date_str = request_time[:8]
    credential_scope = f"{date_str}/{REGION}/{SERVICE}/sdk_request"
    string_to_sign = "\n".join([
        "SDK-HMAC-SHA256",
        request_time,
        credential_scope,
        _sha256_hex(canonical_request.encode("utf-8")),
    ])

    k_date = _hmac_sha256(SK.encode("utf-8"), date_str.encode("utf-8"))
    k_region = _hmac_sha256(k_date, REGION.encode("utf-8"))
    k_service = _hmac_sha256(k_region, SERVICE.encode("utf-8"))
    k_signing = _hmac_sha256(k_service, b"sdk_request")
    signature = hmac.new(k_signing, string_to_sign.encode("utf-8"),
                         hashlib.sha256).hexdigest()

    return (f"SDK-HMAC-SHA256 Access={AK}, "
            f"SignedHeaders={signed_header_names}, "
            f"Signature={signature}")


def _do_request(method: str, path: str, body: bytes = b"") -> dict:
    """发起带签名的 HTTPS 请求，返回解析后的 JSON。"""
    url = f"https://{PIPELINE_HOST}{path}"
    request_time = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    headers = {
        "Host": PIPELINE_HOST,
        "X-Sdk-Date": request_time,
        "Content-Type": "application/json",
        "X-Project-Id": PROJECT_ID,
    }
    auth = _build_authorization(method, path, "", body, headers, request_time)
    headers["Authorization"] = auth

    req = urllib.request.Request(url, data=body or None, method=method.upper())
    for k, v in headers.items():
        req.add_header(k, v)

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = resp.read().decode("utf-8")
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as e:
        logger.error("HTTPError %s: %s", e.code, e.read().decode("utf-8", "ignore"))
        raise


# ---------------------------------------------------------------------------
# CodeArts 流水线操作
# ---------------------------------------------------------------------------
def find_pipeline_id_by_name(pipeline_name: str) -> str:
    """按名称查询流水线 ID。"""
    path = f"/v5/{PROJECT_ID}/api/pipelines?name={pipeline_name}"
    data = _do_request("GET", path)
    for item in data.get("pipelines", data.get("value", [])) or []:
        if item.get("name") == pipeline_name:
            return item.get("id") or item.get("pipeline_id")
    raise RuntimeError(f"未找到流水线：{pipeline_name}")


def start_pipeline(pipeline_id: str) -> dict:
    """启动指定流水线。"""
    path = f"/v5/{PROJECT_ID}/api/pipelines/{pipeline_id}/start"
    return _do_request("POST", path, body=b"{}")


# ---------------------------------------------------------------------------
# 事件解析
# ---------------------------------------------------------------------------
def parse_obs_event(event: dict) -> tuple:
    """从 OBS 触发器事件中提取 桶名 与 对象键。"""
    # FunctionGraph OBS 触发器事件结构
    records = event.get("records") or []
    if records:
        obs = records[0].get("obs", {})
        bucket = obs.get("bucket", {}).get("name")
        key = obs.get("object", {}).get("key")
        if bucket and key:
            return bucket, key

    # 兜底：直接字段
    bucket = event.get("bucket") or (event.get("obs") or {}).get("bucket")
    key = event.get("key") or (event.get("obs") or {}).get("object", {}).get("key")
    if bucket and key:
        return bucket, key
    raise ValueError("无法从事件中提取 OBS 桶名与对象键")


def resolve_pipeline(object_key: str) -> tuple:
    """依据对象键识别类型与标识符，返回 (pipeline_type, identifier)。

    约定路径：
      <namespace>/images/<identifier>.zip   → 镜像流水线
      <namespace>/features/<identifier>.zip → 特性流水线
    """
    key = object_key.split("?")[0]
    prefix_img = f"{NAMESPACE}/images/"
    prefix_feat = f"{NAMESPACE}/features/"

    if key.startswith(prefix_img) and key.endswith(".zip"):
        identifier = key[len(prefix_img):-len(".zip")]
        return "image", identifier
    if key.startswith(prefix_feat) and key.endswith(".zip"):
        identifier = key[len(prefix_feat):-len(".zip")]
        return "feature", identifier
    return None, None


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
def handler(event, context):
    logger.info("收到事件: %s", json.dumps(event, ensure_ascii=False)[:500])

    if not (AK and SK and REGION and PROJECT_ID and PIPELINE_HOST and NAMESPACE):
        msg = "缺少必要环境变量（AK/SK/REGION/PROJECT_ID/PIPELINE_HOST/NAMESPACE）"
        logger.error(msg)
        return {"status": "error", "message": msg}

    try:
        _bucket, object_key = parse_obs_event(event)
    except ValueError as e:
        return {"status": "error", "message": str(e)}

    ptype, identifier = resolve_pipeline(object_key)
    if not ptype:
        logger.warning("对象键不在处理范围，跳过：%s", object_key)
        return {"status": "skipped", "object_key": object_key}

    pipeline_name = f"{NAMESPACE}-{ptype}-{identifier}"
    try:
        pipeline_id = find_pipeline_id_by_name(pipeline_name)
        result = start_pipeline(pipeline_id)
        logger.info("已启动流水线 %s (%s)", pipeline_name, pipeline_id)
        return {
            "status": "started",
            "pipeline_name": pipeline_name,
            "pipeline_id": pipeline_id,
            "result": result,
        }
    except Exception as e:  # noqa: BLE001
        logger.exception("启动流水线失败：%s", pipeline_name)
        return {"status": "error", "pipeline_name": pipeline_name, "message": str(e)}
