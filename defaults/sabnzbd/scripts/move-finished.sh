#!/bin/bash
# move-finished — SABnzbd post-processing script (prowlarr-stack).
#
# Jobs assemble in complete_dir = /downloads/completed/.staging: all of
# SABnzbd's churn (par2 verify/repair, _UNPACK_ folders, obfuscated temp
# names, final deobfuscation renames) happens there, where Media Centaur's
# watcher deliberately never looks (`.staging` is a reserved, invisible
# directory name). This script is the last post-processing step: on success
# it drops the recovery cruft and moves the finished job — final names,
# final content — into /downloads/completed in one rename. Both paths live
# on the same bind mount, so the move is atomic: the importer only ever
# sees a complete job.
#
# Failed jobs stay in .staging (invisible to the importer). Deleting the
# failed entry from SABnzbd's history with "delete files" cleans them up.
#
# Managed by prowlarr-stack: ./setup refreshes this file from defaults/ on
# every run — local edits are overwritten.
set -euo pipefail

# SABnzbd env contract (3.x+): SAB_COMPLETE_DIR is the job's folder,
# SAB_PP_STATUS is 0 when verify/repair/unpack all succeeded.
job_dir="${SAB_COMPLETE_DIR:?SAB_COMPLETE_DIR not set — run via SABnzbd}"
pp_status="${SAB_PP_STATUS:-1}"

# The final destination is the container path of the completed mount —
# fixed by docker-compose.yml, shared with the importer. The override
# exists for the test harness only.
dest_root="${MOVE_FINISHED_DEST:-/downloads/completed}"

if [[ "$pp_status" != "0" ]]; then
  echo "post-processing failed (status=$pp_status) — job left in staging: $job_dir"
  exit 0
fi

# Recovery/index files did their job during repair; the library only
# wants the media.
find "$job_dir" -type f \( -iname '*.par2' -o -iname '*.sfv' -o -iname '*.nzb' \) -delete

dest="$dest_root/$(basename "$job_dir")"
if [[ -e "$dest" ]]; then
  # A same-named job already landed (re-grab). Don't clobber it — land
  # uniquely and let the library sort duplicates out.
  dest="${dest}.$(date +%s)"
fi

mv -- "$job_dir" "$dest"
echo "moved finished job to $dest"
