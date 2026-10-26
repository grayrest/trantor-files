app [main!] { pf: platform "../target/trantor/myapp/platform/main.roc" }

import pf.OsStr
import pf.Stdout
import pf.Path
import pf.File
import pf.Temp
import pf.Env

## `trantor-` and 16 lowercase hex digits.
well_named : Path.Path -> Bool
well_named = |path| {
	name = Path.display(path).split_on("/").last() ?? ""
	digits = Str.drop_prefix(name, "trantor-")
	Str.starts_with(name, "trantor-") and Str.count_utf8_bytes(digits) == 16 and List.all(Str.to_utf8(digits), |c| (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))
}

gone! : Path.Path => Str
gone! = |path| match Path.exists!(path) {
	Ok(False) => "gone"
	Ok(True) => "LEFT"
	Err(_) => "err"
}

## Used and deleted, with the name the docs promise, under TMPDIR.
dir_ok! : () => Try(Str, _)
dir_ok! = || {
	seen = Temp.with_dir!(|dir| {
		Path.write_utf8!(Path.join(dir, "inner.txt"), "x")?
		Ok(dir)
	})?
	under = Str.contains(Path.display(seen), "/tmpbase/")
	Ok("${Str.inspect(well_named(seen))},${Str.inspect(under)},${gone!(seen)}")
}

## An Err from the callback still deletes, and is what comes back.
dir_err! : () => Str
dir_err! = || match Temp.with_dir!(|dir| Err(Refused(dir))) {
	Err(Refused(dir)) => "refused,${gone!(dir)}"
	_ => "other"
}

## The writer writes the file the path names.
file_ok! : () => Try(Str, _)
file_ok! = || {
	(content, seen) = Temp.with_file!(|path, writer| {
		writer.write_utf8!("written")?
		Ok((Path.read_utf8!(path)?, path))
	})?
	Ok("${content},${Str.inspect(well_named(seen))},${gone!(seen)}")
}

## The create_ forms leave their result; two names differ.
created! : () => Try(Str, _)
created! = || {
	dir = Temp.create_dir!()?
	a = Temp.create_file!()?
	b = Temp.create_file!()?
	kinds = "${Str.inspect(Path.is_dir!(dir)?)},${Str.inspect(Path.is_file!(a)?)}"
	Ok("${kinds},${Str.inspect(a != b)},${Path.display(dir).split_on("/").last() ?? ""},${Path.display(a).split_on("/").last() ?? ""}")
}

## The _in forms create under the base given, relative or not.
in_base! : () => Try(Str, _)
in_base! = || {
	inside = Temp.with_file_in!(Path.utf8("base"), |path, _| Ok(Path.display(path)))?
	nested = Temp.with_dir_in!(Path.utf8("base"), |dir| Ok(Path.display(Temp.create_file_in!(dir)?)))?
	Ok("${Str.inspect(Str.starts_with(inside, "base/trantor-"))},${Str.inspect(Str.starts_with(nested, "base/trantor-"))}")
}

## A callback that moves its temp file into place, or deletes its directory,
## succeeds: the temp being gone is not a failed cleanup.
moved! : () => Try(Str, _)
moved! = || {
	file = Temp.with_file_in!(Path.utf8("base"), |path, writer| {
		writer.write_utf8!("data")?
		Path.rename!(path, Path.utf8("final.txt"))?
		Ok("moved")
	})?
	dir = Temp.with_dir_in!(Path.utf8("base"), |d| {
		Path.delete_all!(d)?
		Ok("deleted")
	})?
	Ok("${file},${Path.read_utf8!(Path.utf8("final.txt"))?},${dir}")
}

## A callback that changes the working directory still has its temp deleted:
## the cleanup uses the absolute path it made.
moved_cwd! : () => Try(Str, _)
moved_cwd! = || {
	start = Env.cwd!()?
	made = Temp.with_dir_in!(Path.utf8("base"), |d| {
		Env.set_cwd!(Path.utf8("base"))?
		Ok(d)
	})?
	Env.set_cwd!(start)?
	Ok("cwd-${gone!(made)}")
}

missing_base! : () => Str
missing_base! = || match Temp.create_file_in!(Path.utf8("no-such-base")) {
	Ok(_) => "created"
	Err(PathErr(NotFound)) => "notfound"
	Err(_) => "other"
}

show : Try(Str, _) -> Str
show = |r| match r {
	Ok(s) => s
	Err(e) => "err:${Str.inspect(e)}"
}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	cases = [show(dir_ok!()), dir_err!(), show(file_ok!()), show(created!()), show(in_base!()), missing_base!(), show(moved!()), show(moved_cwd!())]
	Stdout.line!(Str.join_with(cases, " "))
}
