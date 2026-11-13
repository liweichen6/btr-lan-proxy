#!/bin/sh
# Copies the thread ripper download core from a PiliPlus checkout.
# The three files are used unchanged, apart from their import paths.
#   tool/sync_ripper.sh /path/to/PiliPlus
set -eu
src="${1:?usage: tool/sync_ripper.sh /path/to/PiliPlus}"
from="$src/lib/services/thread_ripper"
to="$(cd "$(dirname "$0")/.." && pwd)/lib/src/thread_ripper"
mkdir -p "$to"
for file in auto_concurrency.dart cdn_resolver.dart range_proxy.dart; do
  sed "s#package:PiliPlus/services/thread_ripper/##" "$from/$file" > "$to/$file"
done
commit="$(git -C "$src" log -1 --format=%H -- lib/services/thread_ripper)"
remote="$(git -C "$src" remote get-url origin | sed -E 's#(https://)[^@/]*@#\1#')"
printf 'source: %s\ncommit: %s\npath: lib/services/thread_ripper\n' \
  "$remote" "$commit" > "$to/ORIGIN"
echo "synced thread ripper at $commit"
