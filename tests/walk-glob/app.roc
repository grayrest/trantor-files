app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr
import pf.Stdout
import pf.Env
import pf.Path
import pf.Walk
import pf.Glob

kind : [IsFile, IsDir, IsSymLink, IsOther] -> Str
kind = |k| match k {
	IsFile => "f"
	IsDir => "d"
	IsSymLink => "l"
	IsOther => "o"
}

entries : List(Walk.Entry) -> Str
entries = |list| Str.join_with(list.map(|e| "${Path.display(e.path)}:${kind(e.kind)}${e.depth.to_str()}"), ",")

paths : List(Path.Path) -> Str
paths = |list| Str.join_with(list.map(Path.display), ",")

show : Try(Str, _) -> Str
show = |r| match r {
	Ok(s) => if Str.is_empty(s) { "none" } else { s }
	Err(PathErr(e)) => "err:${Str.inspect(e)}"
	Err(InvalidGlob(_)) => "invalid"
	Err(_) => "err"
}

## Depth first, sorted within a directory, links not followed.
full! : () => Try(Str, _)
full! = || Ok(entries(Walk.list!(Path.utf8("tree"), {})?))

shallow! : () => Try(Str, _)
shallow! = || Ok(entries(Walk.list!(Path.utf8("tree"), { max_depth: 1 })?))

## A followed link to a directory is a directory, and is descended into.
followed! : () => Try(Str, _)
followed! = || Ok(entries(Walk.list!(Path.utf8("tree"), { follow_symlinks: True, max_depth: 2 })?.keep_if(|e| Str.contains(Path.display(e.path), "link"))))

## SkipDir prunes one directory; Stop ends the walk with its state.
pruned! : () => Try(Str, _)
pruned! = || {
	skipped = Walk.walk!(Path.utf8("tree"), [], {}, |acc, e|
		if Path.display(e.path) == "tree/src" { SkipDir(acc) } else { Continue(List.append(acc, e)) })?
	start : U64
	start = 0
	stopped = Walk.walk!(Path.utf8("tree"), start, {}, |n, e|
		if Str.ends_with(Path.display(e.path), ".roc") { Stop(n + 1) } else { Continue(n + 1) })?
	Ok("${Str.inspect(List.len(skipped))},${stopped.to_str()}")
}

## SkipDir for every entry: how many were visited.
skip_all! : Path.Path => Try(Str, _)
skip_all! = |root| {
	start : U64
	start = 0
	Ok(Walk.walk!(root, start, { follow_symlinks: True }, |n, _| SkipDir(n + 1))?.to_str())
}

## `{a,b}` `n` times over: 2^n literal alternatives, each its own start group.
## Grouping them was quadratic — 15 of them took 87 seconds.
braces : U64, Str -> Str
braces = |n, acc| if n == 0 { acc } else { braces(n - 1, "${acc}{a,b}") }

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	cwd = Path.display(Env.cwd!() ?? Path.utf8("."))
	cases = [
		show(full!()),
		show(shallow!()),
		show(followed!()),
		show(pruned!()),
		show(Walk.list!(Path.utf8("missing"), {}).map_ok(entries)),
		show(Walk.list!(Path.utf8("locked"), {}).map_ok(entries)),
		show(Glob.expand!("tree/**/*.roc").map_ok(paths)),
		show(Glob.expand!("tree/src/*.roc").map_ok(paths)),
		show(Glob.expand!("tree/*.{txt,json}").map_ok(paths)),
		show(Glob.expand!("*/a.txt").map_ok(paths)),
		show(Glob.expand!("nope/*.x").map_ok(paths)),
		show(Glob.expand!("[bad").map_ok(paths)),
		show(Glob.expand!("${cwd}/tree/src/lib/*.json").map_ok(|ps| paths(ps).replace_each(cwd, "CWD"))),
		show(Glob.expand!("**/*.json").map_ok(paths)),
		show(Glob.expand!("linked/src/*.roc").map_ok(paths)),
		show(Walk.list!(Path.utf8("tree"), { max_depth: 0 }).map_ok(entries)),
		show(Walk.list!(Path.utf8("cycle"), { follow_symlinks: True }).map_ok(entries)),
		show(Walk.list!(Path.utf8("fork"), { follow_symlinks: True }).map_ok(entries)),
		show(Walk.list!(Path.utf8("followerr"), { follow_symlinks: True }).map_ok(entries)),
		show(Glob.expand!("{${cwd}/tree/a.txt,tree/b.roc}").map_ok(|ps| paths(ps).replace_each(cwd, "CWD"))),
		show(Glob.expand!("tree//a.txt").map_ok(paths)),
		show(Glob.expand!("**/*{*,x}").map_ok(paths)),
		show(Walk.list!(Path.utf8("nowhere"), { follow_symlinks: True }).map_ok(entries)),
		show(Walk.list!(Path.utf8("deferred"), { follow_symlinks: True, max_depth: 1 }).map_ok(entries)),
		show(skip_all!(Path.utf8("deferred"))),
		show(Glob.expand!("{tree/*.txt,./tree/a.txt}").map_ok(paths)),
		show(Glob.expand!("{tree/a.txt,././tree/a.txt,tree/./a.txt}").map_ok(paths)),
		show(Walk.list!(Path.utf8("ronly"), { follow_symlinks: True, max_depth: 1 }).map_ok(entries)),
		show(Glob.expand!("tree/a.txt/x/*.txt").map_ok(paths)),
		show(Glob.expand!("looped/*").map_ok(paths)),
		show(Glob.expand!("{.,tree/..}").map_ok(paths)),
		show(Glob.expand!("{tree/a.txt,}").map_ok(paths)),
		show(Glob.expand!("").map_ok(paths)),
		show(Glob.expand!("ronly/f").map_ok(paths)),
		show(Glob.expand!("looped/x").map_ok(paths)),
		show(Glob.expand!("lit/xonly/f").map_ok(paths)),
		show(Glob.expand!("lerr/**/*.json").map_ok(paths)),
		show(Glob.expand!("tree/*/").map_ok(paths)),
		show(Glob.expand!("tree/a.txt/").map_ok(paths)),
		show(Glob.expand!("tree/*/../a.txt").map_ok(paths)),
		show(Glob.expand!("{looped/sub/*.txt,tree/a.txt}").map_ok(paths)),
		show(Glob.expand!("perm/lz/*").map_ok(paths)),
		show(Glob.expand!("perm/lx/f").map_ok(paths)),
		show(Glob.expand!("perm/*/").map_ok(paths)),
		show(Glob.expand!("x\\/y").map_ok(paths)),
		show(Glob.expand!("p2/*/").map_ok(paths)),
		show(Glob.expand!("p2/lfile/").map_ok(paths)),
		show(Glob.expand!("p2/ldang/").map_ok(paths)),
		show(Glob.expand!("tree/[z-a]*").map_ok(paths)),
		show(Glob.expand!("tree[/]a.txt").map_ok(paths)),
		show(Glob.expand!("tree[/-/]a.txt").map_ok(paths)),
		show(Walk.list!(Path.utf8("long"), { follow_symlinks: True }).map_ok(entries)),
		show(Glob.expand!("long/toolong/*").map_ok(paths)),
		show(Glob.expand!("${Str.repeat("a", 300)}/*").map_ok(paths)),
		show(Glob.expand!("{${Str.repeat("a", 300)},tree/a.txt}").map_ok(paths)),
		show(Glob.expand!(braces(17, "")).map_ok(paths)),
		# A wildcard searches through a link to a directory; `**` does not.
		show(Glob.expand!("tree/*/main.roc").map_ok(paths)),
		show(Glob.expand!("tree/**/main.roc").map_ok(paths)),
		show(Glob.expand!("tree/*/lib/*.json").map_ok(paths)),
		# `**` before the link still reaches the link's own directory, and
		# never past it; an unlistable linked directory is no match.
		show(Glob.expand!("pkg/**/vendorlink/deep/*.txt").map_ok(paths)),
		show(Glob.expand!("pkg/**/deep/*.txt").map_ok(paths)),
		show(Glob.expand!("pkg/**/*/w.txt").map_ok(paths)),
		show(Glob.expand!("pkg/**/w.txt").map_ok(paths)),
		show(Glob.expand!("lp/*/*.txt").map_ok(paths)),
		show(Glob.expand!("lp/**/*.txt").map_ok(paths)),
		# What a wildcard matched, `**` may search below; a real directory that
		# cannot be listed still fails, link above it or not.
		show(Glob.expand!("pkg/*/**/*.txt").map_ok(paths)),
		show(Glob.expand!("pkg/**/*/*.txt").map_ok(paths)),
		show(Glob.expand!("shut/*/*.txt").map_ok(paths)),
		show(Glob.expand!("shut/*/*/*.txt").map_ok(paths)),
	]
	Stdout.line!(Str.join_with(cases, " "))
}
