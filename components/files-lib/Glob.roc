import GlobPattern
import IOErr
import Path
import Walk
import FilesPath
import Fs
import FsOps
## Glob patterns: matching a path, and (with a filesystem) expanding one.
##
## The syntax is globset's: `*` within a component, `?` one character, `**` as
## a whole component for any depth, `[a-z]`/`[!a-z]` classes, `{a,b}`
## alternatives, `\` escapes. Wildcards do not match a leading `.` unless the
## pattern spells it.
Glob :: [].{
	## Whether `path` matches `pattern`. An invalid pattern matches nothing;
	## `GlobPattern.parse` says why it is invalid.
	##
	## ```roc
	## Glob.matches("src/**/*.roc", "src/cli/main.roc") # True
	## ```
	matches : Str, Str -> Bool
	matches = |pattern, path| match GlobPattern.parse(pattern) {
		Ok(p) => GlobPattern.matches(p, path)
		Err(InvalidGlob(_)) => False
	}

	## Every existing path the pattern matches, spelled without `.` components,
	## sorted by their bytes and without duplicates; `Ok([])` when
	## none does. The search starts at the pattern's literal leading directories
	## and skips any directory the pattern rules out. A relative pattern is
	## relative to the working directory, and so are the paths returned.
	## A wildcard searches through a link to a directory, as zsh does, so
	## `src/*/main.roc` finds one inside a linked `src/vendor`. `**` neither
	## matches a link nor reaches past one, wherever it sits in the pattern, and
	## a link back to a directory the search is already inside is matched but
	## not searched. A linked directory that cannot be listed is no match, where
	## a real one fails the expansion. A pattern ending in `/` matches links
	## that lead to directories.
	##
	## ```roc
	## sources = Glob.expand!("src/**/*.roc")?
	## ```
	expand! : Str => Try(List(Path.Path), [PathErr(IOErr), InvalidGlob(Str)])
	expand! = |text| match GlobPattern.parse(text) {
		Err(InvalidGlob(why)) => Err(InvalidGlob(why))
		Ok(pattern) => expand_parsed!(pattern, text)
	}
}

## Each group of alternatives searches from its own start, and the results are
## merged: overlapping starts (`src` and `src/lib`) can find a path twice.
expand_parsed! : GlobPattern.Pattern, Str => Try(List(Path.Path), [PathErr(IOErr)])
expand_parsed! = |pattern, _text| {
	# Spelled without `.` components, so `{*.txt,./a.txt,././a.txt}` finds
	# `a.txt` once. Literal alternatives no search reaches (`.`, `tree/..`, `/`)
	# are checked by name.
	walked = expand_starts!(GlobPattern.starts(pattern), [])?
	named = existing!(GlobPattern.unreachable_literals(pattern), [])?
	found = List.concat(walked, named).map(without_dot_components)
	sorted = List.sort_with(found, |a, b| compare_bytes(FilesPath.bytes(a), FilesPath.bytes(b)))
	Ok(List.fold(sorted, [], |acc, path| match List.last(acc) {
		Ok(previous) if FilesPath.bytes(previous) == FilesPath.bytes(path) => acc
		_ => List.append(acc, path)
	}))
}

expand_starts! : List({ prefix : Str, pattern : GlobPattern.Pattern }), List(Path.Path) => Try(List(Path.Path), [PathErr(IOErr)])
expand_starts! = |starts, found| match starts {
	[] => Ok(found)
	[start, .. as rest] =>
		match expand_from!(start.pattern, start.prefix) {
			Ok(paths) => expand_starts!(rest, List.concat(found, paths))
			# Literal names need no listing: a start that can be searched but not
			# listed (`xonly/f` with xonly mode 111) is checked name by name. Only
			# the walk's failure is set aside; the name check's own errors stand
			# (D-S2-34).
			Err(_) if GlobPattern.is_literal(start.pattern) =>
				expand_starts!(rest, List.concat(found, existing!(GlobPattern.literal_paths(start.pattern), [])?))
			Err(err) => Err(err)
		}
}

expand_from! : GlobPattern.Pattern, Str => Try(List(Path.Path), [PathErr(IOErr)])
expand_from! = |pattern, prefix| {
	root = Path.utf8(if Str.is_empty(prefix) { "." } else { prefix })
	# A start that is not there is no match; a directory vanishing mid-walk is an error.
	match Path.type!(root) {
		Ok(IsDir) => search!(pattern, prefix, root)
		# A link to nothing, through a file, around a loop, or to a name too long
		# to look up is no match. A
		# refused one fails, out of a confined root or not: trantor-files cannot
		# tell the two apart, and a refusal is not an absence (D-S2-37).
		Ok(IsSymLink) => match Path.list!(root) {
			Ok(_) => search!(pattern, prefix, root)
			Err(PathErr(NotFound)) | Err(PathErr(NotADirectory)) => Ok([])
			Err(PathErr(e)) => if FilesPath.leads_nowhere(e) { Ok([]) } else { Err(PathErr(e)) }
		}
		Ok(_) => Ok([])
		# `afile/x`, a missing directory, a loop of links on the way, or a name
		# too long to look up (D-S2-42).
		Err(PathErr(NotFound)) | Err(PathErr(NotADirectory)) => Ok([])
		Err(PathErr(e)) => if FilesPath.leads_nowhere(e) { Ok([]) } else { Err(PathErr(e)) }
	}
}

search! : GlobPattern.Pattern, Str, Path.Path => Try(List(Path.Path), [PathErr(IOErr)])
search! = |pattern, prefix, root|
	# Links are followed under a wildcard, as zsh does, so `src/*/main.roc`
	# looks inside a linked `src/vendor`; `**` may not take a link's own
	# component, though it may take the ones between links (D-S2-46). Cycles
	# end by identity (D-S2-25), and a link whose directory cannot be listed is
	# no match rather than an error.
	Walk.walk!(root, [], { follow_symlinks: True, skip_unreadable_links: True }, |acc, entry| {
		spelled = as_spelled(Path.display(entry.path), prefix)
		reach = reach_of(spelled, entry)
		matched = match GlobPattern.match_kind_within(pattern, spelled, reach) {
			Match => List.append(acc, as_returned(entry.path, prefix))
			# A trailing `/`: a directory, or a link to one (D-S2-33).
			IfDirectory => if is_directory!(entry.path, entry.kind) { List.append(acc, as_returned(entry.path, prefix)) } else { acc }
			NoMatch => acc
		}
		match entry.kind {
			IsDir => if GlobPattern.could_contain_within(pattern, spelled, reach) { Continue(matched) } else { SkipDir(matched) }
			_ => Continue(matched)
		}
	})

## Whether a walked or named entry is a directory, following a link. Opened
## as a directory, which only a directory can be. Listing it, as this used to,
## dropped links to directories that exist but cannot be listed.
##
## A refused open is a directory only if the link resolves: opening a file or
## nothing as a directory fails as that before any permission check, so a
## target that stats is a directory that cannot be read. One that does not
## resolve (behind an unsearchable directory, or out of a confined root) is
## not known to be a directory and does not match, as bash's `*/` does not
## (D-S2-38); counting every refusal matched links to files and to nothing.
is_directory! : Path.Path, [IsFile, IsDir, IsSymLink, IsOther] => Bool
is_directory! = |path, kind| match kind {
	IsDir => True
	IsSymLink => {
		resolved = FsOps.resolve!(FilesPath.bytes(path))
		match Fs.open_at!(FsOps.root!(), resolved, { directory: True }) {
			Ok(_) => True
			Err(Io(PermissionDenied)) => Fs.metadata_hash_at!(FsOps.root!(), resolved, { follow_symlinks: True }).is_ok()
			Err(Io(_)) => False
		}
	}
	_ => False
}

## Which components `**` may not take for this entry: the links on its path,
## as indices into the spelled path. The walk counts depth from its root, and
## the spelled path may carry the start's own components in front of it.
reach_of : Str, Walk.Entry -> GlobPattern.Reach
reach_of = |spelled, entry|
	if List.is_empty(entry.links) {
		Anywhere
	} else {
		base = List.len(Str.split_on(spelled, "/")) - entry.depth
		NotAt(entry.links.map(|depth| base + depth - 1))
	}

## A walk from `.` yields `./name`; the pattern spelled `name`.
as_spelled : Str, Str -> Str
as_spelled = |path, prefix|
	if Str.is_empty(prefix) and Str.starts_with(path, "./") {
		Str.drop_prefix(path, "./")
	} else {
		path
	}

## The path without the `./` the walk from `.` added, keeping its bytes.
as_returned : Path.Path, Str -> Path.Path
as_returned = |path, prefix| {
	bytes = FilesPath.bytes(path)
	dotted = Str.is_empty(prefix) and List.starts_with(bytes, ['.', '/'])
	FilesPath.from_bytes(if dotted { List.drop_first(bytes, 2) } else { bytes })
}

## `.` components removed, keeping a lone `.` and a leading `/`.
without_dot_components : Path.Path -> Path.Path
without_dot_components = |path| {
	bytes = FilesPath.bytes(path)
	kept = List.fold_with_index(List.split_on(bytes, '/'), [], |acc, part, index|
		if part == ['.'] or (index > 0 and part == []) { acc } else { acc.append(part) })
	joined = List.fold_with_index(kept, [], |acc, part, index| if index == 0 { part } else { List.concat(acc.append('/'), part) })
	FilesPath.from_bytes(if List.is_empty(kept) or kept == [[]] { if List.first(bytes) == Ok('/') { ['/'] } else { ['.'] } } else { joined })
}

## The named paths that exist, not following a final link unless a trailing
## `/` asks for a directory. Not there, through a file, or around a loop of
## links is no match; any other error, a confinement refusal or an I/O error,
## fails the expansion (D-S2-34).
existing! : List({ name : Str, directory_only : Bool }), List(Path.Path) => Try(List(Path.Path), [PathErr(IOErr)])
existing! = |names, found| match names {
	[] => Ok(found)
	[literal, .. as rest] => {
		path = Path.utf8(literal.name)
		match Path.type!(path) {
			Ok(kind) =>
				if !literal.directory_only or is_directory!(path, kind) {
					existing!(rest, List.append(found, path))
				} else {
					existing!(rest, found)
				}
			Err(PathErr(NotFound)) | Err(PathErr(NotADirectory)) => existing!(rest, found)
			Err(PathErr(e)) => if FilesPath.leads_nowhere(e) { existing!(rest, found) } else { Err(PathErr(e)) }
		}
	}
}

compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |a, b| match (a, b) {
	([], []) => Same
	([], _) => Before
	(_, []) => After
	([x, .. as xs], [y, .. as ys]) => if x < y { Before } else if x > y { After } else { compare_bytes(xs, ys) }
}

expect Glob.matches("src/**/*.roc", "src/cli/main.roc")
expect !Glob.matches("*.roc", ".hidden.roc")
expect !Glob.matches("[unclosed", "[unclosed")
