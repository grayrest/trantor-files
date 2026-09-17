import OsStr exposing [OsStr]
import Path
import IOErr exposing [IOErr]
## Bytes to and from basic-cli's `Path`, for FsOps, which speaks bytes.
FilesPath :: [].{
	## A path's bytes. Windows UTF-16 paths are not representable on this host
	## and come out as their lossy text, which FsOps then fails to find.
	bytes : Path.Path -> List(U8)
	bytes = |path| match OsStr.to_raw(Path.to_raw(path)) {
		Utf8(s) => Str.to_utf8(s)
		UnixBytes(b) => b
		WindowsU16s(_) => Str.to_utf8(Path.display(path))
	}

	## A path from bytes: text when they are UTF-8, raw otherwise.
	from_bytes : List(U8) -> Path.Path
	from_bytes = |b| match Str.from_utf8(b) {
		Ok(s) => Path.utf8(s)
		Err(_) => Path.unix_bytes(b)
	}

	## Whether an error is a loop of symbolic links (ELOOP). `IOErr` has no
	## variant for it, so it arrives as `Other` with the OS error number in its
	## message: 62 on macOS, 40 on Linux. Neither number is otherwise what a
	## path lookup returns on the other system (EMSGSIZE, ETIME).
	is_link_loop : IOErr -> Bool
	is_link_loop = |err| match err {
		Other(message) => Str.contains(message, "(os error 62)") or Str.contains(message, "(os error 40)")
		_ => False
	}

	## Whether a name is too long to look up (ENAMETOOLONG): `Other` with 63 on
	## macOS, 36 on Linux. Neither is a path lookup's error on the other system
	## (ENOSR, EINPROGRESS).
	is_name_too_long : IOErr -> Bool
	is_name_too_long = |err| match err {
		Other(message) => Str.contains(message, "(os error 63)") or Str.contains(message, "(os error 36)")
		_ => False
	}

	## A name that leads nowhere without anything refusing it: a loop of links
	## or a name too long to look up. Like a missing name, it is no match and a
	## link to it is only a link (D-S2-25, D-S2-42).
	leads_nowhere : IOErr -> Bool
	leads_nowhere = |err| FilesPath.is_link_loop(err) or FilesPath.is_name_too_long(err)

	## `n`'s low `digits` hex digits, lowercase, most significant first.
	hex : U64, U64 -> Str
	hex = |n, digits| hex_digits(n, digits, "")

	## The directory part of a path's bytes: `a/b` → `a`, `/b` → `/`, `b` → `""`.
	parent : List(U8) -> List(U8)
	parent = |path_bytes| match List.find_last_index(path_bytes, |b| b == '/') {
		Ok(0) => ['/']
		Ok(i) => List.take_first(path_bytes, i)
		Err(_) => []
	}

	## `dir/name`, without doubling a trailing `/`.
	child : List(U8), List(U8) -> List(U8)
	child = |dir, name| match List.last(dir) {
		Ok('/') => List.concat(dir, name)
		Ok(_) => List.concat(dir.append('/'), name)
		Err(_) => name
	}
}

hex_digits : U64, U64, Str -> Str
hex_digits = |n, left, acc|
	if left == 0 {
		acc
	} else {
		digit = U64.to_u8_wrap(U64.bitwise_and(n, 0xF))
		char = if digit < 10 { '0' + digit } else { 'a' + digit - 10 }
		hex_digits(U64.shr_wrap(n, 4), left - 1, Str.concat(Str.from_utf8_lossy([char]), acc))
	}

expect FilesPath.is_link_loop(Other("Too many levels of symbolic links (os error 62)"))
expect !FilesPath.is_link_loop(Other("Input/output error (os error 5)"))
expect FilesPath.hex(0xDEADBEEF, 8) == "deadbeef"
expect FilesPath.hex(0x0123456789ABCDEF, 16) == "0123456789abcdef"
expect FilesPath.parent(Str.to_utf8("a/b/c")) == Str.to_utf8("a/b")
expect FilesPath.parent(Str.to_utf8("/c")) == Str.to_utf8("/")
expect FilesPath.parent(Str.to_utf8("c")) == []
expect FilesPath.child(Str.to_utf8("a"), Str.to_utf8("b")) == Str.to_utf8("a/b")
expect FilesPath.child(Str.to_utf8("/"), Str.to_utf8("b")) == Str.to_utf8("/b")
expect FilesPath.bytes(FilesPath.from_bytes([0x61, 0xFF])) == [0x61, 0xFF]
