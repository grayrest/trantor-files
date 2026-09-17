import GlobParse
import GlobText
## Glob patterns in globset's syntax, matched against `/`-separated paths.
##
## `*` matches within a path component and `?` one character; `**` as a whole
## component matches zero or more components; `[abc]`, `[a-z]` and `[!abc]`
## (or `[^abc]`) match one character; `{a,b}` matches either alternative; `\`
## escapes. `*`, `?`, classes and `**` do not match a component's leading `.`
## unless the pattern spells the dot.
GlobPattern :: [].{
	Pattern :: { alternatives : List(List(GlobParse.Segment)) }

	parse : Str -> Try(Pattern, [InvalidGlob(Str)])
	parse = |text| Ok(Pattern.{ alternatives: GlobParse.alternatives(text)? })

	## The component indices `**` may not take, because a symlink sits at each:
	## `**` may match a link's own component no more than it may pass through
	## one, while an ordinary wildcard or literal may take it and `**` may take
	## the components between links (zsh's rule). `Anywhere` for a path with no
	## link in it.
	Reach : [Anywhere, NotAt(List(U64))]

	## Whether `path` matches, component for component.
	matches : Pattern, Str -> Bool
	matches = |pattern, path| GlobPattern.matches_within(pattern, path, Anywhere)

	## `matches` for a path that runs through a symlink.
	matches_within : Pattern, Str, Reach -> Bool
	matches_within = |pattern, path, reach| {
		components = Str.split_on(path, "/").map(Str.to_utf8)
		List.any(pattern.alternatives, |segments| match_segments(content(segments), components, blocked_indices(reach)))
	}

	## `matches` for a path on disk: a match through an alternative with a
	## trailing `/` holds only for a directory, which the caller checks.
	match_kind : Pattern, Str -> [NoMatch, Match, IfDirectory]
	match_kind = |pattern, path| GlobPattern.match_kind_within(pattern, path, Anywhere)

	## `match_kind` for a path that runs through a symlink.
	match_kind_within : Pattern, Str, Reach -> [NoMatch, Match, IfDirectory]
	match_kind_within = |pattern, path, reach| {
		components = Str.split_on(path, "/").map(Str.to_utf8)
		matching = List.keep_if(pattern.alternatives, |segments| match_segments(content(segments), components, blocked_indices(reach)))
		if List.any(matching, |segments| !is_directory_only(segments)) {
			Match
		} else if List.is_empty(matching) {
			NoMatch
		} else {
			IfDirectory
		}
	}

	## Whether anything below the directory `path` could match: its components
	## all match leading segments of some alternative, with segments left over.
	## A search skips a directory this rules out.
	could_contain : Pattern, Str -> Bool
	could_contain = |pattern, path| GlobPattern.could_contain_within(pattern, path, Anywhere)

	## `could_contain` for a path that runs through a symlink: `**` may not
	## take the link's component or any below it, so only an ordinary wildcard
	## or literal component searches inside a linked directory (D-S2-46).
	could_contain_within : Pattern, Str, Reach -> Bool
	could_contain_within = |pattern, path, reach| {
		components = Str.split_on(path, "/").map(Str.to_utf8)
		List.any(pattern.alternatives, |segments| prefix_segments(content(segments), components, blocked_indices(reach)))
	}

	## The pattern split by where a search starts: alternatives with the same
	## literal leading directories share one start, so `{/etc,/usr}/*` searches
	## `/etc` and `/usr`, and `{/abs/*,rel/*}` does not lose the absolute one.
	starts : Pattern -> List({ prefix : Str, pattern : Pattern })
	starts = |pattern| {
		kept = List.keep_if(pattern.alternatives, |segments| !List.is_empty(content(segments)) and !unreachable(segments))
		# Two append-only passes. Scanning the groups for each alternative was
		# quadratic, and so was appending into a group held inside the group
		# list, which copied it every time: `{a,b}` sixteen times over (65536
		# alternatives, one group) took 11 seconds.
		numbered = List.fold(kept, { keys: [], at: Dict.empty(), next: 0 }, |state, segments| {
			prefix = spelled(literal_components(content(segments), []))
			# Literal alternatives start their own group, so a wildcard sharing
			# the start cannot keep them from their name-check fallback.
			literal = Try.is_ok(all_literal(content(segments), []))
			key = "${if literal { "l" } else { "g" }}${prefix}"
			match Dict.get(state.at, key) {
				Ok(index) => { ..state, keys: List.append(state.keys, { index, prefix, segments }) }
				Err(_) => {
					keys: List.append(state.keys, { index: state.next, prefix, segments }),
					at: Dict.insert(state.at, key, state.next),
					next: state.next + 1,
				}
			}
		})
		collected(List.sort_with(numbered.keys, |a, b| if a.index < b.index { Before } else if a.index > b.index { After } else { Same }), [], [])
	}

	## The alternatives with no glob syntax at all, spelled as paths, and
	## whether a trailing `/` restricts each to a directory.
	literal_paths : Pattern -> List({ name : Str, directory_only : Bool })
	literal_paths = |pattern|
		List.keep_oks(pattern.alternatives, |segments| all_literal(content(segments), []).map_ok(|c| { name: spelled(c), directory_only: is_directory_only(segments) }))

	## Literal alternatives no search can find, since a search never visits its
	## own start or `.`/`..` entries: `/`, `.`, `tree/..`. `starts` leaves them
	## out; they are checked by name.
	unreachable_literals : Pattern -> List({ name : Str, directory_only : Bool })
	unreachable_literals = |pattern|
		List.keep_oks(pattern.alternatives, |segments| if unreachable(segments) { all_literal(content(segments), []).map_ok(|c| { name: spelled(c), directory_only: is_directory_only(segments) }) } else { Err(NotLiteral) })

	## Whether every alternative is literal, so a search is only a way to find
	## names that can also be checked one by one.
	is_literal : Pattern -> Bool
	is_literal = |pattern| all_literal_group(pattern)

	## The leading components every alternative spells literally, joined with
	## `/`: the directory a search can start from. `""` when the first
	## component already has glob syntax; `"/"`-led for an absolute pattern, and
	## `"/"` when absolute alternatives share nothing more.
	literal_prefix : Pattern -> Str
	literal_prefix = |pattern| {
		prefixes = pattern.alternatives.map(|segments| literal_components(content(segments), []))
		common = match prefixes {
			[] => []
			[first, .. as rest] => List.fold(rest, first, common_prefix)
		}
		spelled(common)
	}
}

## The indices `**` may not take, as a plain list.
blocked_indices : GlobPattern.Reach -> List(U64)
blocked_indices = |reach| match reach {
	Anywhere => []
	NotAt(indices) => indices
}

## Segments against components, as a set of positions walked forward one
## component at a time: every segment index the pattern could be at after the
## components seen so far. Each component is looked at once and each position
## at most once per component, so it is linear in both however many `**` the
## pattern holds.
##
## It used to keep only the last `**` and back up to it on a mismatch, which is
## correct when every `**` may take any component. `blocked` broke that: with a
## link at one index, `a/**/*/**/b` can only match by having an EARLIER `**`
## take more, which a single back-up point cannot express.
##
## `blocked` holds the component indices `**` may not take: a symlink sits at
## each, and `**` neither matches a link nor passes through one, though it may
## take the components between links.
match_segments : List(GlobParse.Segment), List(List(U8)), List(U64) -> Bool
match_segments = |segments, components, blocked| List.contains(walked(segments, components, blocked), List.len(segments))

## `could_contain`: something is left to match below, so the walk goes deeper.
prefix_segments : List(GlobParse.Segment), List(List(U8)), List(U64) -> Bool
prefix_segments = |segments, components, blocked| List.any(walked(segments, components, blocked), |si| si < List.len(segments))

## The positions reachable after every component.
walked : List(GlobParse.Segment), List(List(U8)), List(U64) -> List(U64)
walked = |segments, components, blocked| step_components(segments, components, blocked, 0, closed(segments, [0], []))

step_components : List(GlobParse.Segment), List(List(U8)), List(U64), U64, List(U64) -> List(U64)
step_components = |segments, components, blocked, ci, states|
	match List.get(components, ci) {
		Err(_) => states
		Ok(component) => {
			next = closed(segments, taking(segments, states, component, ci, blocked, []), [])
			if List.is_empty(next) { [] } else { step_components(segments, components, blocked, ci + 1, next) }
		}
	}

## The positions after one component is taken.
taking : List(GlobParse.Segment), List(U64), List(U8), U64, List(U64), List(U64) -> List(U64)
taking = |segments, states, component, ci, blocked, done| match states {
	[] => done
	[si, .. as rest] => {
		reached = match List.get(segments, si) {
			# `**` takes this component and stays where it is, so it can take
			# the next one too; a trailing `**` that has taken one is a match.
			Ok(DoubleStar) =>
				if List.contains(blocked, ci) or is_hidden(component) {
					[]
				} else if si + 1 == List.len(segments) {
					[si, si + 1]
				} else {
					[si]
				}
			Ok(Component(tokens)) => if component_matches(tokens, component) { [si + 1] } else { [] }
			# `DirectoryOnly` and the end of the segments take no component.
			_ => []
		}
		taking(segments, rest, component, ci, blocked, List.fold(reached, done, added))
	}
}

## Every position reachable from `states` without taking a component: past a
## `DirectoryOnly`, and past a `**` matching nothing. A trailing `**` is not
## one of them, since it must take at least one component.
closed : List(GlobParse.Segment), List(U64), List(U64) -> List(U64)
closed = |segments, pending, done| match pending {
	[] => done
	[si, .. as rest] =>
		if List.contains(done, si) {
			closed(segments, rest, done)
		} else {
			onward = match List.get(segments, si) {
				Ok(DirectoryOnly) => [si + 1]
				Ok(DoubleStar) => if si + 1 == List.len(segments) { [] } else { [si + 1] }
				_ => []
			}
			closed(segments, List.concat(rest, onward), List.append(done, si))
		}
}

added : List(U64), U64 -> List(U64)
added = |states, si| if List.contains(states, si) { states } else { List.append(states, si) }

## A component starting with `.` matches only a pattern that spells the dot
## first: `*.*` does not match `.bashrc`.
component_matches : List(GlobParse.Token), List(U8) -> Bool
component_matches = |tokens, component| {
	dot_spelled = match List.first(tokens) {
		Ok(Lit(lit)) => List.first(lit) == Ok('.')
		_ => False
	}
	(!is_hidden(component) or dot_spelled) and match_tokens(tokens, component)
}

## The numbered alternatives, in group order, as one list of groups: each
## group's alternatives are appended while that list is the only reference to
## it.
collected : List({ index : U64, prefix : Str, segments : List(GlobParse.Segment) }), List(List(GlobParse.Segment)), List({ prefix : Str, pattern : GlobPattern.Pattern }) -> List({ prefix : Str, pattern : GlobPattern.Pattern })
collected = |numbered, current, done| match numbered {
	[] => done
	[one] => List.append(done, { prefix: one.prefix, pattern: GlobPattern.Pattern.{ alternatives: List.append(current, one.segments) } })
	[one, .. as rest] => {
		mine = List.append(current, one.segments)
		next = List.first(rest) ?? one
		if next.index == one.index {
			collected(rest, mine, done)
		} else {
			collected(rest, [], List.append(done, { prefix: one.prefix, pattern: GlobPattern.Pattern.{ alternatives: mine } }))
		}
	}
}

is_hidden : List(U8) -> Bool
is_hidden = |component| List.first(component) == Ok('.')

## Tokens against one component, with the same last-`*` backtracking: linear
## restarts instead of trying every split for every star. Correct because each
## non-star token matches a fixed run at one position.
match_tokens : List(GlobParse.Token), List(U8) -> Bool
match_tokens = |tokens, bytes| tokens_from(tokens, bytes, 0, 0, Err(NoStar))

tokens_from : List(GlobParse.Token), List(U8), U64, U64, Try((U64, U64), [NoStar]) -> Bool
tokens_from = |tokens, bytes, ti, bi, star| {
	restart = || match star {
		Ok((after_star, from)) => match GlobText.scalar_at(bytes, from) {
			Ok({ len, .. }) => tokens_from(tokens, bytes, after_star, from + len, Ok((after_star, from + len)))
			Err(End) => False
		}
		Err(NoStar) => False
	}
	match List.get(tokens, ti) {
		Err(_) => bi == List.len(bytes) or restart()
		Ok(Star) => tokens_from(tokens, bytes, ti + 1, bi, Ok((ti + 1, bi)))
		Ok(Lit(lit)) =>
			if List.sublist(bytes, { start: bi, len: List.len(lit) }) == lit {
				tokens_from(tokens, bytes, ti + 1, bi + List.len(lit), star)
			} else {
				restart()
			}
		Ok(Any) => match GlobText.scalar_at(bytes, bi) {
			Ok({ len, .. }) => tokens_from(tokens, bytes, ti + 1, bi + len, star)
			Err(End) => restart()
		}
		Ok(Class(class)) => match GlobText.scalar_at(bytes, bi) {
			Ok({ scalar, len }) => if in_class(class, scalar) { tokens_from(tokens, bytes, ti + 1, bi + len, star) } else { restart() }
			Err(End) => restart()
		}
	}
}

in_class : { negated : Bool, items : List([Single(U32), Range(U32, U32)]) }, U32 -> Bool
in_class = |class, scalar| {
	member = List.any(class.items, |item| match item {
		Single(c) => c == scalar
		Range(lo, hi) => scalar >= lo and scalar <= hi
	})
	member != class.negated
}

## Components joined with `/`; `[""]`, the root alone, is `/`.
spelled : List(List(U8)) -> Str
spelled = |components| if components == [[]] { "/" } else { Str.join_with(components.map(Str.from_utf8_lossy), "/") }

literal_components : List(GlobParse.Segment), List(List(U8)) -> List(List(U8))
literal_components = |segments, acc| match segments {
	[Component([]), .. as rest] => literal_components(rest, acc.append([]))
	[Component([Lit(bytes)]), .. as rest] => if List.is_empty(rest) { acc } else { literal_components(rest, acc.append(bytes)) }
	_ => acc
}

## An alternative without its `DirectoryOnly` marker: what matches components.
content : List(GlobParse.Segment) -> List(GlobParse.Segment)
content = |segments| if is_directory_only(segments) { List.drop_last(segments, 1) } else { segments }

is_directory_only : List(GlobParse.Segment) -> Bool
is_directory_only = |segments| match List.last(segments) {
	Ok(DirectoryOnly) => True
	_ => False
}

all_literal_group : GlobPattern.Pattern -> Bool
all_literal_group = |pattern| List.all(pattern.alternatives, |segments| Try.is_ok(all_literal(content(segments), [])))

## A literal alternative whose last component a walk never yields.
unreachable : List(GlobParse.Segment) -> Bool
unreachable = |segments| match all_literal(content(segments), []) {
	Ok(components) => components == [[]] or List.last(components) == Ok(['.']) or List.last(components) == Ok(['.', '.'])
	Err(NotLiteral) => False
}

all_literal : List(GlobParse.Segment), List(List(U8)) -> Try(List(List(U8)), [NotLiteral])
all_literal = |segments, acc| match segments {
	[] => if List.is_empty(acc) { Err(NotLiteral) } else { Ok(acc) }
	[Component([]), .. as rest] => all_literal(rest, acc.append([]))
	[Component([Lit(bytes)]), .. as rest] => all_literal(rest, acc.append(bytes))
	_ => Err(NotLiteral)
}

common_prefix : List(List(U8)), List(List(U8)) -> List(List(U8))
common_prefix = |a, b| match (a, b) {
	([x, .. as xs], [y, .. as ys]) => if x == y { List.concat([x], common_prefix(xs, ys)) } else { [] }
	_ => []
}

## The corpus: `(pattern, path, matches)`.
corpus : List((Str, Str, Bool))
corpus = [
	("*.roc", "main.roc", True),
	("*.roc", "main.rs", False),
	("*.roc", "src/main.roc", False),
	("*", "", True),
	("a?c", "abc", True),
	("a?c", "ac", False),
	("a?c", "aéc", True),
	("src/*/lib.rs", "src/core/lib.rs", True),
	("src/*/lib.rs", "src/lib.rs", False),
	("**/*.roc", "main.roc", True),
	("**/*.roc", "a/b/c/main.roc", True),
	("a/**/b", "a/b", True),
	("a/**/b", "a/x/y/b", True),
	("a/**/b", "a/x/y/c", False),
	("a/**", "a/x/y", True),
	("a/**", "a", False),
	("**", "anything/at/all", True),
	("[abc].txt", "b.txt", True),
	("[abc].txt", "d.txt", False),
	("[a-c]x", "cx", True),
	("[!a-c]x", "cx", False),
	("[^a-c]x", "dx", True),
	("[]]", "]", True),
	("[!]]", "a", True),
	("{src,test}/*.roc", "test/a.roc", True),
	("{src,test}/*.roc", "docs/a.roc", False),
	("*.{rs,roc}", "lib.rs", True),
	("*.{rs,roc}", "lib.toml", False),
	("\\*.txt", "*.txt", True),
	("\\*.txt", "a.txt", False),
	("*", ".hidden", False),
	("?hidden", ".hidden", False),
	("[.]hidden", ".hidden", False),
	(".*", ".hidden", True),
	("**/*.roc", ".git/x.roc", False),
	("a/.b/*", "a/.b/c", True),
	("/abs/*.txt", "/abs/x.txt", True),
	("/abs/*.txt", "abs/x.txt", False),
	("a*b*c", "axxbyyc", True),
	("a*b*c", "axxbyy", False),
	("*é", "café", True),
	("*.*", ".bashrc", False),
	("*.txt", ".txt", False),
	(".*.txt", ".a.txt", True),
	("[a\\-z]", "_", False),
	("[a\\-z]", "-", True),
	("[\\a-z]", "b", True),
	("[a-]", "-", True),
	("src/lib/", "src/lib", True),
	("src/*/", "src/core", True),
	("rel//*", "rel/y", True),
	("a/**//b", "a/x/b", True),
	("**/a/**/b", "x/a/y/a/z/b", True),
	("**/a/**/b", "x/a/y/a/z/c", False),
	("a/**/.x/b", "a/y/.x/b", True),
	("*a*a*a*a*a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", False),
	("**/**/**/**/**/**/x", "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/y", False),
]

outcome : (Str, Str, Bool) -> Bool
outcome = |(pattern, path, expected)| match GlobPattern.parse(pattern) {
	Ok(p) => GlobPattern.matches(p, path) == expected
	Err(_) => False
}

## Every corpus case that disagrees, by pattern and path: empty when all pass.
expect List.keep_if(corpus, |case| !outcome(case)).map(|(pattern, path, _)| "${pattern} ~ ${path}") == []

contains : Str, Str -> Bool
contains = |pattern, dir| match GlobPattern.parse(pattern) {
	Ok(p) => GlobPattern.could_contain(p, dir)
	Err(_) => False
}

expect contains("src/*/lib.rs", "src")
expect contains("src/*/lib.rs", "src/core")
expect !contains("src/*/lib.rs", "src/core/deep")
expect !contains("src/*/lib.rs", "docs")
expect contains("**/*.roc", "a/b/c")
expect !contains("**/*.roc", ".git")
expect !contains("*.roc", "sub")
expect contains("{a,b}/*/x", "b/c")
expect !contains("**/x", ".git")
expect contains("a/**/.x/y", "a/b/.x")
expect !contains("**/**/**/**/**/**/**/x", "a/b/c/d/e/f/g/h/i/j/k/l/m/n/.h")
expect contains("**/**/**/**/**/**/**/.h/x", "a/b/c/d/e/f/g/h/i/j/k/l/m/n/.h")

starts : Str -> List(Str)
starts = |pattern| match GlobPattern.parse(pattern) {
	Ok(p) => GlobPattern.starts(p).map(|s| s.prefix)
	Err(_) => ["<invalid>"]
}

expect starts("{/abs/*,rel/*}") == ["/abs", "rel"]

literals : Str -> List(Str)
literals = |pattern| match GlobPattern.parse(pattern) {
	Ok(p) => GlobPattern.literal_paths(p).map(|l| l.name)
	Err(_) => ["<invalid>"]
}

expect literals("{.,tree/..,*.x,/}") == [".", "tree/..", "/"]
expect literals("{a,}") == ["a"]
expect literals("tree/sub/") == ["tree/sub"]

unreachables : Str -> List(Str)
unreachables = |pattern| match GlobPattern.parse(pattern) {
	Ok(p) => GlobPattern.unreachable_literals(p).map(|l| l.name)
	Err(_) => ["<invalid>"]
}

expect unreachables("{.,tree/..,tree/a.txt,*.x,/}") == [".", "tree/..", "/"]
expect starts("{tree/a.txt,.,}") == ["tree"]
expect starts("") == []
expect starts("*.{rs,roc}") == [""]
expect starts("{/etc,/usr}/*") == ["/etc", "/usr"]
expect starts("{src,test}/a/*") == ["src/a", "test/a"]

invalid : Str -> Bool
invalid = |pattern| match GlobPattern.parse(pattern) {
	Ok(_) => False
	Err(InvalidGlob(_)) => True
}

expect invalid("[abc")
expect invalid("{a,b")
expect invalid("{a,{b,c}}")
expect invalid("a**b")
expect invalid("trailing\\")
expect invalid("*{*,x}")
expect invalid("a*{*,b}")
expect invalid("**/*{*,x}")
expect invalid("[**]/*{*,x}")
expect invalid("{a,*}*")
expect invalid("tree/*/../a.txt")
expect invalid("x\\/y")
expect invalid("*/.")
expect invalid("**/../x")
expect !invalid("../*.txt")
expect !invalid("a/./b/*")

kind : Str, Str -> [NoMatch, Match, IfDirectory, Invalid]
kind = |pattern, path| match GlobPattern.parse(pattern) {
	Ok(p) => match GlobPattern.match_kind(p, path) {
		NoMatch => NoMatch
		Match => Match
		IfDirectory => IfDirectory
	}
	Err(_) => Invalid
}

expect kind("tree/*/", "tree/sub") == IfDirectory
expect kind("{tree/*/,tree/a*}", "tree/a.txt") == Match
expect kind("tree/*/", "tree/sub/x") == NoMatch
expect GlobPattern.parse("tree/sub/").map_ok(|p| GlobPattern.starts(p).map(|g| g.prefix)) == Ok(["tree"])
expect !invalid("{\\*,a}*")
expect !invalid("\\**")
expect !invalid("a/**/b")

prefix : Str -> Str
prefix = |pattern| match GlobPattern.parse(pattern) {
	Ok(p) => GlobPattern.literal_prefix(p)
	Err(_) => "<invalid>"
}

expect prefix("src/core/*.rs") == "src/core"
expect prefix("*.rs") == ""
expect prefix("src/{a,b}/x") == "src"
expect prefix("/usr/lib/**/*.so") == "/usr/lib"
expect prefix("src/main.roc") == "src"
expect prefix("{src,test}/*.roc") == ""
expect prefix("{/etc,/usr}/*") == "/"
expect prefix("src/lib/") == "src"
