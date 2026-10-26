app [main!] { pf: platform "../target/trantor/app/platform/main.roc" }

import pf.OsStr
import pf.Stdout
import pf.Path
import pf.Env
import pf.Walk
import pf.Glob
import pf.Temp
import pf.Tree

## README.md's examples, so they keep compiling and doing what it says. It runs
## in a temp directory (absolute, so its cleanup survives the cwd change) and
## builds its own `src` and `template` first.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	answer = Temp.with_dir!(|dir| {
		Env.set_cwd!(dir)?
		Path.create_all!(Path.utf8("src/cli"))?
		Path.write_utf8!(Path.utf8("src/main.roc"), "")?
		Path.write_utf8!(Path.utf8("src/cli/host.rs"), "")?
		Path.create_dir!(Path.utf8("template"))?
		Path.write_utf8!(Path.utf8("template/README"), "")?

		roc_files : U64
		roc_files = Walk.walk!(Path.utf8("src"), 0, {}, |n, entry|
			if entry.path.display().ends_with(".roc") { Continue(n + 1) } else { Continue(n) })?

		sources = Glob.expand!("src/**/*.{roc,rs}")?

		scratch = Temp.with_file!(|path, writer| {
			writer.line!("scratch")?
			path.read_utf8!()
		})?

		Tree.copy!(Path.utf8("template"), Path.utf8("new-project"), {})?
		copied = Path.exists!(Path.utf8("new-project/README"))?

		Ok("${Str.inspect(roc_files)} ${Str.join_with(sources.map(Path.display), ",")} ${Str.trim(scratch)} ${Str.inspect(copied)}")
	})?
	Stdout.line!(answer)
}
