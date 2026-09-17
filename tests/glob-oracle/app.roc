app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr exposing [OsStr]
import pf.Stdout
import pf.Glob
import pf.Path

## One line per match: the pattern, a tab, and the path — so a name holding a
## space still compares cleanly. A pattern with no match prints one line with
## an empty path.
main! : List(OsStr) => Try({}, _)
main! = |args| Stdout.line!(Str.join_with(expanded!(List.drop_first(args, 1)), "\n"))

expanded! : List(OsStr) => List(Str)
expanded! = |patterns| match patterns {
	[] => []
	[one, .. as rest] => {
		text = OsStr.display(one)
		lines = match Glob.expand!(text) {
			Ok([]) => ["${text}\t"]
			Ok(paths) => paths.map(|path| "${text}\t${Path.display(path)}")
			Err(e) => ["${text}\terr:${Str.inspect(e)}"]
		}
		List.concat(lines, expanded!(rest))
	}
}
