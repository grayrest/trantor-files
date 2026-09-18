# A tree copy reproduces directories and files with their modes, contents, and links as links,
# checked by comparing snapshots of both trees taken without following links.
#
# The same app runs twice: on the default world, and on an `fs-confined` one,
# where a link is refused unless its target already exists inside the root.
# `a-link` sorts before `z-target.txt`, so a copy that made links in walk order
# would fail there. There, too, a dangling replacement link cannot be made, and
# the link it would have replaced must still be in place.
source ../lib.sh
umask 022
new_project
fixture() {
	mkdir -p "$1/src/sub/deeper"
	echo a > "$1/src/a.txt"
	printf '#!/bin/sh\n' > "$1/src/exec.sh"; chmod 755 "$1/src/exec.sh"
	echo b > "$1/src/sub/b.txt"
	echo c > "$1/src/sub/deeper/c.txt"
	echo hidden > "$1/src/.hidden"
	# A private directory stays private: made under the umask it came out 755.
	mkdir -p "$1/src/private"; echo key > "$1/src/private/key"; chmod 700 "$1/src/private"
	echo z > "$1/src/z-target.txt"
	ln -s z-target.txt "$1/src/a-link"
	ln -s sub "$1/src/dirlink"
	ln -s ../a.txt "$1/src/sub/up-link"
	# Links to links and through one: made in walk order, confined, each is
	# refused because what it points at is not there yet.
	ln -s c-link "$1/src/b-link"
	ln -s z-target.txt "$1/src/c-link"
	ln -s dirlink/b.txt "$1/src/a2"
	mkdir -p "$1/ow-src" "$1/ow-dst"
	ln -s nowhere "$1/ow-src/l"; ln -s old "$1/ow-dst/l"
	mkdir -p "$1/escape"; ln -s /usr "$1/escape/l"
	mkdir -p "$TMP/outside"; touch "$TMP/outside/f"; ln -s "$TMP/outside" "$1/outlink"
}
# run_copy DIR APP OVERWRITE LINK ESCAPE GLOBS — OVERWRITE is the dangling-link
# overwrite's outcome, LINK what ow-dst/l must hold after it, ESCAPE how a
# followed walk reports a link out of the root, GLOBS how ../outside/f,
# ../outside/* and outlink/* expand.
run_copy() {
	local dir=$1 app=$2 got want
	want="ok err:AlreadyExists ok ok err:NotFound $3 ok,ok ok,err:NotFound $5 $6"
	got=$(cd "$dir" && capped 60 "$(bin "$app")") || { echo "FAIL: $app did not finish"; exit 1; }
	[[ "$got" == "$want" ]] || {
		echo "FAIL: $app outcomes were '$got', want '$want'"
		echo "      (copy again-without-overwrite overwrite single-file missing overwrite-dangling long-name-overwrite copy-from-cwd,copy-from-empty followed-escape glob-escapes)"; exit 1; }
	diff <(python3 snapshot.py "$dir/src") <(python3 snapshot.py "$dir/dst") \
		|| { echo "FAIL: $app: the copy differs from its source (above)"; exit 1; }
	[[ "$(cat "$dir/single.txt")" == a ]] || { echo "FAIL: $app: a single file copy holds '$(cat "$dir/single.txt")'"; exit 1; }
	[[ "$(readlink "$dir/ow-dst/l")" == "$4" ]] || { echo "FAIL: $app: ow-dst/l holds '$(readlink "$dir/ow-dst/l")', want '$4'"; exit 1; }
	[[ "$(cat "$dir/cwd-copy/ab" 2>/dev/null)" == x ]] || { echo "FAIL: $app: copying from \".\" did not keep the name ab: $(ls "$dir/cwd-copy" 2>&1)"; exit 1; }
	[[ -z "$(find "$dir" -name '.copy-in-progress-*')" ]] || { echo "FAIL: $app: a temporary replacement was left behind"; exit 1; }
}
fixture "$TMP/plain"
build_app app.roc copy
run_copy "$TMP/plain" copy ok nowhere dir ../outside/f,../outside/f,outlink/f
printf '\n[wiring]\nfs = "fs-confined"\n' >> "$TMP/myapp/world.toml"
fixture "$TMP/confined"
build_app app.roc copy-confined
run_copy "$TMP/confined" copy-confined err:NotFound old link err:PermissionDenied,err:PermissionDenied,err:PermissionDenied
echo "ok: a tree copy keeps contents, modes and links, refuses or replaces what exists, and works confined"
