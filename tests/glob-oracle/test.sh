# Glob.expand! against zsh, over a generated corpus.
#
# Hand-written cases kept missing whole classes — an earlier `**`, a link one
# level down, a pattern whose components each behave differently — so this
# compares every pattern in the corpus with what zsh expands it to, rather
# than with a line someone wrote down. zsh, not bash: macOS ships bash 3.2,
# which has no `**` at all, and the link rule this package implements is zsh's
# (D-S2-46).
#
# The fixture deliberately holds no unreadable directory: a refused entry is an
# error here and a silent skip in zsh (D-S2-34), and that difference is covered
# by tests/walk-glob instead. Two syntax differences are left out as well: a
# bare trailing `**` means "any depth" in globset's syntax and "one component"
# in zsh's, and a trailing `**/` takes one or more components here where zsh's
# takes zero or more (so zsh lists the directory the pattern started from).
source ../lib.sh
command -v zsh >/dev/null || { echo "ok: skipped, no zsh on this machine"; exit 0; }
new_project
build_app app.roc oracle
G="$TMP/oracle"
mkdir -p "$G/src/lib/deep" "$G/src/bin" "$G/vendor/pkg/src" "$G/docs" "$G/.hidden/inner" "$G/dir with space"
touch "$G/src/main.roc" "$G/src/lib/util.roc" "$G/src/lib/data.json" "$G/src/lib/deep/x.roc" \
	"$G/src/bin/tool.roc" "$G/vendor/pkg/src/lib.roc" "$G/vendor/pkg/README.md" "$G/docs/guide.md" \
	"$G/docs/.notes.md" "$G/.hidden/inner/secret.roc" "$G/top.roc" "$G/top.txt" "$G/dir with space/f.roc"
# Links: to a directory, one level down, to a file, and dangling.
ln -s ../vendor/pkg "$G/src/linked-pkg"
ln -s vendor "$G/vendorlink"
ln -s top.roc "$G/filelink"
ln -s nowhere "$G/danglink"
patterns=(
	'*' '*.roc' '*/*.roc' '*/*/*.roc' 'src/*' 'src/*/' 'src/**/*.roc' '**/*.roc'
	'**/*.md' 'src/*/*.{roc,json}' '{src,docs}/*' 'src/l*/[dr]*' 'src/lib/deep/*' '*/lib/**/*.roc'
	'src/linked-pkg/*' 'src/linked-pkg/src/*.roc' 'src/*/src/*.roc' '**/linked-pkg/src/*.roc'
	'src/*/**/*.roc' 'src/l*/**/*.roc' '*/**/*.roc' '*link/**/*.md' 'src/linked-pkg/**/*.roc'
	'*/*/**/*.md' '**/*/**/*.roc'
	'src/**/src/*.roc' 'vendorlink/*' 'vendorlink/pkg/*.md' '*/pkg/src/*.roc' 'filelink' 'filelink/*'
	'danglink' 'danglink/*' 'dir*/*.roc' '*space*/*' '.*/inner/*.roc' '*/inner/*.roc'
	'src/[!b]*/*.roc' 'top.?oc' '**/deep/*' 'src/lib/../*.roc' 'no-such/*' '*/no-such/*'
)
cd "$G" && capped 60 "$(bin oracle)" "${patterns[@]}" > "$TMP/ours.tsv" || { echo "FAIL: the oracle app did not finish"; exit 1; }
failed=0
for pattern in "${patterns[@]}"; do
	# zsh prints a matched directory as `name/` for a pattern ending in `/`;
	# the path is the same one.
	# `print -rl --` with nothing to print still prints one empty line.
	# `sort -u` on zsh's side only: two `**` in one pattern make zsh list a path
	# once per way it matched, where a match here is a path, not a derivation.
	# Ours is sorted plainly, so a duplicate of our own still shows up.
	zsh -c "setopt nullglob; print -rl -- $pattern" 2>/dev/null | sed 's:/$::' | sed '/^$/d' | sort -u > "$TMP/want.txt"
	awk -F'\t' -v p="$pattern" '$1 == p && $2 != "" { print $2 }' "$TMP/ours.tsv" | sort > "$TMP/got.txt"
	cmp -s "$TMP/want.txt" "$TMP/got.txt" || {
		echo "DIFFER $pattern"
		diff <(sed 's/^/  zsh:  /' "$TMP/want.txt") <(sed 's/^/  ours: /' "$TMP/got.txt") | head -6
		failed=1
	}
done
[[ "$failed" == 0 ]] || { echo "FAIL: expansions differ from zsh (above)"; exit 1; }
echo "ok: ${#patterns[@]} patterns expand exactly as zsh does, links and all"
