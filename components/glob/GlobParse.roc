import GlobText
## Glob pattern text to a matcher's structure: brace alternatives expanded,
## then each alternative split into path components of tokens.
GlobParse :: [].{
	## One piece of a path component's pattern.
	Token : [Lit(List(U8)), Star, Any, Class({ negated : Bool, items : List([Single(U32), Range(U32, U32)]) })]
	## A path component's pattern, `**` (zero or more whole components), or
	## `DirectoryOnly`: a trailing `/`, which takes no component and restricts
	## a match to directories (D-S2-33). It is only ever last.
	Segment : [DoubleStar, Component(List(Token)), DirectoryOnly]

	## Every alternative a pattern spells, each as its segments.
	alternatives : Str -> Try(List(List(Segment)), [InvalidGlob(Str)])
	alternatives = |pattern| {
		expanded = expand_braces(Str.to_utf8(pattern))?
		List.fold_try(expanded, [], |acc, alt| Ok(List.append(acc, segments(alt)?)))
	}
}

## Whether `bytes` ends in a `*` that is not escaped: an even run of `\`
## before it.
ends_with_star : List(U8) -> Bool
ends_with_star = |bytes| match List.last(bytes) {
	Ok('*') => U64.is_even(trailing_backslashes(List.drop_last(bytes, 1), 0))
	_ => False
}

trailing_backslashes : List(U8), U64 -> U64
trailing_backslashes = |bytes, n| match List.last(bytes) {
	Ok('\\') => trailing_backslashes(List.drop_last(bytes, 1), n + 1)
	_ => n
}

## A brace join that puts two stars side by side: `*{*,x}` spells no `**`, but
## its first alternative would be one. Checked where the join happens, so a
## real `**` elsewhere in the pattern, or an escaped `\*`, does not matter.
joins_stars : List(U8), List(U8) -> Bool
joins_stars = |before, after| ends_with_star(before) and List.first(after) == Ok('*')

invalid : Str -> Try(a, [InvalidGlob(Str)])
invalid = |why| Err(InvalidGlob(why))

## The index just past a `[...]` class starting at `start` (the `[`). A `]`
## first in the class, or first after `!`/`^`, is a member, not the close.
class_end : List(U8), U64 -> Try(U64, [InvalidGlob(Str)])
class_end = |bytes, start| {
	after_open = start + 1
	after_negation = match List.get(bytes, after_open) {
		Ok('!') | Ok('^') => after_open + 1
		_ => after_open
	}
	first_member = match List.get(bytes, after_negation) {
		Ok(']') => after_negation + 1
		_ => after_negation
	}
	find_close(bytes, first_member)
}

find_close : List(U8), U64 -> Try(U64, [InvalidGlob(Str)])
find_close = |bytes, i| match List.get(bytes, i) {
	Ok(']') => Ok(i + 1)
	Ok('\\') => find_close(bytes, i + 2)
	Ok(_) => find_close(bytes, i + 1)
	Err(_) => invalid("unclosed character class")
}

## `{a,b}` expanded, left to right, into one pattern per alternative. Braces
## do not nest; escapes and classes are copied through untouched.
expand_braces : List(U8) -> Try(List(List(U8)), [InvalidGlob(Str)])
expand_braces = |bytes| expand_from(bytes, 0, [])

expand_from : List(U8), U64, List(U8) -> Try(List(List(U8)), [InvalidGlob(Str)])
expand_from = |bytes, i, prefix| match List.get(bytes, i) {
	Err(_) => Ok([prefix])
	Ok('\\') => match List.get(bytes, i + 1) {
		Ok(c) => expand_from(bytes, i + 2, prefix.append('\\').append(c))
		Err(_) => invalid("a trailing \\ escapes nothing")
	}
	Ok('[') => {
		end = class_end(bytes, i)?
		expand_from(bytes, end, List.concat(prefix, List.sublist(bytes, { start: i, len: end - i })))
	}
	Ok('{') => {
		(alts, after) = brace_alternatives(bytes, i + 1, [], [])?
		List.fold_try(alts, [], |acc, alt| {
			joined = List.concat(prefix, alt)
			if joins_stars(prefix, alt) or joins_stars(joined, List.drop_first(bytes, after)) {
				invalid("braces may not join two * into **")
			} else {
				Ok(List.concat(acc, expand_from(bytes, after, joined)?))
			}
		})
	}
	Ok(c) => expand_from(bytes, i + 1, prefix.append(c))
}

## The alternatives inside a brace group and the index past its `}`.
brace_alternatives : List(U8), U64, List(List(U8)), List(U8) -> Try((List(List(U8)), U64), [InvalidGlob(Str)])
brace_alternatives = |bytes, i, done, current| match List.get(bytes, i) {
	Err(_) => invalid("unclosed {")
	Ok('{') => invalid("nested { is not supported")
	Ok('}') => Ok((done.append(current), i + 1))
	Ok(',') => brace_alternatives(bytes, i + 1, done.append(current), [])
	Ok('\\') => match List.get(bytes, i + 1) {
		Ok(c) => brace_alternatives(bytes, i + 2, done, current.append('\\').append(c))
		Err(_) => invalid("a trailing \\ escapes nothing")
	}
	Ok('[') => {
		end = class_end(bytes, i)?
		brace_alternatives(bytes, end, done, List.concat(current, List.sublist(bytes, { start: i, len: end - i })))
	}
	Ok(c) => brace_alternatives(bytes, i + 1, done, current.append(c))
}

## Split on `/` outside classes and escapes, then tokenize each component.
segments : List(U8) -> Try(List(GlobParse.Segment), [InvalidGlob(Str)])
segments = |bytes| if List.is_empty(bytes) {
	# An empty alternative (`""`, `{a,}`) names nothing; it is not `/`.
	Ok([])
} else {
	split = split_components(bytes, 0, [], [])?
	# `a//b` is `a/b`: no walked path has an empty component. A leading one
	# stays, making `/a` absolute; a trailing one is `DirectoryOnly`.
	directory_only = List.len(split) > 1 and List.last(split) == Ok([])
	components = List.fold_with_index(split, [], |acc, component, index|
		if index > 0 and List.is_empty(component) { acc } else { acc.append(component) })
	parsed = List.fold_try(components, [], |acc, component|
		if component == ['*', '*'] {
			Ok(acc.append(DoubleStar))
		} else {
			Ok(acc.append(Component(tokens(component, 0, [])?)))
		})?
	no_dots_after_wildcards(parsed, False)?
	Ok(if directory_only { parsed.append(DirectoryOnly) } else { parsed })
}

## `.` or `..` after a component with glob syntax: a walk never yields those
## entries, so the pattern could never match (D-S2-32).
no_dots_after_wildcards : List(GlobParse.Segment), Bool -> Try({}, [InvalidGlob(Str)])
no_dots_after_wildcards = |remaining, seen_wildcard| match remaining {
	[] => Ok({})
	[Component([Lit(['.'])]), .. as rest] | [Component([Lit(['.', '.'])]), .. as rest] =>
		if seen_wildcard { invalid(". or .. after a wildcard is not supported") } else { no_dots_after_wildcards(rest, False) }
	[Component([]), .. as rest] | [Component([Lit(_)]), .. as rest] => no_dots_after_wildcards(rest, seen_wildcard)
	[_, .. as rest] => no_dots_after_wildcards(rest, True)
}

split_components : List(U8), U64, List(List(U8)), List(U8) -> Try(List(List(U8)), [InvalidGlob(Str)])
split_components = |bytes, i, done, current| match List.get(bytes, i) {
	Err(_) => Ok(done.append(current))
	Ok('/') => split_components(bytes, i + 1, done.append(current), [])
	# No name holds a `/`; as an escape it could only ever match by accident.
	Ok('\\') if List.get(bytes, i + 1) == Ok('/') => invalid("an escaped / cannot be part of a name")
	Ok('\\') => match List.get(bytes, i + 1) {
		Ok(c) => split_components(bytes, i + 2, done, current.append('\\').append(c))
		Err(_) => invalid("a trailing \\ escapes nothing")
	}
	Ok('[') => {
		end = class_end(bytes, i)?
		split_components(bytes, end, done, List.concat(current, List.sublist(bytes, { start: i, len: end - i })))
	}
	Ok(c) => split_components(bytes, i + 1, done, current.append(c))
}

tokens : List(U8), U64, List(GlobParse.Token) -> Try(List(GlobParse.Token), [InvalidGlob(Str)])
tokens = |bytes, i, acc| match List.get(bytes, i) {
	Err(_) => Ok(acc)
	Ok('*') =>
		if List.get(bytes, i + 1) == Ok('*') {
			invalid("** must be a whole path component")
		} else {
			tokens(bytes, i + 1, acc.append(Star))
		}
	Ok('?') => tokens(bytes, i + 1, acc.append(Any))
	Ok('\\') => match List.get(bytes, i + 1) {
		Ok(c) => tokens(bytes, i + 2, literal(acc, c))
		Err(_) => invalid("a trailing \\ escapes nothing")
	}
	Ok('[') => {
		end = class_end(bytes, i)?
		tokens(bytes, end, acc.append(class(List.sublist(bytes, { start: i + 1, len: end - i - 2 }))?))
	}
	Ok(c) => tokens(bytes, i + 1, literal(acc, c))
}

## Adjacent literal bytes collect into one `Lit`.
literal : List(GlobParse.Token), U8 -> List(GlobParse.Token)
literal = |acc, c| match List.last(acc) {
	Ok(Lit(bytes)) => List.drop_last(acc, 1).append(Lit(bytes.append(c)))
	_ => acc.append(Lit([c]))
}

## A class body (between the brackets) as its members. A class that can match
## nothing is refused, as an escaped `/` is: a reversed range (`[z-a]`), which
## globset rejects too, and a class of only `/`, which no path component holds.
class : List(U8) -> Try(GlobParse.Token, [InvalidGlob(Str)])
class = |body| {
	negated = List.first(body) == Ok('!') or List.first(body) == Ok('^')
	members = if negated { List.drop_first(body, 1) } else { body }
	items = class_items(GlobText.scalars(members), [])
	if List.any(items, |item| match item { Range(lo, hi) => lo > hi, Single(_) => False }) {
		invalid("a class range runs backwards")
	} else if !negated and List.all(items, |item| item == Single('/') or item == Range('/', '/')) {
		invalid("a class of only / matches nothing inside a path component")
	} else {
		Ok(Class({ negated, items }))
	}
}

## Members left to right: one character, escaped or not, then `-` and a second
## makes a range. `[a\-z]` is `a`, `-`, `z`; a trailing `-` is itself.
class_items : List(U32), List([Single(U32), Range(U32, U32)]) -> List([Single(U32), Range(U32, U32)])
class_items = |scalars, acc| match class_char(scalars) {
	Err(Empty) => acc
	Ok((lo, after_lo)) => match after_lo {
		['-', .. as after_dash] => match class_char(after_dash) {
			Ok((hi, rest)) => class_items(rest, acc.append(Range(lo, hi)))
			Err(Empty) => class_items(after_dash, acc.append(Single(lo)).append(Single('-')))
		}
		_ => class_items(after_lo, acc.append(Single(lo)))
	}
}

class_char : List(U32) -> Try((U32, List(U32)), [Empty])
class_char = |scalars| match scalars {
	['\\', c, .. as rest] => Ok((c, rest))
	[c, .. as rest] => Ok((c, rest))
	[] => Err(Empty)
}
