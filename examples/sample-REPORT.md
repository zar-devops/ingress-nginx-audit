# Ingress-NGINX exit audit

- Context: `demo-cluster`
- Generated: 2026-11-17 10:41 UTC
- Gateway API CRDs: not installed

## Summary

| | Count |
|---|---|
| Ingress objects in the cluster | 4 |
| Served by ingress-nginx (or likely) | 3 |
| Unique hostnames to move | 3 |
| GREEN: core Gateway API covers everything | 1 |
| AMBER: needs implementation policies or a manual check | 1 |
| RED: uses something with no equivalent, plan a redesign | 1 |
| Ingresses with no class set | 1 |

## Controllers found

| Namespace | Pod | Image | Phase |
|---|---|---|---|
| ingress-nginx | ingress-nginx-controller-abc | registry.k8s.io/ingress-nginx/controller:v1.11.3 | Running |

### Entry points (these IPs/hostnames are what your DNS points at today)

| Namespace | Service | Type | externalTrafficPolicy | Address |
|---|---|---|---|---|
| ingress-nginx | ingress-nginx-controller | LoadBalancer | Local | 203.0.113.10 |

## Behaviour ingress-nginx gave you for free

Gateway API implementations do not copy these defaults. Decide for each one whether you need it.

1. **HTTP to HTTPS redirect.** ingress-nginx redirects automatically when an Ingress has TLS. With Gateway API you add a redirect HTTPRoute on the HTTP listener.
2. **HSTS header.** On by default in ingress-nginx (max-age 1 year). Add it back with a ResponseHeaderModifier if your sites rely on it.
3. **Timeouts.** ingress-nginx defaults to 60s proxy read/send timeouts. Envoy's default route timeout is shorter (15s) unless your implementation overrides it. Set `timeouts` explicitly on routes with slow endpoints, uploads or reports.
4. **Body size.** ingress-nginx rejects bodies over 1 MB unless `proxy-body-size` is set. Envoy behaves differently. Test your largest uploads.
5. **Client IP.** If you used `use-forwarded-headers`, `enable-real-ip` or PROXY protocol, set the equivalent in the new controller before you rely on IP allowlists or rate limits.
6. **Default 404 / error pages.** Requests for unknown hosts get a different response. Check monitoring and uptime probes that expect nginx's page.

## Global controller settings to carry over

These keys in the controller ConfigMap change behaviour for every Ingress:

| ConfigMap | Key | Value |
|---|---|---|
| ingress-nginx/ingress-nginx-controller | `allow-snippet-annotations` | `true` |
| ingress-nginx/ingress-nginx-controller | `use-forwarded-headers` | `true` |
| ingress-nginx/ingress-nginx-controller | `proxy-body-size` | `50m` |

> **Security:** `allow-snippet-annotations` is enabled. Combined with an unpatched controller this is a real risk. Prioritise this cluster.

## RED: Ingresses that need a redesign

### legacy/old-app

Hosts: old.example.com

- `configuration-snippet` → No equivalent. Raw nginx config. Read every snippet and map each line to a filter or policy. Common ones: add_header (ResponseHeaderModifier), more_set_headers, return 301 (RequestRedirect).

  ```
  more_set_headers "X-Frame-Options: DENY";
  add_header X-Test 1;
  ```


## AMBER: annotations that need a policy or a check

| Annotation | Used by | Target | Note |
|---|---|---|---|
| `enable-cors` | 1 Ingress(es) | Envoy Gateway SecurityPolicy cors (or HTTPRoute CORS filter if your version supports it) | See manifests/envoy-gateway/30-security-policy.yaml |
| `limit-rps` | 1 Ingress(es) | Envoy Gateway BackendTrafficPolicy rateLimit (Local) | nginx limits per client IP by default; Envoy local limits are per Envoy replica unless you add a clientSelector. |
| `rewrite-target` | 1 Ingress(es) | HTTPRoute filter URLRewrite (ReplacePrefixMatch / ReplaceFullPath) | Regex capture groups ($1, $2) are not core. Use Envoy Gateway HTTPRouteFilter with regex rewrite or restructure paths. |
| `use-regex` | 1 Ingress(es) | HTTPRoute path type RegularExpression | RegularExpression matching is implementation-specific. Test every regex path; nginx regex and Envoy RE2 differ (no lookaheads). |
| `whatever-new` | 1 Ingress(es) | Not in the kit map - check manually |  |

## Ingresses with no class

These rely on a default IngressClass or on a controller watching all Ingresses. Confirm who serves them:

- legacy/old-app (old.example.com)

## Certificates in use

- legacy/legacy-tls
- shop/shop-tls

A Gateway listener can only reference Secrets in its own namespace unless you add a ReferenceGrant.

## Next steps

1. Pick a replacement controller (Envoy Gateway, Traefik, NGINX Gateway Fabric, Cilium or your cloud's gateway).
2. Convert GREEN Ingresses first with `ingress2gateway`, then AMBER, then RED.
3. Test every hostname against the new entry point before you touch DNS.

The full Ingress-NGINX Exit Kit adds a side-by-side validation script, Envoy Gateway YAML for every AMBER item, a runbook with rollback at each step and a cutover checklist: https://vortik.gumroad.com/l/ingress-nginx-exit-kit

Files in this folder: `inventory.csv` (one row per Ingress), `annotations.csv` (one row per annotation), `hosts.txt` (host and path list for testing), `analysis.json` (everything, for your own tooling), `raw/` (what kubectl returned).
