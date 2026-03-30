# Elasticsearch Config Exporter

Stop losing track of your Elasticsearch customisations. This script exports your ingest pipelines, index templates, component templates, and ILM lifecycle policies from Elastic Cloud into flat JSON files — ready to commit, diff, review, and restore.

## Why?

Elastic Cloud is great until someone tweaks a pipeline at 2am and nobody knows what changed. Sound familiar?

With this tool you can:

- **Version control your Elasticsearch config** — commit pipelines, templates, and policies to Git just like application code
- **Track changes over time** — `git diff` will show you exactly what changed between exports
- **Recover from mistakes** — rolled back a deployment but lost your custom pipeline? It's in Git
- **Audit and review** — PRs for infrastructure changes, not just app code
- **Migrate between clusters** — export from one, import to another
- **Filter by naming convention** — only export resources matching your patterns (e.g. `custom-*`, `ausiex-*`), skipping the hundreds of built-in Elastic defaults

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/youruser/es-config-exporter.git
cd es-config-exporter

# 2. Create your config
cp export_es_resources.example.conf export_es_resources.conf

# 3. Add your Elastic Cloud endpoint and credentials
vi export_es_resources.conf

# 4. Run the export
./export_es_resources.sh

# 5. Commit the results
git add pipelines/ component_templates/ index_templates/ lifecycle_policies/
git commit -m "ES config snapshot $(date +%Y-%m-%d)"
```

## Configuration

All settings live in `export_es_resources.conf` (gitignored by default — your credentials stay local).

| Setting          | Description                                      | Default                                                            |
|------------------|--------------------------------------------------|--------------------------------------------------------------------|
| `ES_URL`         | Elastic Cloud endpoint                           | *(required)*                                                       |
| `ES_API_KEY`     | API key (create in Kibana → Stack Management)    | *(required)*                                                       |
| `ES_PROXY`       | HTTP(S) proxy URL                                | —                                                                  |
| `MATCH_PATTERNS` | Comma-separated name patterns (case-insensitive) | `ausiex,custom`                                                    |
| `EXPORT_TYPES`   | Comma-separated resource types to export         | `pipelines,component_templates,index_templates,lifecycle_policies`  |
| `OUTPUT_DIR`     | Base directory for exported files                | `.` (current directory)                                            |

## Usage

```bash
# Default (uses ./export_es_resources.conf)
./export_es_resources.sh

# Custom config file
./export_es_resources.sh -c /path/to/other.conf

# Dry run — see what would be exported without writing files
./export_es_resources.sh -d

# Show help
./export_es_resources.sh -h
```

## Output Structure

Each resource is saved as a pretty-printed JSON file, one per resource:

```
├── component_templates/
│   ├── custom-logs-mappings.json
│   └── ausiex-base-settings.json
├── index_templates/
│   └── custom-logs-template.json
├── pipelines/
│   ├── ausiex-ingest-pipeline.json
│   └── custom-geoip-enrichment.json
└── lifecycle_policies/
    └── custom-30d-retention.json
```

Because they're individual JSON files, `git diff` gives you clean, readable diffs when something changes between exports.

## Suggested Workflows

**Scheduled exports** — run the script on a cron or CI schedule, auto-commit, and you've got a rolling history of your Elasticsearch config without lifting a finger.

```bash
# Example: cron entry for daily export at midnight
0 0 * * * cd /path/to/repo && ./export_es_resources.sh && git add -A && git diff --cached --quiet || git commit -m "ES config snapshot $(date +\%Y-\%m-\%d)"
```

**Before/after deployments** — export before you deploy, export after. The diff is your change log.

**Disaster recovery** — if a cluster goes sideways, the JSON files contain everything you need to recreate your custom resources via the Elasticsearch API.

## Requirements

- `bash` 4+
- `curl`
- `python3` (for JSON parsing and pretty-printing)

## License

MIT
