#!/bin/zsh
set -eu
cd "$(dirname "$0")"
printf '请输入真实 HTTPS 源根地址（包含实际子目录）：\n'
IFS= read -r base
output="upload-$(date +%Y%m%d-%H%M%S)"
python3 prepare-release.py --base-url "$base" --output "$output"
python3 validate-release.py "$output" "$base"
printf '\n已生成并校验：%s/%s\n已有源请合并素材与安装包，再重建全源索引，不要直接覆盖原 Packages。\n' "$PWD" "$output"
printf '按回车关闭。\n'
IFS= read -r answer
