#!/usr/bin/env bash
# ingress-nginx-audit - free cluster audit (from the Vortik Ingress-NGINX Exit Kit)
#
# Read-only. It only runs `kubectl get`. Nothing in the cluster is changed.
#
# Usage:
#   ./scripts/audit.sh                 # current kubectl context
#   ./scripts/audit.sh -c prod-eu      # a specific context
#   ./scripts/audit.sh -o ./my-report  # choose the output folder
#
# Needs: kubectl, jq (1.6+). Works on Linux, macOS and WSL.

set -euo pipefail

CONTEXT=""
OUT=""

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts "c:o:h" opt; do
  case "$opt" in
    c) CONTEXT="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

for bin in kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: $bin is not installed" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP_TSV="$SCRIPT_DIR/../data/annotations.tsv"
[[ -f "$MAP_TSV" ]] || { echo "error: $MAP_TSV not found" >&2; exit 1; }

KUBECTL=(kubectl)
[[ -n "$CONTEXT" ]] && KUBECTL+=(--context "$CONTEXT")
k() { "${KUBECTL[@]}" "$@"; }

CTX_NAME="${CONTEXT:-$(kubectl config current-context 2>/dev/null || echo unknown)}"
OUT="${OUT:-ingress-audit-$(date +%Y%m%d-%H%M%S)}"
RAW="$OUT/raw"
mkdir -p "$RAW"

log() { printf '  %s\n' "$*" >&2; }

echo "Auditing context: $CTX_NAME" >&2
echo "Output folder:    $OUT" >&2

# ---------------------------------------------------------------- collect
log "reading Ingresses"
k get ingress -A -o json > "$RAW/ingresses.json"

log "reading IngressClasses"
k get ingressclass -o json > "$RAW/ingressclasses.json" 2>/dev/null || echo '{"items":[]}' > "$RAW/ingressclasses.json"

log "looking for controller pods"
k get pods -A -o json | jq '[.items[]
  | select(any(.spec.containers[]; .image | test("ingress-nginx/controller|ingress-nginx-controller|nginx/nginx-ingress|nginx-ingress-controller")))
  | {namespace: .metadata.namespace, name: .metadata.name,
     images: [.spec.containers[].image],
     phase: .status.phase}]' > "$RAW/controller-pods.json"

log "looking for controller Services"
k get svc -A -o json | jq '[.items[]
  | select(.spec.type == "LoadBalancer" or .spec.type == "NodePort")
  | select(((.metadata.labels["app.kubernetes.io/name"] // "") | test("ingress-nginx|nginx-ingress"))
           or (.metadata.name | test("ingress-nginx|nginx-ingress")))
  | {namespace: .metadata.namespace, name: .metadata.name, type: .spec.type,
     externalTrafficPolicy: (.spec.externalTrafficPolicy // "Cluster"),
     address: ([.status.loadBalancer.ingress[]? | (.ip // .hostname)] | join(" "))}]' > "$RAW/controller-services.json"

log "looking for controller ConfigMaps"
k get configmap -A -o json | jq '[.items[]
  | select(.metadata.name | test("ingress-nginx-controller$|nginx-configuration$|nginx-ingress-controller$"))
  | {namespace: .metadata.namespace, name: .metadata.name, data: (.data // {})}]' > "$RAW/controller-configmaps.json"

log "checking for Gateway API CRDs"
if k get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  GW_CRDS="$(k get crd gateways.gateway.networking.k8s.io -o json \
    | jq -r '.metadata.annotations["gateway.networking.k8s.io/bundle-version"] // "installed (version unknown)"')"
else
  GW_CRDS="not installed"
fi

# annotation map TSV -> JSON
jq -R -s '
  split("\n")
  | map(select(length > 0 and (startswith("#") | not)) | split("\t"))
  | map({key: .[0], value: {class: .[1], target: (.[2] // ""), note: (.[3] // "")}})
  | from_entries' "$MAP_TSV" > "$RAW/map.json"

# ---------------------------------------------------------------- analyse
PREFIX="nginx.ingress.kubernetes.io/"

# Which IngressClass names belong to the community ingress-nginx controller?
NGINX_CLASSES="$(jq -c '[.items[] | select(.spec.controller == "k8s.io/ingress-nginx") | .metadata.name]' "$RAW/ingressclasses.json")"
DEFAULT_NGINX="$(jq -r '[.items[] | select(.spec.controller == "k8s.io/ingress-nginx")
  | select(.metadata.annotations["ingressclass.kubernetes.io/is-default-class"] == "true")] | length' "$RAW/ingressclasses.json")"

jq --slurpfile map "$RAW/map.json" --argjson classes "$NGINX_CLASSES" \
   --arg prefix "$PREFIX" --argjson defaultNginx "$DEFAULT_NGINX" '
  def rank: . as $c | {"REDESIGN": 3, "REVIEW": 2, "POLICY": 1, "DIRECT": 0, "INFO": 0} | .[$c] // 2;
  def risklabel: if . >= 3 then "RED" elif . >= 1 then "AMBER" else "GREEN" end;
  [.items[] | . as $i
   | (($i.spec.ingressClassName // $i.metadata.annotations["kubernetes.io/ingress.class"]) // "") as $cls
   | ([($i.metadata.annotations // {}) | to_entries[]
       | select(.key | startswith($prefix))
       | (.key | ltrimstr($prefix)) as $a
       | (.value | tostring) as $v
       | ($map[0][$a] // {class: "REVIEW", target: "Not in the kit map - check manually", note: ""}
          | if $a == "rewrite-target" and ($v | test("\\$[0-9]")) then .class = "POLICY" else . end) as $m
       | {annotation: $a, value: $v,
          class: $m.class, target: $m.target, note: $m.note}]) as $anns
   | {
       namespace: $i.metadata.namespace,
       name: $i.metadata.name,
       class: (if $cls == "" then "(none)" else $cls end),
       managed: (if ($classes | index($cls)) != null or $cls == "nginx" then "yes"
                 elif $cls == "" and $defaultNginx > 0 then "yes (default class)"
                 elif $cls == "" then "unknown"
                 else "no" end),
       hosts: ([$i.spec.rules[]? | .host // "*"] | unique),
       paths: [$i.spec.rules[]? | (.host // "*") as $h | .http.paths[]?
               | {host: $h, path: (.path // "/"), type: (.pathType // "ImplementationSpecific"),
                  service: (.backend.service.name // .backend.resource.name // "?"),
                  port: ((.backend.service.port.number // .backend.service.port.name) // "?" | tostring)}],
       tls: (($i.spec.tls // []) | length > 0),
       tlsSecrets: [($i.spec.tls // [])[] | .secretName // empty],
       annotations: $anns,
       risk: ([$anns[].class | rank] | max // 0 | risklabel),
       foreignNginxAnnotations: ([($i.metadata.annotations // {}) | keys[] | select(startswith("nginx.org/"))] | length)
     }]' "$RAW/ingresses.json" > "$OUT/analysis.json"

# ---------------------------------------------------------------- CSV outputs
jq -r '["namespace","name","class","managed_by_ingress_nginx","hosts","paths","tls","annotations","risk"],
  (.[] | [.namespace, .name, .class, .managed, (.hosts | join(" ")), (.paths | length),
          (if .tls then "yes" else "no" end), (.annotations | length), .risk])
  | @csv' "$OUT/analysis.json" > "$OUT/inventory.csv"

jq -r '["namespace","ingress","annotation","value","class","gateway_api_target","note"],
  (.[] | . as $i | .annotations[]
   | [$i.namespace, $i.name, .annotation, (.value | gsub("\n"; " ") | .[0:200]), .class, .target, .note])
  | @csv' "$OUT/analysis.json" > "$OUT/annotations.csv"

# host + path list for testing (regex paths are commented out)
{
  echo "# host path   (generated by audit.sh - edit freely)"
  jq -r '.[] | select(.managed != "no") | .paths[]
    | select(.host != "*")
    | if (.path | test("[\\[\\]()*+?^$|{}\\\\]")) then "# regex path, test by hand: \(.host) \(.path)"
      else "\(.host) \(.path)" end' "$OUT/analysis.json" | sort -u
} > "$OUT/hosts.txt"

# ---------------------------------------------------------------- report
total=$(jq 'length' "$OUT/analysis.json")
managed=$(jq '[.[] | select(.managed != "no")] | length' "$OUT/analysis.json")
red=$(jq '[.[] | select(.managed != "no" and .risk == "RED")] | length' "$OUT/analysis.json")
amber=$(jq '[.[] | select(.managed != "no" and .risk == "AMBER")] | length' "$OUT/analysis.json")
green=$(jq '[.[] | select(.managed != "no" and .risk == "GREEN")] | length' "$OUT/analysis.json")
noclass=$(jq '[.[] | select(.class == "(none)")] | length' "$OUT/analysis.json")
f5=$(jq '[.[] | select(.foreignNginxAnnotations > 0)] | length' "$OUT/analysis.json")
hostcount=$(jq '[.[] | select(.managed != "no") | .hosts[]] | unique | length' "$OUT/analysis.json")

{
cat <<EOF
# Ingress-NGINX exit audit

- Context: \`$CTX_NAME\`
- Generated: $(date -u +"%Y-%m-%d %H:%M UTC")
- Gateway API CRDs: $GW_CRDS

## Summary

| | Count |
|---|---|
| Ingress objects in the cluster | $total |
| Served by ingress-nginx (or likely) | $managed |
| Unique hostnames to move | $hostcount |
| GREEN: core Gateway API covers everything | $green |
| AMBER: needs implementation policies or a manual check | $amber |
| RED: uses something with no equivalent, plan a redesign | $red |
| Ingresses with no class set | $noclass |

EOF

if [[ "$f5" -gt 0 ]]; then
cat <<EOF
> **Note:** $f5 Ingress object(s) use \`nginx.org/\` annotations. Those belong to F5's
> NGINX Ingress Controller, a different project that is **not** part of the retirement.
> Check which controller actually serves them before migrating.

EOF
fi

echo "## Controllers found"
echo
if [[ "$(jq length "$RAW/controller-pods.json")" -eq 0 ]]; then
  echo "No ingress-nginx controller pods found. If you run it outside the cluster or under a custom image name, check by hand."
else
  echo "| Namespace | Pod | Image | Phase |"
  echo "|---|---|---|---|"
  jq -r '.[] | "| \(.namespace) | \(.name) | \(.images | join(", ")) | \(.phase) |"' "$RAW/controller-pods.json"
fi
echo

if [[ "$(jq length "$RAW/controller-services.json")" -gt 0 ]]; then
  echo "### Entry points (these IPs/hostnames are what your DNS points at today)"
  echo
  echo "| Namespace | Service | Type | externalTrafficPolicy | Address |"
  echo "|---|---|---|---|---|"
  jq -r '.[] | "| \(.namespace) | \(.name) | \(.type) | \(.externalTrafficPolicy) | \(.address) |"' "$RAW/controller-services.json"
  echo
fi

echo "## Behaviour ingress-nginx gave you for free"
echo
cat <<'EOF'
Gateway API implementations do not copy these defaults. Decide for each one whether you need it.

1. **HTTP to HTTPS redirect.** ingress-nginx redirects automatically when an Ingress has TLS. With Gateway API you add a redirect HTTPRoute on the HTTP listener.
2. **HSTS header.** On by default in ingress-nginx (max-age 1 year). Add it back with a ResponseHeaderModifier if your sites rely on it.
3. **Timeouts.** ingress-nginx defaults to 60s proxy read/send timeouts. Envoy's default route timeout is shorter (15s) unless your implementation overrides it. Set `timeouts` explicitly on routes with slow endpoints, uploads or reports.
4. **Body size.** ingress-nginx rejects bodies over 1 MB unless `proxy-body-size` is set. Envoy behaves differently. Test your largest uploads.
5. **Client IP.** If you used `use-forwarded-headers`, `enable-real-ip` or PROXY protocol, set the equivalent in the new controller before you rely on IP allowlists or rate limits.
6. **Default 404 / error pages.** Requests for unknown hosts get a different response. Check monitoring and uptime probes that expect nginx's page.
EOF
echo

cm_count=$(jq length "$RAW/controller-configmaps.json")
if [[ "$cm_count" -gt 0 ]]; then
  echo "## Global controller settings to carry over"
  echo
  echo "These keys in the controller ConfigMap change behaviour for every Ingress:"
  echo
  echo "| ConfigMap | Key | Value |"
  echo "|---|---|---|"
  jq -r '.[] | . as $c | .data | to_entries[]
    | "| \($c.namespace)/\($c.name) | `\(.key)` | `\(.value | tostring | gsub("\n"; " ") | gsub("\\|"; "\\\\|") | .[0:80])` |"' \
    "$RAW/controller-configmaps.json"
  echo
  if jq -e '[.[].data["allow-snippet-annotations"]] | any(. == "true")' "$RAW/controller-configmaps.json" >/dev/null; then
    echo "> **Security:** \`allow-snippet-annotations\` is enabled. Combined with an unpatched controller this is a real risk. Prioritise this cluster."
    echo
  fi
fi

echo "## RED: Ingresses that need a redesign"
echo
if [[ "$red" -eq 0 ]]; then
  echo "None. Good news."
else
  jq -r '.[] | select(.managed != "no" and .risk == "RED")
    | "### \(.namespace)/\(.name)\n\nHosts: \(.hosts | join(", "))\n",
      (.annotations[] | select(.class == "REDESIGN")
       | "- `\(.annotation)` → \(.target). \(.note)\n\n  ```\n  \(.value | .[0:400] | gsub("\n"; "\n  "))\n  ```"),
      ""' "$OUT/analysis.json"
fi
echo

echo "## AMBER: annotations that need a policy or a check"
echo
if [[ "$amber" -eq 0 && "$red" -eq 0 ]]; then
  echo "None."
else
  echo "| Annotation | Used by | Target | Note |"
  echo "|---|---|---|---|"
  jq -r '[.[] | select(.managed != "no") | . as $i | .annotations[]
          | select(.class == "POLICY" or .class == "REVIEW")
          | {a: .annotation, t: .target, n: .note, who: "\($i.namespace)/\($i.name)"}]
    | group_by(.a)[]
    | "| `\(.[0].a)` | \(length) Ingress(es) | \(.[0].t) | \(.[0].n) |"' "$OUT/analysis.json"
fi
echo

if [[ "$noclass" -gt 0 ]]; then
  echo "## Ingresses with no class"
  echo
  echo "These rely on a default IngressClass or on a controller watching all Ingresses. Confirm who serves them:"
  echo
  jq -r '.[] | select(.class == "(none)") | "- \(.namespace)/\(.name) (\(.hosts | join(", ")))"' "$OUT/analysis.json"
  echo
fi

echo "## Certificates in use"
echo
jq -r '[.[] | select(.managed != "no") | . as $i | .tlsSecrets[] | "\($i.namespace)/\(.)"] | unique | .[] | "- \(.)"' "$OUT/analysis.json"
echo
echo "A Gateway listener can only reference Secrets in its own namespace unless you add a ReferenceGrant."
echo

cat <<'EOF'
## Next steps

1. Pick a replacement controller (Envoy Gateway, Traefik, NGINX Gateway Fabric, Cilium or your cloud's gateway).
2. Convert GREEN Ingresses first with `ingress2gateway`, then AMBER, then RED.
3. Test every hostname against the new entry point before you touch DNS.

The full Ingress-NGINX Exit Kit adds a side-by-side validation script, Envoy Gateway YAML for every AMBER item, a runbook with rollback at each step and a cutover checklist: https://vortik.gumroad.com/l/ingress-nginx-exit-kit

Files in this folder: `inventory.csv` (one row per Ingress), `annotations.csv` (one row per annotation), `hosts.txt` (host and path list for testing), `analysis.json` (everything, for your own tooling), `raw/` (what kubectl returned).
EOF
} > "$OUT/REPORT.md"

echo >&2
echo "Done. $managed Ingress object(s) to migrate: $green green, $amber amber, $red red." >&2
echo "Open $OUT/REPORT.md" >&2
