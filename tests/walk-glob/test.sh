# Walking a tree and expanding globs over it, against a real directory.
#
# The walk's order (depth first, sorted in each directory), its depth numbers,
# link handling both ways, max_depth, SkipDir and Stop are each visible in the
# output. Globs cover `**`, a literal start directory, alternatives, a missing
# start (no match, not an error), an invalid pattern and an absolute pattern.
# The pruning is observable: `locked/inner` cannot be read, so `*/a.txt` only
# succeeds because the search never opens a directory its pattern rules out,
# while `**/*.json` has to open it and fails. A glob starts through a linked
# directory (`/tmp` is one on macOS); `max_depth: 0` visits nothing; a followed
# link back to a directory the walk is inside is not descended, by identity:
# to itself, through an absolute alias, and across sibling directories (which
# once never finished); a followed link that cannot be read fails the walk.
# Absolute and relative alternatives each search from their own start, a
# doubled slash is one, and braces cannot build a `**`. A followed link that
# loops or runs through a file is a link, not a failure; a link to an
# unreadable directory fails only a walk that enters it; `./x` and `x` are one
# result. A trailing `/` matches a link only if it resolves to a directory: a
# link to a file or to nothing behind an unsearchable directory once matched.
# A class that can match nothing is an invalid pattern. A link whose target
# name is too long to look up leads nowhere, like a loop: a followed walk
# reports it as a link, and a glob through it, or naming such a name, is no
# match. A wildcard searches through a link to a directory, as bash does, and
# `**` neither matches a link nor reaches past one, wherever it sits in the
# pattern. A linked directory that cannot be listed is no match, where a real
# one still fails the walk (D-S2-34).
source ../lib.sh
new_project
W="$TMP/walk"
mkdir -p "$W/tree/src/lib" "$W/tree/.git" "$W/tree/zeta/deep" "$W/locked/inner"
touch "$W/tree/a.txt" "$W/tree/b.roc" "$W/tree/.hidden.roc" "$W/tree/src/main.roc" \
	"$W/tree/src/lib/util.roc" "$W/tree/src/lib/data.json" "$W/tree/.git/config.roc" "$W/tree/zeta/deep/x.roc"
ln -s src "$W/tree/link"
ln -s tree "$W/linked"
mkdir -p "$W/cycle"; touch "$W/cycle/f"; ln -s . "$W/cycle/l1"; ln -s "$W/cycle" "$W/cycle/abs"
mkdir -p "$W/fork/a" "$W/fork/b"
ln -s ../b "$W/fork/a/l1"; ln -s ../b "$W/fork/a/l2"; ln -s ../a "$W/fork/b/m1"; ln -s ../a "$W/fork/b/m2"
mkdir -p "$W/followerr"; ln -s ../locked/inner "$W/followerr/l"
mkdir -p "$W/nowhere"; ln -s l2 "$W/nowhere/l1"; ln -s l1 "$W/nowhere/l2"; touch "$W/nowhere/file"; ln -s file/child "$W/nowhere/through"
mkdir -p "$W/deferred"; ln -s ../locked/inner "$W/deferred/link"
mkdir -p "$W/ronly/sub"; touch "$W/ronly/f"; chmod 400 "$W/ronly"
ln -s looped "$W/looped"
mkdir -p "$W/lit/xonly"; touch "$W/lit/xonly/f"; chmod 111 "$W/lit/xonly"
mkdir -p "$W/errdir/shut"; chmod 000 "$W/errdir/shut"; ln -s errdir "$W/lerr"
mkdir -p "$W/perm/zdir" "$W/perm/xdir"; touch "$W/perm/xdir/f" "$W/perm/file"
chmod 000 "$W/perm/zdir"; chmod 111 "$W/perm/xdir"
ln -s zdir "$W/perm/lz"; ln -s xdir "$W/perm/lx"; ln -s file "$W/perm/lf"
mkdir -p "$W/pkg" "$W/vendored/deep" "$W/vendored/mid/deep"; touch "$W/vendored/w.txt" "$W/vendored/deep/w.txt" "$W/vendored/mid/deep/w.txt" "$W/vendored/deep/x.txt"
ln -s ../vendored "$W/pkg/vendorlink"
# The unlistable target sits outside the walked tree, so only a walk that
# follows the link reaches it.
mkdir -p "$TMP/shut-outside/inner"; touch "$TMP/shut-outside/x.txt"; chmod 000 "$TMP/shut-outside"
mkdir -p "$W/lp"; ln -s "$TMP/shut-outside" "$W/lp/shutlink"
# A real unreadable directory below a link: the link is skippable, it is not.
mkdir -p "$TMP/below-link/real-shut"; touch "$TMP/below-link/seen.txt"; chmod 000 "$TMP/below-link/real-shut"
mkdir -p "$W/shut"; ln -s "$TMP/below-link" "$W/shut/through"
mkdir -p "$W/long"; ln -s "$(printf 'a%.0s' $(seq 300))" "$W/long/toolong"
mkdir -p "$W/p2/shut"; touch "$W/p2/shut/f"; chmod 000 "$W/p2/shut"; ln -s shut/f "$W/p2/lfile"; ln -s shut/missing "$W/p2/ldang"
chmod 000 "$W/locked/inner"
trap 'chmod 700 "$W/locked/inner" "$W/ronly" "$W/lit/xonly" "$W/errdir/shut" "$W/perm/zdir" "$W/perm/xdir" "$W/p2/shut" "$TMP/shut-outside" "$TMP/below-link/real-shut" 2>/dev/null || true' EXIT
build_app app.roc walk
# 30 seconds: the 131072-alternative case below took 144 seconds on its own
# while grouping the starts still copied each group per alternative.
got=$(cd "$W" && capped 30 "$(bin walk)") || { echo "FAIL: the walk app did not finish"; exit 1; }
want="tree/.git:d1,tree/.git/config.roc:f2,tree/.hidden.roc:f1,tree/a.txt:f1,tree/b.roc:f1,tree/link:l1,tree/src:d1,tree/src/lib:d2,tree/src/lib/data.json:f3,tree/src/lib/util.roc:f3,tree/src/main.roc:f2,tree/zeta:d1,tree/zeta/deep:d2,tree/zeta/deep/x.roc:f3"
want="$want tree/.git:d1,tree/.hidden.roc:f1,tree/a.txt:f1,tree/b.roc:f1,tree/link:l1,tree/src:d1,tree/zeta:d1"
want="$want tree/link:d1,tree/link/lib:d2,tree/link/main.roc:f2"
want="$want 9,2"
want="$want err:NotFound err:PermissionDenied"
want="$want tree/b.roc,tree/src/lib/util.roc,tree/src/main.roc,tree/zeta/deep/x.roc"
want="$want tree/src/main.roc tree/a.txt linked/a.txt,tree/a.txt none invalid CWD/tree/src/lib/data.json err:PermissionDenied"
want="$want linked/src/main.roc none cycle/abs:l1,cycle/f:f1,cycle/l1:l1"
want="$want fork/a:d1,fork/a/l1:d2,fork/a/l1/m1:l3,fork/a/l1/m2:l3,fork/a/l2:d2,fork/a/l2/m1:l3,fork/a/l2/m2:l3,fork/b:d1,fork/b/m1:d2,fork/b/m1/l1:l3,fork/b/m1/l2:l3,fork/b/m2:d2,fork/b/m2/l1:l3,fork/b/m2/l2:l3"
want="$want err:PermissionDenied CWD/tree/a.txt,tree/b.roc tree/a.txt invalid"
want="$want nowhere/file:f1,nowhere/l1:l1,nowhere/l2:l1,nowhere/through:l1 deferred/link:d1 1 tree/a.txt tree/a.txt ronly/f:f1,ronly/sub:d1 none none .,tree/.. tree/a.txt none ronly/f none lit/xonly/f err:PermissionDenied tree/link,tree/src,tree/zeta none invalid tree/a.txt err:PermissionDenied perm/lx/f perm/lx,perm/lz,perm/xdir,perm/zdir invalid p2/shut none none invalid invalid invalid long/toolong:l1 none none tree/a.txt none tree/link/main.roc,tree/src/main.roc tree/src/main.roc tree/link/lib/data.json,tree/src/lib/data.json pkg/vendorlink/deep/w.txt,pkg/vendorlink/deep/x.txt none pkg/vendorlink/w.txt none none none pkg/vendorlink/deep/w.txt,pkg/vendorlink/deep/x.txt,pkg/vendorlink/mid/deep/w.txt,pkg/vendorlink/w.txt pkg/vendorlink/w.txt shut/through/seen.txt err:PermissionDenied"
if [[ "$got" != "$want" ]]; then
	echo "FAIL: outcomes differ (walk shallow followed pruned missing locked glob** glob-literal glob-alt glob-pruned glob-nostart invalid absolute glob-locked glob-through-link max-depth-0 follow-cycle sibling-cycles follow-error mixed-alternatives doubled-slash brace-stars links-to-nowhere unlistable-at-max-depth unlistable-skipped dot-slash-duplicate dot-components unsearchable-dir file-in-start looped-start literal-starts empty-alternative empty-pattern literal-unsearchable literal-looped literal-unlistable-parent link-start-inner-error directories-only file-with-slash dotdot-after-wildcard loop-in-start-prefix refused-link-start literal-behind-unlistable-link directories-through-unlistable-links escaped-slash unresolvable-links-not-directories literal-link-to-file-slash literal-dangling-slash reversed-range slash-class slash-range-class walk-link-name-too-long glob-link-name-too-long glob-start-name-too-long glob-literal-name-too-long many-literal-alternatives wildcard-through-link globstar-not-through-link wildcard-through-link-deeper globstar-before-link globstar-cannot-take-link globstar-past-link-once-inside globstar-into-link unlistable-link-deeper unlistable-link globstar-below-a-matched-link globstar-between-links seen-below-link real-unreadable-below-link)"
	paste <(tr ' ' '\n' <<<"$want") <(tr ' ' '\n' <<<"$got") | awk -F'\t' '$1 != $2 { print "  want: " $1 "\n  got:  " $2 }'
	exit 1
fi
echo "ok: a walk is depth first and sorted, links and depth as asked; a glob searches only where it can match"
