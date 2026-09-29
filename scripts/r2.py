"""往 R2（Cloudflare 的对象存储，桶 skylu-downloads，公开地址 downloads.skylu.ai）传对象的公共小件。

纯标准库 SigV4，不装依赖。音乐库（scripts/audio-library/upload.py）和本机配音模型（scripts/voice-models/upload.py）共用
—— 同一段签名代码只留这一份。

凭证从环境变量读：R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_ENDPOINT（R2_BUCKET 默认 skylu-downloads）。
本机放在**仓库外**的 ~/.config/srtflow/r2.env（权限 600，令牌只给这一个桶；docs/plans/2026-09-27-mcp.md 第 51 条），
跑之前 `set -a; source ~/.config/srtflow/r2.env; set +a`。放仓库里的 .env.local 虽然被忽略，但 AI 在仓库里全局搜索时
可能把密钥打印进对话记录。
"""
import datetime
import hashlib
import hmac
import os
import urllib.error
import urllib.request

# 按 id / 版本号命名、内容永不变的对象给长缓存；会更新的清单只给 5 分钟。
IMMUTABLE = "public, max-age=31536000, immutable"
SHORT = "public, max-age=300"


def credentials():
    """(access key, secret, endpoint, bucket, host)。缺了就说清楚缺哪个，不打印任何值。"""
    missing = [n for n in ("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_ENDPOINT") if not os.environ.get(n)]
    if missing:
        raise SystemExit("缺环境变量：" + "、".join(missing) + "（先 source ~/.config/srtflow/r2.env）")
    endpoint = os.environ["R2_ENDPOINT"].strip().rstrip("/")
    return (os.environ["R2_ACCESS_KEY_ID"].strip(), os.environ["R2_SECRET_ACCESS_KEY"].strip(), endpoint,
            os.environ.get("R2_BUCKET", "skylu-downloads"), endpoint.split("://", 1)[1])


def bucket():
    return os.environ.get("R2_BUCKET", "skylu-downloads")


def put(key, body, content_type, cache_control, timeout=600):
    """传一个对象。返回 (HTTP 状态, 出错时服务器回的前 200 个字)。"""
    ak, sk, endpoint, bucket_name, host = credentials()
    t = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = t.strftime("%Y%m%dT%H%M%SZ"), t.strftime("%Y%m%d")
    ph = hashlib.sha256(body).hexdigest()
    uri = "/" + bucket_name + "/" + key
    headers = {
        "cache-control": cache_control,
        "content-type": content_type,
        "host": host,
        "x-amz-content-sha256": ph,
        "x-amz-date": amzdate,
    }
    signed = ";".join(sorted(headers))
    canon_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    creq = f"PUT\n{uri}\n\n{canon_headers}\n{signed}\n{ph}"
    scope = f"{datestamp}/auto/s3/aws4_request"
    to_sign = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n{hashlib.sha256(creq.encode()).hexdigest()}"

    def s(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
    key4 = s(s(s(s(("AWS4" + sk).encode(), datestamp), "auto"), "s3"), "aws4_request")
    sig = hmac.new(key4, to_sign.encode(), hashlib.sha256).hexdigest()

    req = urllib.request.Request(endpoint + uri, data=body, method="PUT", headers={
        **{k.title(): v for k, v in headers.items() if k != "host"},
        "Host": host,
        "Authorization": f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
                         f"SignedHeaders={signed}, Signature={sig}",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:200]
