#!/usr/bin/env bash
# Chạy bằng node-admin (KHÔNG dùng sudo cho cả script) trong thư mục checkout trên node01.
# Kiểm tra checkout sạch, kiểm tra cú pháp, rồi cài bản root-sở-hữu vào /usr/local/sbin.
set -euo pipefail
cd "$(dirname "$0")"
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree không sạch - dừng. Xem: git status --short"; exit 1
fi
commit=$(git rev-parse --short HEAD)
ver=$(git describe --tags --always)
echo "Sẽ cài replicate_profiles.sh từ commit $commit ($ver)"
bash -n replicate_profiles.sh
sudo install -m 700 -o root -g root replicate_profiles.sh /usr/local/sbin/replicate_profiles.sh
echo "$commit $ver $(date -Is)" | sudo tee /usr/local/sbin/replicate_profiles.sh.version >/dev/null
echo "Đã cài. Thử 1 container trước khi bật cron:"
echo "  sudo /usr/local/sbin/replicate_profiles.sh VPS.378062.NguyenThuHa"
