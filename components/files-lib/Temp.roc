import IOErr exposing [IOErr]
import Path
import File
import Env
import Random
import Fs
import FsOps
import FilesPath
## Temporary files and directories with unguessable names.
##
## The `with_` functions delete what they created when the callback returns,
## `Ok` or `Err`; the `create_` functions leave deleting to the caller. A crash
## leaves the file behind. Each has an `_in` form taking the directory to create
## in; the others use `Env.temp_dir!()`, which honors `TMPDIR` — under
## `fs-confined`, point `TMPDIR` inside the root or pass a base (D-S2-7).
##
## Names are `trantor-` and 16 hex digits from the OS entropy source, created
## exclusively and retried on a collision, so another process cannot plant a
## file where one is about to be made. A file is created `0o600` and a
## directory `0o700`, as `mkstemp` and `mkdtemp` do, so what is staged through
## one is not readable by other users even in a shared `/tmp` (the umask can
## only take more bits away).
##
## A path is spelled under the base it was made in, so a relative base gives a
## relative path. A `with_` form deletes by the absolute path it made, so the
## callback may change the working directory, and may move or delete what it
## was given.
Temp :: [].{
	with_dir! : (Path.Path => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])) => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])
	with_dir! = |use!| Temp.with_dir_in!(Env.temp_dir!(), use!)

	with_dir_in! : Path.Path, (Path.Path => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])) => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])
	with_dir_in! = |base, use!| {
		dir = Temp.create_dir_in!(base)?
		made = FsOps.resolve!(FilesPath.bytes(dir))
		result = use!(dir)
		cleaned = FsOps.delete_all!(made).map_err(|DirErr(e)| PathErr(e))
		after_cleanup(result, cleaned)
	}

	## The callback gets the file's path and a writer on it, positioned at the
	## start.
	with_file! : (Path.Path, File.Writer => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])) => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])
	with_file! = |use!| Temp.with_file_in!(Env.temp_dir!(), use!)

	with_file_in! : Path.Path, (Path.Path, File.Writer => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])) => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])
	with_file_in! = |base, use!| {
		{ path, writer } = exclusive_file!(base, attempts)?
		made = FsOps.resolve!(FilesPath.bytes(path))
		result = use!(path, writer)
		cleaned = FsOps.delete!(made).map_err(|FileErr(e)| PathErr(e))
		after_cleanup(result, cleaned)
	}

	## A new empty directory the caller deletes.
	create_dir! : () => Try(Path.Path, [PathErr(IOErr), RandomErr(IOErr), ..])
	create_dir! = || Temp.create_dir_in!(Env.temp_dir!())

	create_dir_in! : Path.Path => Try(Path.Path, [PathErr(IOErr), RandomErr(IOErr), ..])
	create_dir_in! = |base| exclusive_dir!(base, attempts)

	## A new empty file the caller deletes.
	create_file! : () => Try(Path.Path, [PathErr(IOErr), RandomErr(IOErr), ..])
	create_file! = || Temp.create_file_in!(Env.temp_dir!())

	create_file_in! : Path.Path => Try(Path.Path, [PathErr(IOErr), RandomErr(IOErr), ..])
	create_file_in! = |base| Ok(exclusive_file!(base, attempts)?.path)
}

## How many names to try before reporting `AlreadyExists`. A collision of
## 64-bit random names is already a sign something is planting them.
attempts : U64
attempts = 8

## What `mkstemp` and `mkdtemp` create with: nobody else may read a temp.
owner_only_file : U32
owner_only_file = 0o600
owner_only_dir : U32
owner_only_dir = 0o700

name_prefix : Str
name_prefix = "trantor-"

hex_digits : U64
hex_digits = 16

## The callback's result, unless it succeeded and the cleanup did not. A temp
## already gone is not a failed cleanup: moving it into place, or deleting it,
## is what a callback does with it, and a successful rename used to come back
## as `NotFound`. The cleanup looks by absolute path, so `NotFound` cannot be a
## changed working directory.
after_cleanup : Try(a, [PathErr(IOErr), ..e]), Try({}, [PathErr(IOErr), ..e]) -> Try(a, [PathErr(IOErr), ..e])
after_cleanup = |result, cleaned| match (result, cleaned) {
	(Ok(_), Err(PathErr(NotFound))) => result
	(Ok(_), Err(PathErr(err))) => Err(PathErr(err))
	_ => result
}

fresh_name! : Path.Path => Try(Path.Path, [RandomErr(IOErr), ..])
fresh_name! = |base| {
	seed = Random.seed_u64!()?
	# Not `Path.join`, which concatenates: macOS sets TMPDIR with a trailing
	# slash, and every temp path came back with a doubled separator in it.
	Ok(FilesPath.from_bytes(FilesPath.child(FilesPath.bytes(base), Str.to_utf8("${name_prefix}${FilesPath.hex(seed, hex_digits)}"))))
}

exclusive_dir! : Path.Path, U64 => Try(Path.Path, [PathErr(IOErr), RandomErr(IOErr), ..])
exclusive_dir! = |base, left| {
	path = fresh_name!(base)?
	match FsOps.create_dir_mode!(FilesPath.bytes(path), owner_only_dir) {
		Ok({}) => Ok(path)
		Err(DirErr(AlreadyExists)) if left > 1 => exclusive_dir!(base, left - 1)
		Err(DirErr(err)) => Err(PathErr(err))
	}
}

exclusive_file! : Path.Path, U64 => Try({ path : Path.Path, writer : File.Writer }, [PathErr(IOErr), RandomErr(IOErr), ..])
exclusive_file! = |base, left| {
	path = fresh_name!(base)?
	match open_new!(path) {
		Ok(writer) => Ok({ path, writer })
		Err(Io(AlreadyExists)) if left > 1 => exclusive_file!(base, left - 1)
		Err(Io(err)) => Err(PathErr(err))
	}
}

## Created only if nothing is there, without following a planted link.
open_new! : Path.Path => Try(File.Writer, [Io(IOErr)])
open_new! = |path| {
	descriptor = Fs.open_at!(FsOps.root!(), FsOps.resolve!(FilesPath.bytes(path)), { read: False, write: True, exclusive: True, follow_symlinks: False, mode: owner_only_file })?
	match Fs.write_via_stream!(descriptor, 0) {
		Ok(stream) => Ok(File.Writer.from_host({ descriptor, stream }))
		Err(err) => {
			# Created but unusable: nobody else will delete it.
			_ = FsOps.delete!(FilesPath.bytes(path))
			Err(err)
		}
	}
}

