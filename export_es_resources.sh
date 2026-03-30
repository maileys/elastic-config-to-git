#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Export Elasticsearch resources from Elastic Cloud
#
# Downloads pipelines, templates, component templates, and lifecycle policies
# where the name matches configured patterns.
#
# Usage:
#   ./export_es_resources.sh                        # uses ./export_es_resources.conf
#   ./export_es_resources.sh -c other.conf          # uses custom config file
#   ./export_es_resources.sh -d               # dry run (list only)
#   ./export_es_resources.sh -h               # show help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/export_es_resources.conf"

# --- Argument parsing --------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Export Elasticsearch resources matching configured name patterns.

Options:
  -c, --config FILE   Path to config file (default: ./export_es_resources.conf)
  -d, --dry-run       List matching resources without downloading
  -h, --help          Show this help message

Configuration:
  Copy export_es_resources.example.conf to export_es_resources.conf and fill in your values.
  See export_es_resources.example.conf for all available options.
EOF
    exit 0
}

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# --- Load config -------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: ${CONFIG_FILE}"
    echo "Copy export_es_resources.example.conf to export_es_resources.conf and fill in your values."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# --- Validate config ---------------------------------------------------------
errors=()
[[ -z "${ES_URL:-}" ]] && errors+=("ES_URL is not set")

# Check that auth is configured
if [[ -z "${ES_API_KEY:-}" ]]; then
    errors+=("ES_API_KEY is not set")
fi

if [[ ${#errors[@]} -gt 0 ]]; then
    echo "Configuration errors:"
    for e in "${errors[@]}"; do echo "  • $e"; done
    echo ""
    echo "Edit your config file: ${CONFIG_FILE}"
    exit 1
fi

OUTPUT_DIR="${OUTPUT_DIR:-.}"
MATCH_PATTERNS="${MATCH_PATTERNS:-ausiex,custom}"
EXPORT_TYPES="${EXPORT_TYPES:-pipelines,component_templates,index_templates,lifecycle_policies}"

# Strip trailing slash from URL
ES_URL="${ES_URL%/}"

# Parse comma-separated values into arrays
IFS=',' read -ra PATTERNS <<< "$MATCH_PATTERNS"
IFS=',' read -ra TYPES <<< "$EXPORT_TYPES"

# Trim whitespace from array elements
PATTERNS=("${PATTERNS[@]// /}")
TYPES=("${TYPES[@]// /}")

# --- Helpers -----------------------------------------------------------------
CURL_OPTS=(-s --max-time 30)

# Build auth header
AUTH=(-H "Authorization: ApiKey ${ES_API_KEY}")

# Proxy support
if [[ -n "${ES_PROXY:-}" ]]; then
    CURL_OPTS+=(--proxy "${ES_PROXY}")
fi

es_get() {
    local response http_code
    response=$(curl "${CURL_OPTS[@]}" "${AUTH[@]}" -H "Content-Type: application/json" -w "\n%{http_code}" "${ES_URL}/$1" 2>&1)
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]] 2>/dev/null; then
        echo "$response"
    else
        echo "Error fetching ${ES_URL}/$1 (HTTP ${http_code})" >&2
        echo "$response" >&2
        return 1
    fi
}

matches_pattern() {
    local name="${1,,}"
    for pattern in "${PATTERNS[@]}"; do
        if [[ "$name" == *"${pattern,,}"* ]]; then
            return 0
        fi
    done
    return 1
}

should_export() {
    local type="$1"
    for t in "${TYPES[@]}"; do
        [[ "$t" == "$type" ]] && return 0
    done
    return 1
}

saved=0
skipped=0

save_resource() {
    local dir="$1" name="$2" json="$3"
    local safe_name="${name//\//_}"
    local outfile="${dir}/${safe_name}.json"

    if $DRY_RUN; then
        echo "  [dry-run] ${name}"
        ((saved++))
        return
    fi

    echo "$json" | python3 -m json.tool > "$outfile" 2>/dev/null || echo "$json" > "$outfile"
    echo "  ✓ ${name}"
    ((saved++))
}

# --- Connection test ---------------------------------------------------------
echo "Connecting to ${ES_URL} ..."
if ! cluster_info=$(es_get ""); then
    echo "Error: Could not connect to Elasticsearch at ${ES_URL}"
    echo "Check ES_URL and credentials in your config file."
    exit 1
fi

cluster_name=$(echo "$cluster_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cluster_name','unknown'))" 2>/dev/null || echo "unknown")
version=$(echo "$cluster_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',{}).get('number','unknown'))" 2>/dev/null || echo "unknown")
echo "Connected to cluster: ${cluster_name} (v${version})"
echo "Patterns: ${PATTERNS[*]}"
echo "Export types: ${TYPES[*]}"
$DRY_RUN && echo "** DRY RUN — no files will be written **"
echo ""

# --- Ingest Pipelines --------------------------------------------------------
if should_export "pipelines"; then
    echo "━━━ Ingest Pipelines ━━━"
    outdir="${OUTPUT_DIR}/pipelines"
    $DRY_RUN || mkdir -p "$outdir"

    pipelines_json=$(es_get "_ingest/pipeline")
    pipeline_names=$(echo "$pipelines_json" | python3 -c "
import sys, json
for name in sorted(json.load(sys.stdin).keys()):
    print(name)
")

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if matches_pattern "$name"; then
            body=$(echo "$pipelines_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(json.dumps(data[sys.argv[1]]))
" "$name")
            save_resource "$outdir" "$name" "$body"
        else
            ((skipped++))
        fi
    done <<< "$pipeline_names"
    echo ""
fi

# --- Component Templates -----------------------------------------------------
if should_export "component_templates"; then
    echo "━━━ Component Templates ━━━"
    outdir="${OUTPUT_DIR}/component_templates"
    $DRY_RUN || mkdir -p "$outdir"

    comp_json=$(es_get "_component_template")
    comp_names=$(echo "$comp_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ct in sorted(data.get('component_templates', []), key=lambda x: x['name']):
    print(ct['name'])
")

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if matches_pattern "$name"; then
            body=$(es_get "_component_template/${name}")
            save_resource "$outdir" "$name" "$body"
        else
            ((skipped++))
        fi
    done <<< "$comp_names"
    echo ""
fi

# --- Index Templates ----------------------------------------------------------
if should_export "index_templates"; then
    echo "━━━ Index Templates ━━━"
    outdir="${OUTPUT_DIR}/index_templates"
    $DRY_RUN || mkdir -p "$outdir"

    idx_json=$(es_get "_index_template")
    idx_names=$(echo "$idx_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in sorted(data.get('index_templates', []), key=lambda x: x['name']):
    print(t['name'])
")

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if matches_pattern "$name"; then
            body=$(es_get "_index_template/${name}")
            save_resource "$outdir" "$name" "$body"
        else
            ((skipped++))
        fi
    done <<< "$idx_names"
    echo ""
fi

# --- ILM Lifecycle Policies ---------------------------------------------------
if should_export "lifecycle_policies"; then
    echo "━━━ Lifecycle Policies (ILM) ━━━"
    outdir="${OUTPUT_DIR}/lifecycle_policies"
    $DRY_RUN || mkdir -p "$outdir"

    ilm_json=$(es_get "_ilm/policy")
    ilm_names=$(echo "$ilm_json" | python3 -c "
import sys, json
for name in sorted(json.load(sys.stdin).keys()):
    print(name)
")

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if matches_pattern "$name"; then
            body=$(echo "$ilm_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(json.dumps(data[sys.argv[1]]))
" "$name")
            save_resource "$outdir" "$name" "$body"
        else
            ((skipped++))
        fi
    done <<< "$ilm_names"
    echo ""
fi

# --- Summary -----------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
$DRY_RUN && printf "[DRY RUN] "
echo "Exported ${saved} resources (${skipped} skipped)"

if ! $DRY_RUN; then
    echo "Output:"
    for type in "${TYPES[@]}"; do
        dir="${OUTPUT_DIR}/${type}"
        if [[ -d "$dir" ]]; then
            count=$(find "$dir" -name '*.json' 2>/dev/null | wc -l)
            echo "  ${dir}/  (${count} files)"
        fi
    done
fi
