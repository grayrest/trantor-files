# trantor-files

Walking directories, expanding globs, temporary files and copying trees, for
[trantor-cli](../trantor-cli) apps.

```toml
# world.toml
[deps]
trantor-cli = { path = "../trantor-cli" }
trantor-files = { path = "../trantor-files" }
```

Everything here is Roc over trantor-cli's filesystem primitives, with no host
code, so it is confined wherever trantor-cli's `fs-confined` is wired. Single
operations — append, copy one file, symlinks — are methods on trantor-cli's
`Path` instead. Functions take basic-cli's `Path`.

In the signatures below, `Path`, `File.Writer` and `IOErr` are from trantor-cli.

## Walk

`Walk.walk!(root, state, options, visit!)` visits everything under `root`
depth first, names sorted within each directory, and threads `state` through
`visit!`, which answers `Continue(state)`, `SkipDir(state)` to leave a
directory unread, or `Stop(state)`. Options are `follow_symlinks` (default
`False`) and `max_depth` (1 is direct children). `Walk.list!` returns the
entries instead.

```roc
# A fold counting the number of roc files, 0 is initial state.
roc_files : U64
roc_files = Walk.walk!(Path.utf8("src"), 0, {}, |n, entry|
	if entry.path.display().ends_with(".roc") { Continue(n + 1) } else { Continue(n) })?
```

```roc
Entry : {
    path : Path,
    kind : [IsFile, IsDir, IsSymLink, IsOther],
    depth : U64,         # 1 for the root's direct children
    link : Bool,         # the name itself is a symlink, even when kind is IsDir
    links : List(U64),   # the depth of every symlink on the path, this entry's included
}

Walk.walk! : Path, state, { follow_symlinks ?: Bool, max_depth ?: U64, skip_unreadable_links ?: Bool }, (state, Entry => [Continue(state), SkipDir(state), Stop(state)]) => Try(state, [PathErr(IOErr)])
Walk.list! : Path, { follow_symlinks ?: Bool, max_depth ?: U64, skip_unreadable_links ?: Bool } => Try(List(Entry), [PathErr(IOErr)])
```

`root` itself is not visited, and `max_depth: 0` visits nothing. With
`follow_symlinks: True`, a link back to a directory the walk is already inside
is `IsSymLink` and not descended, so cycles end. An unreadable directory fails
the walk, unless it is reached through a link and `skip_unreadable_links` is
`True`: then the link is visited and its contents skipped.

## Glob

`Glob.matches(pattern, path)` is pure; `Glob.expand!(pattern)` returns the
existing paths that match, sorted, searching only directories the pattern can
match below. The syntax is globset's: `*` and `?` within a component, `**` as a
whole component for any depth, `[a-z]` and `[!a-z]`, `{a,b}`, `\` escapes.
Wildcards do not match a leading `.` unless the pattern spells it. A wildcard
searches through a link to a directory, as zsh does, so `src/*/main.roc` finds
one inside a linked `src/vendor`; `**` neither matches a link nor reaches past
one, and a linked directory that cannot be listed is no match. `tests/glob-oracle`
checks the expansions against zsh's.

```roc
sources = Glob.expand!("src/**/*.{roc,rs}")?
```

```roc
Glob.matches : Str, Str -> Bool    # pattern, path; an invalid pattern matches nothing
Glob.expand! : Str => Try(List(Path), [PathErr(IOErr), InvalidGlob(Str)])
```

`expand!` returns paths spelled without `.` components, sorted by their bytes,
without duplicates, and `Ok([])` when nothing matches. A relative pattern gives
paths relative to the working directory.

## Temp

`Temp.with_dir!` and `Temp.with_file!` create a temporary directory, or a file
and a `File.Writer` on it, hand them to a callback, and delete them when it
returns, `Ok` or `Err`; a callback may also move or delete what it was given.
`Temp.create_dir!` and `Temp.create_file!` leave the
deleting to you. Each has an `_in` form taking the directory to create in; the
others use `TMPDIR`. Names are random and created exclusively, so another
process cannot plant a file where one is about to be made. Permissions are
`0o600` for a file and `0o700` for a directory, as `mkstemp` and `mkdtemp` do,
so a shared `/tmp` does not expose what is staged through one. A relative base
gives relative paths; cleanup uses the absolute path, so a callback may change
the working directory.

```roc
answer = Temp.with_file!(|path, writer| {
	writer.line!("scratch")?
	path.read_utf8!()
})?
```

```roc
Temp.with_dir! : (Path => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])) => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])
Temp.with_dir_in! : Path, (Path => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])) => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])
Temp.with_file! : (Path, File.Writer => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])) => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])
Temp.with_file_in! : Path, (Path, File.Writer => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])) => Try(a, [PathErr(IOErr), RandomErr(IOErr), ..e])
Temp.create_dir! : () => Try(Path, [PathErr(IOErr), RandomErr(IOErr)])
Temp.create_dir_in! : Path => Try(Path, [PathErr(IOErr), RandomErr(IOErr)])
Temp.create_file! : () => Try(Path, [PathErr(IOErr), RandomErr(IOErr)])
Temp.create_file_in! : Path => Try(Path, [PathErr(IOErr), RandomErr(IOErr)])
```

A callback's own errors pass through beside `PathErr` and `RandomErr`. The
callback's result wins, unless it succeeded and the cleanup then failed; a temp
the callback already moved or deleted is not a failed cleanup. The
`with_file!` writer starts at the beginning of the empty file.

## Tree

`Tree.copy!(from, to, { overwrite })` copies directories and files with their
permission bits (a directory's owner always keeps read, write and search), and
symlinks as links with the same target. Anything already
at a destination fails with `AlreadyExists` unless `overwrite: True`. A copy
that fails part way leaves what it made.
Timestamps are not copied.

```roc
Tree.copy!(Path.utf8("template"), Path.utf8("new-project"), {})?
```

```roc
Tree.copy! : Path, Path, { overwrite ?: Bool } => Try({}, [PathErr(IOErr)])    # overwrite defaults to False
```

A file `from` is copied as one file. Setuid, setgid and sticky bits are
dropped, and a socket or FIFO in the tree is `Unsupported`. With
`overwrite: True` an existing file or link is replaced only once its
replacement has been made, and an existing directory is copied into; a link
where a directory would go is still `AlreadyExists`, so nothing is written
through it.

## Testing

```sh
trantor test .
```

Runs the glob corpus and the other `expect`s, the README examples
(`tests/readme`), and suites for walking and globbing a real tree (including
an unreadable directory a glob must not open), temp files, and tree copies on
both the default and the confined filesystem.
