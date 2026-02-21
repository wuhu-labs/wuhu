#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<EOF
Usage:
  $(basename "$0") [port] [WuhuCore|/path/to/catalog.docc]
  $(basename "$0") --port <port> [WuhuCore|/path/to/catalog.docc]

Examples:
  $(basename "$0")
  $(basename "$0") 8081
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

port="8080"
catalog="WuhuCore"

if [[ "${1:-}" == "--port" ]]; then
  port="${2:-}"
  catalog="${3:-WuhuCore}"
elif [[ -n "${1:-}" ]]; then
  port="$1"
  catalog="${2:-WuhuCore}"
fi

if [[ ! "$port" =~ ^[0-9]+$ ]]; then
  echo "Invalid port: '$port'" >&2
  usage
  exit 2
fi

case "$catalog" in
  WuhuCore)
    target="WuhuCore"
    catalog_path="$repo_root/Sources/WuhuCore/WuhuCore.docc"
    doc_path="/documentation/wuhucore"
    ;;
  /*|./*|../*)
    target=""
    catalog_path="$catalog"
    doc_path="/"
    ;;
  *)
    echo "Unknown catalog '$catalog'." >&2
    usage
    exit 2
    ;;
esac

symbol_graph_dir="$repo_root/.docc-build/symbol-graphs"
mkdir -p "$symbol_graph_dir"

cd "$repo_root"

build_args=(
  -c debug
  -Xswiftc -emit-symbol-graph
  -Xswiftc -emit-symbol-graph-dir -Xswiftc "$symbol_graph_dir"
  -Xswiftc -symbol-graph-minimum-access-level -Xswiftc internal
)
if [[ -n "$target" ]]; then
  swift build --target "$target" "${build_args[@]}"
else
  swift build "${build_args[@]}"
fi

echo "Previewing DocC catalog: $catalog_path"
echo "Symbol graphs: $symbol_graph_dir"
echo "Port: $port"
echo "URL: http://localhost:$port$doc_path"

exec xcrun docc preview "$catalog_path" \
  --additional-symbol-graph-dir "$symbol_graph_dir" \
  --port "$port"
