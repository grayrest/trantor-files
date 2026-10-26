import IOErr
import Path
import FsOps
import FilesPath
import Fs
## Recursive directory traversal.
Walk :: [].{
	## One thing found under the walked directory. `depth` is 1 for its direct
	## children.
	## `link` is whether the name itself is a symlink, which `kind` no longer
	## says once a followed link reports as `IsDir`. `links` is the depth of
	## every symlink on this entry's path, the entry itself included, so a
	## caller can tell which components were links rather than only whether
	## one was.
	Entry : { path : Path.Path, kind : [IsFile, IsDir, IsSymLink, IsOther], depth : U64, link : Bool, links : List(U64) }

	## Visit everything under `root`, depth first, names sorted within each
	## directory, threading `state` through `visit!`. `visit!` answers
	## `Continue` to go on, `SkipDir` to not descend into this entry, or `Stop`
	## to end the walk; the walk returns the last state. `root` itself is not
	## visited.
	##
	## Symlinks are not followed by default. With `follow_symlinks: True`, a link
	## to a directory is reported as `IsDir` and descended into, unless it leads
	## back to a directory the walk is already inside: that link is `IsSymLink`
	## and not descended, so cycles end. With `skip_unreadable_links: True` a
	## link whose directory cannot be listed is visited and its contents
	## skipped, instead of failing the walk; a real directory that cannot be
	## listed still fails it, wherever it sits. A link that leads nowhere (missing,
	## through a file, a loop of links, a name too long to look up, out of a
	## confined root) or to a file is `IsSymLink`. `max_depth: 1` visits only direct children. An unreadable
	## directory, followed or not, fails the walk.
	##
	## ```roc
	## count = Walk.walk!(Path.utf8("src"), 0, {}, |n, entry|
	##     match entry.kind {
	##         IsFile => Continue(n + 1)
	##         _ => Continue(n)
	##     })?
	## ```
	walk! : Path.Path, state, { follow_symlinks ?: Bool, max_depth ?: U64, skip_unreadable_links ?: Bool }, (state, Entry => [Continue(state), SkipDir(state), Stop(state)]) => Try(state, [PathErr(IOErr)])
	walk! = |root, state, opts, visit!| {
		config = { follow: opts.?follow_symlinks ?? False, max_depth: opts.?max_depth ?? U64.highest, skip_unreadable_links: opts.?skip_unreadable_links ?? False }
		# `max_depth: 0` visits nothing, not the direct children.
		if config.max_depth == 0 {
			Ok(state)
		} else {
			bytes = FilesPath.bytes(root)
			inside = if config.follow { [identity!(bytes, True).map_err(|e| PathErr(e))?] } else { [] }
			match walk_dir!(bytes, 1, inside, [], state, config, visit!) {
				Ok(Continue(s)) => Ok(s)
				Ok(Stop(s)) => Ok(s)
				Err(e) => Err(PathErr(e))
			}
		}
	}

	## Everything `walk!` would visit, in that order.
	list! : Path.Path, { follow_symlinks ?: Bool, max_depth ?: U64, skip_unreadable_links ?: Bool } => Try(List(Entry), [PathErr(IOErr)])
	list! = |root, opts| Walk.walk!(root, [], opts, |acc, entry| Continue(List.append(acc, entry)))
}

Config : { follow : Bool, max_depth : U64, skip_unreadable_links : Bool }

Identity : { lower : U64, upper : U64 }

## The directories the walk is inside, by identity, when following links.
Inside : List(Identity)

identity! : List(U8), Bool => Try(Identity, IOErr)
identity! = |bytes, follow| Fs.metadata_hash_at!(FsOps.root!(), FsOps.resolve!(bytes), { follow_symlinks: follow }).map_err(|Io(e)| e)

walk_dir! : List(U8), U64, Inside, List(U64), state, Config, (state, Walk.Entry => [Continue(state), SkipDir(state), Stop(state)]) => Try([Continue(state), Stop(state)], IOErr)
walk_dir! = |dir, depth, inside, links, state, config, visit!| {
	entries = FsOps.entries!(dir).map_err(|DirErr(e)| e)?
	walk_entries!(dir, entries, depth, inside, links, state, config, visit!)
}

walk_entries! : List(U8), List(FsOps.Entry), U64, Inside, List(U64), state, Config, (state, Walk.Entry => [Continue(state), SkipDir(state), Stop(state)]) => Try([Continue(state), Stop(state)], IOErr)
walk_entries! = |dir, entries, depth, inside, links, state, config, visit!| match entries {
	[] => Ok(Continue(state))
	[entry, .. as rest] => {
		bytes = FilesPath.child(dir, entry.name)
		is_link = entry.kind == SymLink
		# Every link on this path, by depth: a caller matching `**` may not
		# take these components, and may take the ones between them.
		here_links = if is_link { List.append(links, depth) } else { links }
		descent = descent!(bytes, entry.kind, inside, config)?
		kind = match (entry.kind, descent) {
			(File, _) => IsFile
			(Other, _) => IsOther
			(Dir, _) => IsDir
			(SymLink, Descend(_)) => IsDir
			(SymLink, Stay) => IsSymLink
		}
		match visit!(state, { path: FilesPath.from_bytes(bytes), kind, depth, link: is_link, links: here_links }) {
			Stop(s) => Ok(Stop(s))
			SkipDir(s) => walk_entries!(dir, rest, depth, inside, links, s, config, visit!)
			Continue(s) =>
				match descent {
					Descend(below) if depth < config.max_depth => {
						# A real directory's identity is read here, as the walk goes in,
						# so one it will not enter is never stat'ed.
						id = match below.id {
							Known(known) => known
							Unread => identity!(bytes, False)?
						}
						if config.follow and List.contains(inside, id) {
							# Reached back through a followed link: already open above.
							walk_entries!(dir, rest, depth, inside, links, s, config, visit!)
						} else {
							# A link whose target cannot be listed is skipped
							# rather than failing the walk, when asked: to a
							# search it is a candidate, not a place it must go.
							# Only the link itself — a real directory below one
							# is a real directory (D-S2-49).
							skippable = config.skip_unreadable_links and is_link
							match listing!(bytes, skippable) {
								Err(e) => Err(e)
								Ok(listing) =>
									match walk_entries!(bytes, listing, depth + 1, List.append(inside, id), here_links, s, config, visit!)? {
										Stop(done) => Ok(Stop(done))
										Continue(next) => walk_entries!(dir, rest, depth, inside, links, next, config, visit!)
									}
							}
						}
					}
					_ => walk_entries!(dir, rest, depth, inside, links, s, config, visit!)
				}
		}
	}
}

## A directory's entries, or none when a refused listing is to be skipped.
## Only a refusal: EIO or ESTALE fails the walk as it does anywhere else, and
## turning one into an empty directory would lose it.
listing! : List(U8), Bool => Try(List(FsOps.Entry), IOErr)
listing! = |bytes, skippable| match FsOps.entries!(bytes) {
	Ok(entries) => Ok(entries)
	Err(DirErr(PermissionDenied)) if skippable => Ok([])
	Err(DirErr(e)) => Err(e)
}

Below : { id : [Known(Identity), Unread] }

## Whether to go below an entry. A real directory always can; its identity is
## read only when following links, and only as the walk goes in. A followed
## link descends when it leads to a directory the walk is not already inside
## (D-S2-25). A link that leads nowhere or to a file stays; a directory it
## leads to that cannot be listed fails the walk when entered, as a real one
## does, unless `skip_unreadable_links` is set.
descent! : List(U8), [File, Dir, SymLink, Other], Inside, Config => Try([Descend(Below), Stay], IOErr)
descent! = |bytes, kind, inside, config| match kind {
	Dir =>
		if config.follow {
			Ok(Descend({ id: Unread }))
		} else {
			Ok(Descend({ id: Known({ lower: 0, upper: 0 }) }))
		}
	SymLink if config.follow =>
		match identity!(bytes, True) {
			# Leads nowhere: missing, through a file, around a loop of links
			# (ELOOP, which IOErr only names as Other), or out of a confined root
			# or through a directory that cannot be searched (PermissionDenied,
			# which cap-std gives an escape). Reported as the link (D-S2-30).
			Err(NotFound) | Err(NotADirectory) | Err(PermissionDenied) => Ok(Stay)
			# A loop or a target name too long to look up leads nowhere too. Any
			# other failure (EIO, ESTALE) fails the walk; it used to skip the
			# subtree as a link to nowhere.
			Err(e) => if FilesPath.leads_nowhere(e) { Ok(Stay) } else { Err(e) }
			Ok(id) =>
				if List.contains(inside, id) {
					Ok(Stay)
				} else {
					# A stat, not a listing: reading every linked directory here
					# cost a `max_depth: 1` walk over 200 links to 20,000-entry
					# directories 3.0s instead of 0.19s, and `SkipDir` could not
					# avoid it either. A directory that cannot be listed still
					# descends, and fails the walk only when it is entered.
					match Fs.stat_at!(FsOps.root!(), FsOps.resolve!(bytes), { follow_symlinks: True }) {
						Ok({ kind: Dir, .. }) => Ok(Descend({ id: Known(id) }))
						Ok(_) => Ok(Stay)
						Err(Io(NotADirectory)) => Ok(Stay)
						Err(Io(_)) => Ok(Descend({ id: Known(id) }))
					}
				}
		}
	_ => Ok(Stay)
}
