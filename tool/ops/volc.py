"""火山引擎 API 的最小签名客户端（只给运维脚本用，不进产物）。"""
import hashlib, hmac, datetime, urllib.request, urllib.error, urllib.parse

def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()

def _derive(sk, day, region, service):
    k = sk.encode()
    for p in [day, region, service, 'request']:
        k = _sign(k, p)
    return k

def tos(ak, sk, method, host, region='cn-beijing', path='/', body=b'',
        headers=None, query=''):
    """TOS 的 SigV4（header 形式）。返回 (状态码, 正文)"""
    now = datetime.datetime.now(datetime.UTC)
    stamp = now.strftime('%Y%m%dT%H%M%SZ'); day = stamp[:8]
    scope = f'{day}/{region}/tos/request'
    payload = hashlib.sha256(body).hexdigest()
    extra = {k.lower(): v for k, v in (headers or {}).items()}
    signed = dict(extra)
    signed['host'] = host
    signed['x-tos-content-sha256'] = payload
    signed['x-tos-date'] = stamp
    keys = sorted(signed)
    canon_headers = ''.join(f'{k}:{signed[k]}\n' for k in keys)
    canon = '\n'.join([method, path, query, canon_headers, ';'.join(keys),
                       payload])
    sts = '\n'.join(['TOS4-HMAC-SHA256', stamp, scope,
                     hashlib.sha256(canon.encode()).hexdigest()])
    sig = hmac.new(_derive(sk, day, region, 'tos'), sts.encode(),
                   hashlib.sha256).hexdigest()
    hdrs = {k: v for k, v in signed.items()}
    hdrs['Authorization'] = (
        f'TOS4-HMAC-SHA256 Credential={ak}/{scope},'
        f'SignedHeaders={";".join(keys)},Signature={sig}')
    url = f'https://{host}{path}' + (f'?{query}' if query else '')
    req = urllib.request.Request(url, data=body or None, headers=hdrs,
                                 method=method)
    try:
        r = urllib.request.urlopen(req, timeout=120)
        return r.status, r.read().decode(errors='replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors='replace')

def api(ak, sk, service, action, version, params=None, region='cn-beijing',
        host='open.volcengineapi.com'):
    """开放 API 的 GET 调用（IAM 等）。返回 (状态码, 正文)"""
    q = {'Action': action, 'Version': version, **(params or {})}
    query = '&'.join(
        f'{urllib.parse.quote(k, safe="-_.~")}='
        f'{urllib.parse.quote(str(v), safe="-_.~")}'
        for k, v in sorted(q.items()))
    now = datetime.datetime.now(datetime.UTC)
    stamp = now.strftime('%Y%m%dT%H%M%SZ'); day = stamp[:8]
    scope = f'{day}/{region}/{service}/request'
    payload = hashlib.sha256(b'').hexdigest()
    canon = '\n'.join(['GET', '/', query,
                       f'host:{host}\nx-date:{stamp}\n', 'host;x-date', payload])
    sts = '\n'.join(['HMAC-SHA256', stamp, scope,
                     hashlib.sha256(canon.encode()).hexdigest()])
    sig = hmac.new(_derive(sk, day, region, service), sts.encode(),
                   hashlib.sha256).hexdigest()
    req = urllib.request.Request(f'https://{host}/?{query}', headers={
        'Host': host, 'X-Date': stamp,
        'Authorization': f'HMAC-SHA256 Credential={ak}/{scope},'
                         f'SignedHeaders=host;x-date,Signature={sig}'})
    try:
        r = urllib.request.urlopen(req, timeout=60)
        return r.status, r.read().decode(errors='replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors='replace')

def secret(name):
    return open(f'.secrets/{name}').read().strip()
