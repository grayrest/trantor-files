app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Path
import pf.Env
import pf.Walk
import pf.Glob
import pf.Tree

show : Try({}, _) -> Str
show = |r| match r {
	Ok({}) => "ok"
	Err(PathErr(e)) => "err:${Str.inspect(e)}"
	Err(_) => "err"
}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	first = show(Tree.copy!(Path.utf8("src"), Path.utf8("dst"), {}))
	again = show(Tree.copy!(Path.utf8("src"), Path.utf8("dst"), {}))
	Path.write_utf8!(Path.utf8("dst/a.txt"), "changed")?
	replaced = show(Tree.copy!(Path.utf8("src"), Path.utf8("dst"), { overwrite: True }))
	single = show(Tree.copy!(Path.utf8("src/a.txt"), Path.utf8("single.txt"), {}))
	missing = show(Tree.copy!(Path.utf8("no-such-dir"), Path.utf8("elsewhere"), {}))
	# A replacement link that cannot be made leaves the old one in place.
	kept = show(Tree.copy!(Path.utf8("ow-src"), Path.utf8("ow-dst"), { overwrite: True }))
	# A name near the filesystem's 255-byte limit can still be replaced.
	long = Path.utf8(Str.repeat("x", 240))
	long_first = show(Tree.copy!(Path.utf8("src/a.txt"), long, {}))
	long_again = show(Tree.copy!(Path.utf8("src/a.txt"), long, { overwrite: True }))
	# From "." (the working directory), entry names are kept whole. An empty
	# path names nothing (D-S2-58), so copying from "" is NotFound.
	Path.create_dir!(Path.utf8("from-cwd"))?
	Path.write_utf8!(Path.utf8("from-cwd/ab"), "x")?
	Env.set_cwd!(Path.utf8("from-cwd"))?
	cwd_copy = "${show(Tree.copy!(Path.utf8("."), Path.utf8("../cwd-copy"), {}))},${show(Tree.copy!(Path.utf8(""), Path.utf8("../empty-copy"), {}))}"
	Env.set_cwd!(Path.utf8(".."))?
	# A followed link out of the root: a directory unconfined, the link itself
	# under fs-confined, not a failed walk (D-S2-30).
	escape = match Walk.list!(Path.utf8("escape"), { follow_symlinks: True, max_depth: 1 }) {
		Ok([entry]) => match entry.kind {
			IsDir => "dir"
			IsSymLink => "link"
			_ => "other"
		}
		Ok(_) => "count"
		Err(PathErr(e)) => "err:${Str.inspect(e)}"
	}
	# Out of the root by `..`, literal or wildcard, or through a start link:
	# refused alike under fs-confined (D-S2-34, D-S2-37).
	glob! = |pattern| match Glob.expand!(pattern) {
		Ok([]) => "none"
		Ok(ps) => Str.join_with(ps.map(Path.display), "+")
		Err(PathErr(e)) => "err:${Str.inspect(e)}"
		Err(_) => "invalid"
	}
	escapes = "${glob!("../outside/f")},${glob!("../outside/*")},${glob!("outlink/*")}"
	Stdout.line!("${first} ${again} ${replaced} ${single} ${missing} ${kept} ${long_first},${long_again} ${cwd_copy} ${escape} ${escapes}")
}
