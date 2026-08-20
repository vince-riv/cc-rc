set -euo pipefail
# ~/.claude/: overwrite from image, never delete extras
# (claude's own state/credentials survive; --ignore-times
# forces the overwrite even on a size+mtime match).
# Everywhere else: full reset via --delete, except ~/.cc-rc/
# (our login-complete marker - must survive every boot).
# --no-owner --no-group --no-perms: the PVC mountpoint root
# is owned by root (fsGroup only adds group-write, it
# doesn't chown), so non-root can never chown/chgrp/chmod
# it - EPERM, even though writing new files inside it works
# fine. New files still land with sane permissions anyway.
mkdir -p /home/dev/.claude /mnt/home-pvc/.claude
rsync -a --no-times --no-owner --no-group --no-perms --ignore-times \
  /home/dev/.claude/. /mnt/home-pvc/.claude/
rsync -a --delete --no-times --no-owner --no-group --no-perms \
  --exclude=.claude --exclude=.cc-rc \
  /home/dev/. /mnt/home-pvc/
