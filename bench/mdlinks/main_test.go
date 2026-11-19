package main

import (
	"reflect"
	"strings"
	"testing"
)

// The anchors GitHub gives these headings, by github-slugger's rule
// (lowercase; every character but letters, marks, numbers, "_", "-" and
// spaces dropped; spaces to "-") applied to the heading's rendered text.
func TestSlug(t *testing.T) {
	cases := map[string]string{
		"Documentation":                         "documentation",
		"Production contract: `Conn.step`":      "production-contract-connstep",
		"The over-5 s tail":                     "the-over-5-s-tail",
		"What's *new* in [v2](docs/v2.md)?":     "whats-new-in-v2",
		"Zażółć gęślą jaźń":                     "zażółć-gęślą-jaźń",
		"C++ &amp; Go":                          "c--go",
		"Image ![alt](x.png) gone":              "image--gone",
		"Escaped \\# hash":                      "escaped--hash",
		"<code>tag</code> text":                 "tag-text",
		"  Leading and trailing ":               "--leading-and-trailing-",
		"Dates (2026-11-19), items g4vate/x.md": "dates-2026-11-19-items-g4vatexmd",
		"Title <!-- note -->":                   "title-",
		// Code spans keep their content verbatim: no tags, entities or
		// emphasis inside them.
		"Use `&amp;`":                           "use-amp",
		"The `<div>` element":                   "the-div-element",
		"Type `Vec<T>` and `a<b` `c>d`":         "type-vect-and-ab-cd",
		"Code `_x_`":                            "code-_x_",
		"`<!-- keep -->`":                       "---keep---",
		"[Read `]` here](guide.md)":             "read--here",
		"See <https://example.org>":             "see-httpsexampleorg",
		"Install<!-- TODO: document `PATH` -->": "install",
		"Title <!-- [draft](draft.md) -->":      "title-",
		// "_" goes only where it pairs up as emphasis.
		"snake_case and _emphasis_": "snake_case-and-emphasis",
		"__Bold__ text":             "bold-text",
		"_word":                     "_word",
		"a _ b":                     "a-_-b",
	}
	for in, want := range cases {
		if got := slug(inlineText(in)); got != want {
			t.Errorf("slug(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDuplicateHeadings(t *testing.T) {
	got := slugs([]string{"Notes", "Notes", "Notes-1", "Notes"})
	want := map[string]bool{"notes": true, "notes-1": true, "notes-1-1": true, "notes-2": true}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("slugs = %v, want %v", got, want)
	}
}

// docLinks is every link scan and links find in a document.
func docLinks(text string) []link {
	var out []link
	_, bs := scan(text)
	for _, b := range bs {
		out = append(out, links(b)...)
	}
	return out
}

func TestHeadings(t *testing.T) {
	doc := strings.Join([]string{
		"# Title",
		"## Closed ##",
		"# ###",
		"#hashtag is no heading",
		"",
		"Setext heading",
		"===",
		"",
		"---",
		"Not a setext title, after a thematic break",
		"",
		"- a list item",
		"---",
		"",
		"<!--",
		"# Ghost",
		"-->",
		"",
		"```",
		"# Fenced",
		"```",
		"",
		"    # Indented",
		"",
		"# CRLF\r",
		"Setext CRLF\r",
		"---\r",
		"",
		"[r]: t.md",
		"---",
		"",
		"[api]: api.md",
		"Installation",
		"============",
		"",
		"[r]: ",
		"---",
	}, "\n")
	hs, _ := scan(doc)
	want := []string{"Title", "Closed", "", "Setext heading", "CRLF", "Setext CRLF", "Installation", "[r]:"}
	if !reflect.DeepEqual(hs, want) {
		t.Errorf("headings = %q\nwant       %q", hs, want)
	}
}

// Links are found in prose with their lines, and not in code, comments or
// text that only looks like a link.
func TestLinks(t *testing.T) {
	cases := []struct {
		name string
		doc  string
		want []link
	}{
		{"inline and image", "Text [a](a.md) and ![i](i.png).", []link{{1, "a.md"}, {1, "i.png"}}},
		{"title", "[a](a.md \"t\") [b](b.md 't') [c](c.md (t))", []link{{1, "a.md"}, {1, "b.md"}, {1, "c.md"}}},
		{"spanning lines", "x\n[spanning\nlines](f.md)", []link{{3, "f.md"}}},
		{"escapes and parens", "[e](g\\(1\\).md) [p](h(1).md) [pct](i%20j.md) [ent](a&amp;b.md)",
			[]link{{1, "g(1).md"}, {1, "h(1).md"}, {1, "i%20j.md"}, {1, "a&b.md"}}},
		{"angle brackets", "[a](<d e.md#x>)", []link{{1, "d e.md#x"}}},
		{"escaped bracket", "\\[not](no.md)", nil},
		{"escaped backslash", "\\\\[real](r.md)", []link{{1, "r.md"}}},
		{"code span", "`[code](no.md)` [y](y.md)", []link{{1, "y.md"}}},
		{"html comment", "x <!-- [c](no.md) --> [y](y.md)\n\n<!--\n[c](no.md)\n-->\n[z](z.md)", []link{{1, "y.md"}, {6, "z.md"}}},
		// A line that starts with "<!--" is an HTML block: none of it is Markdown.
		{"html block", "<!-- c --> [no](no.md)", nil},
		{"fenced", "```\n[f](no.md)\n```\n~~~ lean\n[f](no.md)\n~~~\n[y](y.md)", []link{{7, "y.md"}}},
		{"indented code", "x\n\n    [i](no.md)\n\n[y](y.md)", []link{{5, "y.md"}}},
		{"indented fence is code", "    ```\n\n[real](r.md)", []link{{3, "r.md"}}},
		{"list item fence", "- ```\n  [literal](no.md)\n  ```\n\n[real](r.md)", []link{{5, "r.md"}}},
		{"list continuation", "- item [li](b.md)\n\n    [in list](c.md)", []link{{1, "b.md"}, {3, "c.md"}}},
		{"heading ends at newline", "# [not a link\ncontinued](no.md)", nil},
		{"unclosed", "[x](no.md\n\n[x](no.md not-a-title)\n\nfoo[0](bar baz)", nil},
		{"web", "[w](https://x.org/a.md) [m](mailto:a@b)", []link{{1, "https://x.org/a.md"}, {1, "mailto:a@b"}}},
		{"reference definitions", "[r]: r.md\n[s]: <s s.md> \"title [l](no.md)\"\n\n[t]:\n  t.md 'x'",
			[]link{{1, "r.md"}, {2, "s s.md"}, {4, "t.md"}}},
		{"reference definition in a list item", "- [r]: r.md", []link{{1, "r.md"}}},
		{"title on the next line", "[r]: r.md\n  \"title [x](no.md)\"", []link{{1, "r.md"}}},
		{"indented fence does not close", "~~~\n    ~~~\n[code](no.md)\n~~~", nil},
		{"list fence ends with its item", "- ~~~\n  code\n\n[real](r.md)", []link{{4, "r.md"}}},
		{"indented code after a heading", "# Heading\n    [code](no.md)", nil},
		{"thematic break ends a paragraph", "[unfinished\n***\ncontinued](no.md)", nil},
		{"spaced thematic break is no list", "- - -\n\n    [code](no.md)", nil},
		{"backticks in a destination", "[x](a`b`.md)", []link{{1, "a`b`.md"}}},
		{"backticks in titles", "[a](a.md \"`\") [b](b.md \"`\")", []link{{1, "a.md"}, {1, "b.md"}}},
		{"escaped ampersand", "[x](a\\&amp;b.md)", []link{{1, "a&amp;b.md"}}},
		{"unclosed comment is text", "Text <!-- [x](r.md)", []link{{1, "r.md"}}},
		{"no link in a link", "[outer [inner](ok.md)](no.md)", []link{{1, "ok.md"}}},
		{"image in a link", "[![alt](img.png)](r.md)", []link{{1, "img.png"}, {1, "r.md"}}},
		{"hard line break", "[text\\\n](r.md)", []link{{2, "r.md"}}},
		{"top-level fence after a list fence", "- ```\n  make build\n```\n[example](no.md)\n```\n\n[guide](g.md)", []link{{7, "g.md"}}},
		{"indented list item fence", " - ~~~\n   code\n - [real](r.md)", []link{{3, "r.md"}}},
		{"fence after a list item", "- item\n```\n[not a link](no.md)\n```", nil},
		{"heading ends a list", "- item\n## Next\n    [example](no.md)", nil},
		{"link in an image", "![Diagram of [step 1](s.md)](d.png)", []link{{1, "s.md"}, {1, "d.png"}}},
		{"fence deeper than its item", "- Paste this:\n\n    ```markdown\n  [Example](no.md)\n    ```\n\n[real](r.md)", []link{{7, "r.md"}}},
		{"fence closed at the item's column", "- item\n    ```\n    code\n  ```\n  [real](r.md)", []link{{5, "r.md"}}},
		{"spaced thematic break ends a list", "- item\n\n* * *\n\n    [code](no.md)", nil},
		{"inactive opener in an image", "![diagram [see [v1](v1.md)](v2.md)](d.png)", []link{{1, "v1.md"}, {1, "d.png"}}},
		{"not reference definitions", "Paragraph\n[r]: no.md\n\n[RFC 9110]: the HTTP semantics.\n\n[x]: y.md trailing", nil},
	}
	for _, c := range cases {
		if got := docLinks(c.doc); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: links = %v, want %v", c.name, got, c.want)
		}
	}
}

// Every way a link can fail is reported with its file, line and cause, and
// links that resolve are not.
func TestCheck(t *testing.T) {
	docs := map[string]string{
		"README.md": "# Read me\n\n## Usage\n\n## Usage\n\n" +
			"[ok](docs/a.md#section-two) [ok](#usage-1) [ok](docs/) [ok](/docs/a.md) [ok](#)\n" +
			"[ok](LICENSE#L3) [ok](docs/a%20b.md) [web](https://example.org/#x) [web](//example.org/x)\n" +
			"[ok](docs/a.md?plain=1#section-two) [ok](/) [ok](docs/a.md#)\n" +
			"[bad](docs/missing.md) [bad](#usage-2) [bad](docs/a.md#Section-Two)\n" +
			"[bad](../outside.md) [bad](untracked.md) [bad](README.md/) [bad](/../x.md) [bad](a%ZZ.md)\n",
		"docs/a.md":   "Section two\n===\n\n[ok](../README.md#read-me) [bad](../README.md#nope) [bad](#%ZZ)\n",
		"docs/a b.md": "",
	}
	tracked := map[string]bool{"README.md": true, "docs/a.md": true, "docs/a b.md": true, "LICENSE": true}
	problems, n := check(docs, tracked)
	var got []string
	for _, p := range problems {
		got = append(got, p.String())
	}
	want := []string{
		"README.md:10: (docs/missing.md): path: docs/missing.md is not a tracked file or directory",
		"README.md:10: (#usage-2): anchor: no heading of README.md has the slug usage-2",
		"README.md:10: (docs/a.md#Section-Two): anchor: no heading of docs/a.md has the slug Section-Two",
		"README.md:11: (../outside.md): path: ../outside.md is outside the repository",
		"README.md:11: (untracked.md): path: untracked.md is not a tracked file or directory",
		"README.md:11: (README.md/): path: README.md is a file, not a directory",
		"README.md:11: (/../x.md): path: ../x.md is outside the repository",
		"README.md:11: (a%ZZ.md): path: bad percent-encoding",
		"docs/a.md:4: (../README.md#nope): anchor: no heading of README.md has the slug nope",
		"docs/a.md:4: (#%ZZ): anchor: bad percent-encoding",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("problems =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if n != 21 {
		t.Errorf("checked %d relative links, want 21", n)
	}
}

// A NUL-delimited list, as `git ls-files -z` and linux-check.sh write it:
// names with spaces or newlines stay whole, and empty names (the final
// terminator, or none at all) are no files.
func TestFileSet(t *testing.T) {
	cases := map[string]map[string]bool{
		"":                               {},
		"a.md\x00":                       {"a.md": true},
		"a.md\x00dir/b c.md\x00x\ny\x00": {"a.md": true, "dir/b c.md": true, "x\ny": true},
		"a.md\x00a.md":                   {"a.md": true},
	}
	for in, want := range cases {
		if got := fileSet([]byte(in)); !reflect.DeepEqual(got, want) {
			t.Errorf("fileSet(%q) = %v, want %v", in, got, want)
		}
	}
}
