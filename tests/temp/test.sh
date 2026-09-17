# Temporary files and directories: named as documented, created under TMPDIR
# or the base given, deleted by the with_ forms on Ok and on Err, and left for
# the caller by the create_ forms. A callback may move or delete what it was
# given: renaming a temp file into place used to come back as NotFound. A
# callback may change the working directory: cleanup by the relative name
# looked in the wrong place, and once NotFound counted as clean, leaked.
#
# What is left behind is checked from outside the app: TMPDIR must hold exactly
# what the create_ calls made, and the `_in` base nothing.
source ../lib.sh
new_project
T="$TMP/temp"
mkdir -p "$T/tmpbase" "$T/base"
build_app app.roc temp
# A trailing slash on TMPDIR is the macOS default; the paths handed back must
# not carry a doubled separator.
got=$(cd "$T" && umask 022 && TMPDIR="$T/tmpbase/" capped 60 "$(bin temp)") || { echo "FAIL: the temp app did not finish"; exit 1; }
read -r dir_ok dir_err file_ok created in_base missing moved moved_cwd <<<"$got"
created_file=${created##*,}
without_file=${created%,*}
created_name=${without_file##*,}
check() { [[ "$2" == "$3" ]] || { echo "FAIL: $1 was '$2', want '$3'"; exit 1; }; }
check "with_dir! (named, under TMPDIR, deleted)" "$dir_ok" "True,True,gone"
check "with_dir! on Err" "$dir_err" "refused,gone"
check "with_file!" "$file_ok" "written,True,gone"
check "create_dir!/create_file!" "${without_file%,*}" "True,True,True"
check "_in forms under a relative base" "$in_base" "True,True"
check "a missing base" "$missing" "notfound"
[[ "$created" != *"//"* ]] || { echo "FAIL: a temp path doubled the separator: '$created'"; exit 1; }
check "a callback moving or deleting its temp" "$moved" "moved,data,deleted"
check "a callback changing the working directory" "$moved_cwd" "cwd-gone"
mode() { python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o7777, "o"))' "$1"; }
# 0600 and 0700, as mkstemp and mkdtemp make them: the umask can only take more
# away, and /tmp is shared.
[[ "$(mode "$T/tmpbase/$created_file")" == 600 ]] || { echo "FAIL: a temp file has mode $(mode "$T/tmpbase/$created_file"), want 600"; exit 1; }
[[ "$(mode "$T/tmpbase/$created_name")" == 700 ]] || { echo "FAIL: a temp directory has mode $(mode "$T/tmpbase/$created_name"), want 700"; exit 1; }
[[ -d "$T/tmpbase/$created_name" ]] || { echo "FAIL: create_dir! reported $created_name, which is not in TMPDIR"; exit 1; }
left=$(cd "$T/tmpbase" && find . -mindepth 1 | sort | tr '\n' ' ')
[[ $(find "$T/tmpbase" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') == 1 && $(find "$T/tmpbase" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ') == 2 ]] \
	|| { echo "FAIL: TMPDIR should hold one created directory and two created files, holds: $left"; exit 1; }
[[ -z "$(ls -A "$T/base")" ]] || { echo "FAIL: the with_*_in forms left: $(ls -A "$T/base")"; exit 1; }
echo "ok: temp names are unguessable and exclusive; with_ forms clean up on Ok and Err, create_ forms leave their result"
