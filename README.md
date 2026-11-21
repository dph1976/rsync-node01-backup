# rsync-node01-backup

Script đẩy bản sao của **node01** (Chrome profile, code, secrets, state) sang **node-backup** (VM Hyper-V, bản dự phòng lạnh). Tài liệu đầy đủ: `Node-backup-environtment-and-processes.md` (mục 7 và 9).

## Luồng quản lý code

PC01 (sửa, commit) → GitHub (repo private) → node01 (`git pull`, đọc `git diff`, `install_on_node01.sh`) → rsync mỗi ngày → node-backup. Node-backup **không** tự `git pull`; nó luôn là bản sao đúng với những gì node01 đang chạy.

## Tệp

| Tệp | Vai trò |
|---|---|
| `replicate_profiles.sh` | Script sync, chạy bằng root trên node01 |
| `install_on_node01.sh` | Cài bản root-sở-hữu vào `/usr/local/sbin`, ghi commit đã cài |
| `crontab.root.example` | Mẫu cron của root (16:00, 16:40, 17:20) |
| `.gitattributes` | Ép kết thúc dòng LF cho `.sh` (tránh lỗi `bash\r` khi soạn trên Windows) |

## Điều kiện trên node01

- Đã cài `rsync`; khóa `/root/.ssh/id_ed25519_replica` (không passphrase, chỉ nằm trên node01).
- Tailscale ACL cho `tag:node01` → `tag:nodebackup` `tcp:22`.

## Điều kiện trên node-backup

Dòng trong `~/.ssh/authorized_keys` của `node-admin` (khóa công khai của node01):

```
restrict,from="100.86.15.13",command="/usr/bin/rrsync -wo -no-lock /data/replica" ssh-ed25519 <KHÓA_CÔNG_KHAI> node01-replica
```

Thư mục đích: `/data/replica/{volumes,history,env,state}`.

## Triển khai và cập nhật

1. Trên PC01: sửa, commit, push (`.gitattributes` giữ LF).
2. Trên node01 (node-admin): `git pull`, xem `git diff HEAD@{1}`, rồi `./install_on_node01.sh`.
3. Thử 1 container: `sudo /usr/local/sbin/replicate_profiles.sh VPS.378062.NguyenThuHa`
4. Chạy cả bộ lần đầu trong `tmux`: `sudo /usr/local/sbin/replicate_profiles.sh` (xem log `/data/logs/vps/replicate_profiles.log`).
5. Cron: xem `crontab.root.example`.

## Quy tắc an toàn

- Cron của root chỉ chạy bản ở `/usr/local/sbin`, **không** chạy thẳng file trong thư mục git (node-admin sửa được, kể cả qua Samba).
- Không commit khóa, `.env`, mật khẩu, nội dung `authorized_keys` thật.
- Script bỏ qua khi còn worker/Controller/OOT/backup/token đang chạy, khi Chrome đang chạy trong container, hoặc khi nguồn thiếu `Default/` (tránh `--delete` xóa nhầm bản sao).
- Mirror một chiều không phải backup đầy đủ; backup hằng tuần lên Google Drive vẫn phải giữ.
- Mỗi account chỉ một bên chạy: không chạy Controller/AM/PM/OOT/token trên node-backup khi node01 còn hoạt động.
- `ssh` dùng làm đường truyền cho rsync không được có `-n`.
