set -euo pipefail
# ~/.claude/: overwrite from image, never delete extras
# (claude's own state/credentials, e.g. ~/.claude/.credentials.json,
# survive; --ignore-times forces the overwrite even on a size+mtime
# match).
# Everywhere else: full reset via --delete, except ~/.cc-rc/ (our
# login-complete marker) and ~/.claude.json - a top-level file
# (sibling to the ~/.claude/ directory, not inside it - claude joins
# it directly with homedir(), unlike .credentials.json which goes
# through the config dir) holding claude's own account/session state,
# never shipped by the image, that would otherwise get deleted every
# boot since it never matches anything in the source.
# --no-owner --no-group --no-perms: the PVC mountpoint root
# is owned by root (fsGroup only adds group-write, it
# doesn't chown), so non-root can never chown/chgrp/chmod
# it - EPERM, even though writing new files inside it works
# fine. New files still land with sane permissions anyway.
# --executability: without it, a file that's already the right size
# (e.g. a claude binary left non-executable by some prior mishap) is
# treated as unchanged by rsync's quick check and never re-synced -
# --no-perms skips it, so a corrupted exec bit stays corrupted forever,
# even across full pod recreation. This flag re-checks and restores
# just the source's execute bit, without needing a full re-transfer.
mkdir -p /home/dev/.claude /mnt/home-pvc/.claude
rsync -a --no-times --no-owner --no-group --no-perms --executability --ignore-times \
  /home/dev/.claude/. /mnt/home-pvc/.claude/
rsync -a --delete --no-times --no-owner --no-group --no-perms --executability \
  --exclude=.claude --exclude=.cc-rc --exclude=.claude.json \
  /home/dev/. /mnt/home-pvc/
