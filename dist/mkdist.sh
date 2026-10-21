#!/bin/bash
# mkdist.sh — 从仓库源文件生成可分发 tarball (arpfanout-<ver>.tar.gz)
# 用法: bash dist/mkdist.sh [版本号, 默认从 git describe 或 1.5]
set -e
cd "$(dirname "$0")/.."
VER="${1:-$(git describe --tags 2>/dev/null | cut -c2- || echo 1.5)}"
STAGE=$(mktemp -d)/arpfanout-$VER
mkdir -p "$STAGE"
cp src/arpfanout.bpf.c src/arpfanout.bpf.o src/arpfanout src/arpfanout.service \
   src/arpfanout.env src/arpfanout-remove src/arpfanout-uninstall "$STAGE/"
cp dist/install.sh dist/check.sh dist/deploy_hosts.sh dist/test_v6.sh dist/test_10bonds.sh "$STAGE/"
cp README.md "$STAGE/README.md"
tar czf arpfanout-$VER.tar.gz -C "$(dirname "$STAGE")" arpfanout-$VER
echo "built: $(pwd)/arpfanout-$VER.tar.gz"
echo "内容:"; tar tzf arpfanout-$VER.tar.gz | sed 's/^/  /'
