import IOErr exposing [IOErr]
import Path
import Walk
import FilesPath
import FsOps
import Random
## Whole directory trees.
Tree :: [].{
	## Copy `from` to `to`: directories and files with their permission bits,
	## and symlinks as links holding the same target. A new directory's owner
	## always gets read, write and search; setuid, setgid and sticky are
	## dropped. Timestamps are not copied, and a socket or FIFO in the tree is
	## `Unsupported`. A file `from` is copied as one file.
	##
	## Anything already at a destination is `AlreadyExists`, unless
	## `overwrite: True`: then an existing file or link is replaced, only once
	## its replacement has been made, and an existing directory is copied into
	## as it is. A link where a directory would be copied is `AlreadyExists`
	## even then, so nothing is written through it.
	##
	## A copy that fails part way leaves what it had made: delete the
	## destination, or copy again with `overwrite: True`. Nothing is removed for
	## you, since a destination directory may have been there before.
	##
	## Links are made after everything else, and a link to another link after
	## that one, so each finds its target there, which `fs-confined` requires
	## of every link it creates.
	copy! : Path.Path, Path.Path, { overwrite ?: Bool } => Try({}, [PathErr(IOErr)])
	copy! = |from, to, opts| {
		overwrite = opts.?overwrite ?? False
		match Path.type!(from)? {
			IsDir => copy_dir!(from, to, overwrite)
			IsFile => copy_file!(from, to, overwrite)
			IsSymLink => copy_link!(from, to, overwrite)
			IsOther => Err(PathErr(Unsupported))
		}
	}
}

copy_dir! : Path.Path, Path.Path, Bool => Try({}, [PathErr(IOErr)])
copy_dir! = |from, to, overwrite| {
	entries = Walk.list!(from, {})?
	make_dir!(from, to, overwrite)?
	spots = { from: FilesPath.bytes(from), to: FilesPath.bytes(to) }
	links = copy_entries!(entries, spots, overwrite, [])?
	copy_links!(links, spots, overwrite)
}

Spots : { from : List(U8), to : List(U8) }

destination : Spots, Walk.Entry -> Path.Path
destination = |spots, entry| FilesPath.from_bytes(FilesPath.child(spots.to, relative(spots.from, FilesPath.bytes(entry.path))))

## Directories and files in walk order, so a parent exists before its
## children; the links are handed back for afterwards.
copy_entries! : List(Walk.Entry), Spots, Bool, List(Walk.Entry) => Try(List(Walk.Entry), [PathErr(IOErr)])
copy_entries! = |entries, spots, overwrite, links| match entries {
	[] => Ok(links)
	[entry, .. as rest] =>
		match entry.kind {
			IsDir => {
				make_dir!(entry.path, destination(spots, entry), overwrite)?
				copy_entries!(rest, spots, overwrite, links)
			}
			IsFile => {
				copy_file!(entry.path, destination(spots, entry), overwrite)?
				copy_entries!(rest, spots, overwrite, links)
			}
			IsSymLink => copy_entries!(rest, spots, overwrite, List.append(links, entry))
			IsOther => Err(PathErr(Unsupported))
		}
}

## Links in rounds: under `fs-confined` a link whose target is another link,
## or lies through one, is refused until that link exists. Each round makes
## what it can and retries the refusals; a round that makes nothing answers
## `NotFound`, which is also the answer for a target that never exists.
copy_links! : List(Walk.Entry), Spots, Bool => Try({}, [PathErr(IOErr)])
copy_links! = |links, spots, overwrite| {
	waiting = link_round!(links, spots, overwrite, [])?
	if List.is_empty(waiting) {
		Ok({})
	} else if List.len(waiting) < List.len(links) {
		copy_links!(waiting, spots, overwrite)
	} else {
		Err(PathErr(NotFound))
	}
}

## The links a round could not make yet because their target was missing.
link_round! : List(Walk.Entry), Spots, Bool, List(Walk.Entry) => Try(List(Walk.Entry), [PathErr(IOErr)])
link_round! = |links, spots, overwrite, waiting| match links {
	[] => Ok(waiting)
	[entry, .. as rest] =>
		match copy_link!(entry.path, destination(spots, entry), overwrite) {
			Ok({}) => link_round!(rest, spots, overwrite, waiting)
			Err(PathErr(NotFound)) => link_round!(rest, spots, overwrite, List.append(waiting, entry))
			Err(err) => Err(err)
		}
}

## The part of `path` below `root`, which `path` is spelled under.
relative : List(U8), List(U8) -> List(U8)
relative = |root, path| {
	# A root ending in `/` already separates it from its entries. (An empty
	# root cannot reach here: it is NotFound before the walk, D-S2-58.)
	separator = if List.last(root) == Ok('/') { 0 } else { 1 }
	List.drop_first(path, List.len(root) + separator)
}

## A new directory with `from`'s permission bits (D-S2-39).
make_dir! : Path.Path, Path.Path, Bool => Try({}, [PathErr(IOErr)])
make_dir! = |from, path, overwrite| match FsOps.copy_dir!(FilesPath.bytes(from), FilesPath.bytes(path)) {
	Ok({}) => Ok({})
	Err(DirErr(AlreadyExists)) if overwrite => if Path.is_dir!(path)? { Ok({}) } else { Err(PathErr(AlreadyExists)) }
	Err(DirErr(err)) => Err(PathErr(err))
}

copy_file! : Path.Path, Path.Path, Bool => Try({}, [PathErr(IOErr)])
copy_file! = |from, to, overwrite|
	if overwrite {
		replace!(to, |fresh| Path.copy!(from, fresh))
	} else {
		Path.copy!(from, to)
	}

copy_link! : Path.Path, Path.Path, Bool => Try({}, [PathErr(IOErr)])
copy_link! = |from, to, overwrite| {
	target = Path.read_sym_link!(from)?
	if overwrite {
		replace!(to, |fresh| Path.sym_link!(target, fresh))
	} else {
		Path.sym_link!(target, to)
	}
}

## Make the new entry beside `to` under a temporary name, then rename it over,
## so an old file or link is replaced only once its replacement exists: a copy
## or link that fails leaves the destination as it was, and its partial
## temporary is removed. A directory at `to` stays, and the rename onto it
## fails. The name is `.copy-in-progress-` and 16 hex digits, the same length
## whatever `to` is called, so a name near the filesystem's limit can still be
## replaced; a taken name is retried (D-S2-28).
replace! : Path.Path, (Path.Path => Try({}, [PathErr(IOErr), ..e])) => Try({}, [PathErr(IOErr), ..e])
replace! = |to, make!| replace_attempt!(to, make!, replace_attempts)

replace_attempts : U64
replace_attempts = 8

in_progress_prefix : Str
in_progress_prefix = ".copy-in-progress-"

replace_attempt! : Path.Path, (Path.Path => Try({}, [PathErr(IOErr), ..e])), U64 => Try({}, [PathErr(IOErr), ..e])
replace_attempt! = |to, make!, left| {
	seed = Random.seed_u64!().map_err(|RandomErr(e)| PathErr(e))?
	name = Str.to_utf8("${in_progress_prefix}${FilesPath.hex(seed, 16)}")
	fresh = FilesPath.from_bytes(FilesPath.child(FilesPath.parent(FilesPath.bytes(to)), name))
	match make!(fresh) {
		# Someone else's file: not ours to delete, so try another name.
		Err(PathErr(AlreadyExists)) => if left > 1 { replace_attempt!(to, make!, left - 1) } else { Err(PathErr(AlreadyExists)) }
		Err(err) => {
			_ = Path.delete!(fresh)
			Err(err)
		}
		Ok({}) => match Path.rename!(fresh, to) {
			Ok({}) => Ok({})
			Err(err) => {
				_ = Path.delete!(fresh)
				Err(err)
			}
		}
	}
}

expect relative(Str.to_utf8("src"), Str.to_utf8("src/a/b")) == Str.to_utf8("a/b")
expect relative(Str.to_utf8("/"), Str.to_utf8("/etc")) == Str.to_utf8("etc")
