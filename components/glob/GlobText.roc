## UTF-8 scalars from bytes, for `?` and classes, which match a character
## rather than a byte. Malformed input decodes a byte at a time as U+FFFD, so a
## non-UTF-8 name still matches `*` and `?` without crashing anything.
GlobText :: [].{
	## The scalar starting at `i`, and how many bytes it took.
	scalar_at : List(U8), U64 -> Try({ scalar : U32, len : U64 }, [End])
	scalar_at = |bytes, i| {
		lead = List.get(bytes, i).map_err(|_| End)?
		(len, initial) =
			if lead < 0x80 {
				(1, U8.to_u32(lead))
			} else if lead >= 0xF0 and lead < 0xF8 {
				(4, U8.to_u32(U8.bitwise_and(lead, 0x07)))
			} else if lead >= 0xE0 and lead < 0xF0 {
				(3, U8.to_u32(U8.bitwise_and(lead, 0x0F)))
			} else if lead >= 0xC0 and lead < 0xF8 {
				(2, U8.to_u32(U8.bitwise_and(lead, 0x1F)))
			} else {
				(0, 0)
			}
		if len == 0 {
			Ok({ scalar: replacement, len: 1 })
		} else {
			Ok(continue_scalar(bytes, i + 1, len - 1, initial, len))
		}
	}

	scalars : List(U8) -> List(U32)
	scalars = |bytes| collect(bytes, 0, [])
}

replacement : U32
replacement = 0xFFFD

continuation_mask : U8
continuation_mask = 0x3F

continue_scalar : List(U8), U64, U64, U32, U64 -> { scalar : U32, len : U64 }
continue_scalar = |bytes, i, left, acc, len|
	if left == 0 {
		{ scalar: acc, len }
	} else {
		match List.get(bytes, i) {
			Ok(b) if b >= 0x80 and b < 0xC0 =>
				continue_scalar(bytes, i + 1, left - 1, U32.shl_wrap(acc, 6) + U8.to_u32(U8.bitwise_and(b, continuation_mask)), len)
			_ => { scalar: replacement, len: 1 }
		}
	}

collect : List(U8), U64, List(U32) -> List(U32)
collect = |bytes, i, acc| match GlobText.scalar_at(bytes, i) {
	Ok({ scalar, len }) => collect(bytes, i + len, acc.append(scalar))
	Err(End) => acc
}

expect GlobText.scalars(Str.to_utf8("aé☃😀")) == [0x61, 0xE9, 0x2603, 0x1F600]
expect GlobText.scalars([0xFF, 0x61]) == [0xFFFD, 0x61]
