# Cloudflare + B2 setup

`https://outpost.bios.plus/aurstrich/…` is served by Cloudflare from the public
B2 bucket `<bucket>` (EU Central, friendly host `f003.backblazeb2.com`).

## B2

1. Bucket `<bucket>`: **Public**.
2. Lifecycle Settings: **Keep only the last version of the file**.

## DNS

| Type | Name | Target | Proxy |
|---|---|---|---|
| `CNAME` | `outpost` | `f003.backblazeb2.com` | **Proxied** |

SSL/TLS mode: **Full (strict)**.

## URL Rewrite rule

Rules → Transform Rules → URL Rewrite Rules → Create rule.

- Expression:

  ```
  (http.host eq "outpost.bios.plus" and starts_with(http.request.uri.path, "/aurstrich/"))
  ```

- Path → Rewrite to → Dynamic:

  ```
  concat("/file/<bucket>", http.request.uri.path)
  ```

## Cache Rules

Caching → Cache Rules. Create two rules.

**Database: bypass**

```
(http.host eq "outpost.bios.plus" and (ends_with(http.request.uri.path, ".db") or ends_with(http.request.uri.path, ".db.sig") or ends_with(http.request.uri.path, ".db.tar.gz") or ends_with(http.request.uri.path, ".db.tar.gz.sig") or ends_with(http.request.uri.path, ".files") or ends_with(http.request.uri.path, ".files.sig") or ends_with(http.request.uri.path, ".files.tar.gz") or ends_with(http.request.uri.path, ".files.tar.gz.sig") or ends_with(http.request.uri.path, ".asc")))
```

Cache eligibility: **Bypass cache**.

**Packages: 30 days**

```
(http.host eq "outpost.bios.plus" and (ends_with(http.request.uri.path, ".pkg.tar.zst") or ends_with(http.request.uri.path, ".pkg.tar.zst.sig")))
```

Cache eligibility: **Eligible for cache**. Edge TTL: **Ignore cache-control
header, 30 days**.

## Optional: block other paths

Security → WAF → Custom rules → Block:

```
(http.host eq "outpost.bios.plus" and not starts_with(raw.http.request.uri.path, "/aurstrich/"))
```

This must use `raw.` (the path before rewriting). Add an exception here
when something else, such as a mirror, moves onto the host.

## Check

```bash
curl -sSI https://outpost.bios.plus/aurstrich/x86_64/aurstrich.db | grep -i cf-cache-status
```

Expect `BYPASS` or `DYNAMIC`.
