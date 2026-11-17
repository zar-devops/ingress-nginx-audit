# ingress-nginx-audit

The community **ingress-nginx** controller was retired in March 2026. It gets no more releases or security fixes.

Before you can migrate, you need to know what your cluster actually uses. This script tells you in about a minute.

```bash
git clone https://github.com/zar-devops/ingress-nginx-audit
cd ingress-nginx-audit
./scripts/audit.sh -c my-cluster
less ingress-audit-*/REPORT.md
```

## What it does

- Finds every Ingress, the controllers that serve them, their entry-point IPs and the controller's global ConfigMap settings.
- Checks 99 `nginx.ingress.kubernetes.io/*` annotations against Gateway API and sorts each Ingress into:
  - **GREEN**: core Gateway API covers everything
  - **AMBER**: needs an implementation policy or a manual check
  - **RED**: uses snippets, ModSecurity or other things with no equivalent
- Lists the defaults ingress-nginx gave you that Gateway API won't (HTTPS redirect, HSTS, 60s timeouts, 1 MB body limit, client IP handling, default 404).
- Flags `allow-snippet-annotations: true` and Ingresses using F5's `nginx.org/` annotations (a different, still-maintained controller).

Output: `REPORT.md`, `inventory.csv`, `annotations.csv`, `hosts.txt`, `analysis.json`. See [examples/sample-REPORT.md](examples/sample-REPORT.md).

## Safety

Read-only. The script only runs `kubectl get`. Read it first, it's one file.

## Requirements

bash 4+, kubectl, jq 1.6+. Linux, macOS or WSL.

## Need the rest of the migration?

The paid [Ingress-NGINX Exit Kit](https://vortik.gumroad.com/l/ingress-nginx-exit-kit) adds:

- `validate.sh`: sends the same requests to the old and new entry points and shows what differs, before you change DNS
- Envoy Gateway YAML for redirects, HSTS, timeouts, regex rewrites, canary, CORS, basic auth, IP allowlists, rate limits, sticky sessions and client IP
- a runbook with rollback at every step, a controller comparison and a cutover-day checklist

## License

MIT. Issues and pull requests welcome, especially annotation mappings that are wrong or missing in `data/annotations.tsv`.
