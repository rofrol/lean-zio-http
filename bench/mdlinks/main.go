// mdlinks checks the relative links of every git-tracked Markdown file: the
// path a link names must be a tracked file or a directory holding one, and a
// fragment on a Markdown target (or on the same file) must be the GitHub
// heading slug of one of its headings, duplicate headings' "-1", "-2"
// suffixes included. Other targets are checked only for existence; links with
// a scheme (https:, mailto:) are not checked, and nothing goes to the
// network. Links are inline ([text](dest), images too) and reference
// definitions ([label]: dest); fenced and indented code blocks, inline code
// and HTML comments are skipped. It runs from the repository's root (check.sh
// runs it there), prints each broken link with its file, line, destination
// and whether the path or the anchor failed, and exits 1 when any is broken.
//
// The files it reads and resolves links against are `git ls-files -z`'s.
// Where the tree is no git repository (linux-check.sh's copy in a
// container), MDLINKS_FILES names a file holding them instead, NUL-delimited
// and relative to the root, as `git ls-files -z` prints them: linux-check.sh
// gives it the list it built the copy from, which also holds the untracked
// files git does not ignore: there they count as tracked.
//
// It parses the subset of CommonMark these documents use, not all of it.
// Known differences, none met in this repository's documents: headings in
// block quotes or list items, and HTML anchors (<a id=...>), are not targets;
// reference definitions inside block quotes are not read; list items are told
// apart by their markers only, not by their content's indentation, so an
// indented code block inside an item is read as prose and a paragraph
// indented one to three spaces after a list stays in it; reference links are
// not resolved, so one inside a link's text does not keep the outer brackets
// from being a link; in a heading, a reference link ([text][label]) gives its
// text whether or not the label is defined, and "_" runs pair as emphasis
// without regard to their lengths or to link boundaries, and "<!--" ... "-->"
// is a comment even when its ends lie in two link titles; lowercasing is Go's
// (no Unicode special casing, so "İ" gives "i"); the slug of a heading
// spanning lines (setext) drops the line break, as github-slugger drops
// control characters (not checked against GitHub). A difference makes the
// check report a link that GitHub resolves or pass one it does not; the first
// shows at once, the second is the risk.
package main

import (
	"bytes"
	"fmt"
	"html"
	"net/url"
	"os"
	"os/exec"
	"path"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// problem is one broken link: what is reported for it.
type problem struct {
	file string
	line int
	dest string
	what string
}

func (p problem) String() string {
	return fmt.Sprintf("%s:%d: (%s): %s", p.file, p.line, p.dest, p.what)
}

// link is a destination found in a document, with its 1-based line.
type link struct {
	line int
	dest string
}

// block is a paragraph or a heading: prose in which links are looked for.
// It holds no blank line. line is the 1-based line it starts on.
type block struct {
	line int
	text string
}

func main() {
	var out []byte
	var err error
	if list := os.Getenv("MDLINKS_FILES"); list != "" {
		out, err = os.ReadFile(list)
	} else if out, err = exec.Command("git", "ls-files", "-z").Output(); err != nil {
		err = fmt.Errorf("git ls-files: %w", err)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "mdlinks:", err)
		os.Exit(2)
	}
	tracked := fileSet(out)
	docs := map[string]string{}
	for f := range tracked {
		if !strings.HasSuffix(f, ".md") {
			continue
		}
		b, err := os.ReadFile(f)
		if os.IsNotExist(err) {
			delete(tracked, f) // deleted in the working tree: a link to it is broken
			continue
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "mdlinks:", err)
			os.Exit(2)
		}
		docs[f] = string(b)
	}
	problems, links := check(docs, tracked)
	for _, p := range problems {
		fmt.Println(p)
	}
	if len(problems) > 0 {
		fmt.Printf("mdlinks: %d of %d relative links in %d Markdown files are broken\n", len(problems), links, len(docs))
		os.Exit(1)
	}
	fmt.Printf("mdlinks: %d relative links in %d Markdown files resolve\n", links, len(docs))
}

// fileSet is the set of paths in a NUL-delimited list.
func fileSet(list []byte) map[string]bool {
	set := map[string]bool{}
	for _, f := range strings.Split(string(list), "\x00") {
		if f != "" {
			set[f] = true
		}
	}
	return set
}

// check returns the broken relative links of docs (path to content) and the
// number of relative links checked. tracked holds every tracked file's path.
func check(docs map[string]string, tracked map[string]bool) ([]problem, int) {
	dirs := map[string]bool{}
	for f := range tracked {
		for d := path.Dir(f); d != "."; d = path.Dir(d) {
			dirs[d] = true
		}
	}
	anchors := map[string]map[string]bool{}
	found := map[string][]link{}
	files := make([]string, 0, len(docs))
	for f, text := range docs {
		hs, bs := scan(text)
		anchors[f] = slugs(hs)
		for _, b := range bs {
			found[f] = append(found[f], links(b)...)
		}
		files = append(files, f)
	}
	sort.Strings(files)
	var problems []problem
	n := 0
	for _, f := range files {
		for _, l := range found[f] {
			what, relative := resolve(f, l.dest, tracked, dirs, anchors)
			if !relative {
				continue
			}
			n++
			if what != "" {
				problems = append(problems, problem{f, l.line, l.dest, what})
			}
		}
	}
	return problems, n
}

var scheme = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9+.-]*:`)

// resolve checks one destination found in file from. It returns what failed
// ("" when nothing did) and whether the destination is a relative link at all.
func resolve(from, dest string, tracked, dirs map[string]bool, anchors map[string]map[string]bool) (string, bool) {
	if dest == "" || scheme.MatchString(dest) || strings.HasPrefix(dest, "//") {
		return "", false
	}
	p, frag, _ := strings.Cut(dest, "#")
	p, _, _ = strings.Cut(p, "?")
	p, err := url.PathUnescape(p)
	if err != nil {
		return "path: bad percent-encoding", true
	}
	target := from
	if p != "" {
		if strings.HasPrefix(p, "/") {
			target = path.Clean(strings.TrimPrefix(p, "/"))
		} else {
			target = path.Join(path.Dir(from), p)
		}
		switch {
		case target == ".." || strings.HasPrefix(target, "../"):
			return "path: " + target + " is outside the repository", true
		case strings.HasSuffix(p, "/") && tracked[target]:
			return "path: " + target + " is a file, not a directory", true
		case !tracked[target] && !dirs[target] && target != ".":
			return "path: " + target + " is not a tracked file or directory", true
		}
	}
	// An empty fragment ("#") names the top of the page.
	if frag == "" || !strings.HasSuffix(target, ".md") || !tracked[target] {
		return "", true
	}
	f, err := url.PathUnescape(frag)
	if err != nil {
		return "anchor: bad percent-encoding", true
	}
	if !anchors[target][f] {
		return "anchor: no heading of " + target + " has the slug " + f, true
	}
	return "", true
}

// slugs returns the GitHub anchors of the headings hs, in document order:
// github-slugger's, where a repeated slug gets "-1", "-2", ... appended.
func slugs(hs []string) map[string]bool {
	seen := map[string]bool{}
	count := map[string]int{}
	for _, h := range hs {
		base := slug(h)
		s := base
		for seen[s] {
			count[base]++
			s = fmt.Sprintf("%s-%d", base, count[base])
		}
		seen[s] = true
	}
	return seen
}

// slug is github-slugger's slug of a heading's text: lowercased, every
// character but letters, marks, numbers, connector punctuation (_), hyphens
// and spaces removed, and each space turned into a hyphen.
func slug(text string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(text) {
		switch {
		case r == ' ':
			b.WriteByte('-')
		case r == '-' || unicode.IsLetter(r) || unicode.IsMark(r) || unicode.IsNumber(r) || unicode.Is(unicode.Pc, r):
			b.WriteRune(r)
		}
	}
	return b.String()
}

var (
	atx           = regexp.MustCompile(`^ {0,3}#{1,6}(?:[ \t]+(.*))?$`)
	atxClosing    = regexp.MustCompile(`(^|[ \t]+)#+$`)
	setext        = regexp.MustCompile(`^ {0,3}(=+|-+)[ \t]*$`)
	thematicBreak = regexp.MustCompile(`^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$`)
	fence         = regexp.MustCompile("^(`{3,}|~{3,})(.*)$")
	listItem      = regexp.MustCompile(`^ {0,3}([-*+]|[0-9]{1,9}[.)])([ \t]+|$)`)
	refDef        = regexp.MustCompile(`^ {0,3}\[((?:[^\]\\]|\\.)+)\]:`)
	htmlTag       = regexp.MustCompile(`</?[A-Za-z][^>]*>`)
	autolink      = regexp.MustCompile(`<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\x00-\x20]*)>`)
	tabsToSpaces  = strings.NewReplacer("\t", "    ")
)

// scan returns the text of the headings of a document, in order, and its
// blocks of prose: paragraphs (a list item starts a new one, its marker
// removed) and headings, without fenced or indented code blocks, thematic
// breaks or HTML comment blocks.
func scan(text string) ([]string, []block) {
	var headings []string
	var blocks []block
	var para []string // the current paragraph's lines
	paraStart, paraInList := 0, false
	flush := func() {
		if para != nil {
			blocks = append(blocks, block{paraStart, strings.Join(para, "\n")})
			para = nil
		}
	}
	inList := false
	fenceMark := "" // the opening fence of the fenced code block we are in
	// fenceCol is the column of the content its lines must keep: 0 at the
	// top level, the list item's content column inside one.
	fenceCol := 0
	itemCol := 0 // the content column of the last list item
	inComment := false
	prevBlankOrCode := true // whether an indented code block may start here
	for i, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		trimmed := strings.TrimLeft(line, " \t")
		indent := len(tabsToSpaces.Replace(line)) - len(strings.TrimLeft(tabsToSpaces.Replace(line), " "))
		if fenceMark != "" {
			// A fence closes at up to three spaces past its content column;
			// a line left of that column ends the list item and its fence.
			if m := fence.FindStringSubmatch(trimmed); m != nil && indent >= fenceCol && indent-fenceCol <= 3 &&
				m[1][0] == fenceMark[0] && len(m[1]) >= len(fenceMark) && strings.TrimSpace(m[2]) == "" {
				fenceMark = ""
				continue
			}
			if trimmed == "" || indent >= fenceCol {
				continue
			}
			fenceMark = ""
		}
		if inComment {
			inComment = !strings.Contains(line, "-->")
			continue
		}
		if trimmed == "" {
			flush()
			prevBlankOrCode = true
			continue
		}
		if indent >= 4 && prevBlankOrCode && !inList {
			continue // an indented code block
		}
		item := listItem.FindStringIndex(line)
		if thematicBreak.MatchString(line) {
			item = nil // "- - -" and "* * *" are no list items
		}
		// An unindented line that is no list item ends a list when it
		// starts a paragraph or a block that interrupts one.
		if indent == 0 && item == nil && (para == nil || fence.MatchString(trimmed) ||
			strings.HasPrefix(trimmed, "<!--") || atx.MatchString(line) || thematicBreak.MatchString(line)) {
			inList = false
		}
		// A fence opens a code block at up to three spaces of indentation,
		// after a list item's marker, or anywhere inside a list.
		body := ""
		switch {
		case item != nil:
			body = line[item[1]:]
		case indent <= 3 || inList:
			body = trimmed
		}
		if m := fence.FindStringSubmatch(body); m != nil && !(m[1][0] == '`' && strings.Contains(m[2], "`")) {
			flush()
			fenceMark = m[1]
			switch {
			case item != nil:
				inList, itemCol, fenceCol = true, item[1], item[1]
			case inList:
				fenceCol = itemCol
			default:
				fenceCol = 0
			}
			prevBlankOrCode = true
			continue
		}
		if indent <= 3 && strings.HasPrefix(trimmed, "<!--") {
			flush()
			inComment = !strings.Contains(trimmed[4:], "-->")
			prevBlankOrCode = true
			continue
		}
		if m := atx.FindStringSubmatch(line); m != nil {
			flush()
			headings = append(headings, inlineText(atxClosing.ReplaceAllString(strings.TrimSpace(m[1]), "")))
			blocks = append(blocks, block{i + 1, line})
			prevBlankOrCode = true
			continue
		}
		// A setext underline after a paragraph that is not only reference
		// definitions makes it a heading; otherwise a line of "-", "*" or
		// "_" is a thematic break.
		if setext.MatchString(line) && para != nil && !paraInList {
			text := strings.Join(para, "\n")
			if _, end := refDefs(block{paraStart, text}); end < len(text) {
				headings = append(headings, inlineText(strings.TrimSpace(text[end:])))
				flush()
				prevBlankOrCode = true
				continue
			}
		}
		if thematicBreak.MatchString(line) {
			flush()
			prevBlankOrCode = true
			continue
		}
		prevBlankOrCode = false
		if item != nil {
			flush()
			inList, itemCol = true, item[1]
			line = line[item[1]:]
		}
		if para == nil {
			paraStart, paraInList = i+1, inList
		}
		para = append(para, strings.TrimLeft(line, " \t"))
	}
	flush()
	return headings, blocks
}

// links returns the link destinations of a block: the reference definitions
// it starts with, then its inline links and images, outside code spans and
// HTML comments. A "](" is a link only when its "]" closes a "[" of the block
// and a destination, an optional title and ")" follow; a link inside a
// link's text is none.
func links(bl block) []link {
	b := []byte(bl.text)
	out, i := refDefs(bl)
	lineAt := func(off int) int { return bl.line + bytes.Count(b[:off], []byte("\n")) }
	// The "[" not yet closed; one before a link is no longer active: its
	// "]" is text.
	type opener struct {
		at     int
		active bool
	}
	var openers []opener
	for ; i < len(b); i++ {
		switch {
		case b[i] == '\\' && i+1 < len(b) && isASCIIPunct(b[i+1]):
			i++
		case b[i] == '`':
			n := run(b, i, '`')
			if end := closingRun(b, i+n, n); end >= 0 {
				i = end + n - 1
			} else {
				i += n - 1
			}
		case bytes.HasPrefix(b[i:], []byte("<!--")):
			if end := bytes.Index(b[i+4:], []byte("-->")); end >= 0 {
				i += 4 + end + 2
			}
		case b[i] == '[':
			openers = append(openers, opener{i, true})
		case b[i] == ']' && len(openers) > 0:
			open := openers[len(openers)-1]
			openers = openers[:len(openers)-1]
			if !open.active || i+1 >= len(b) || b[i+1] != '(' {
				continue
			}
			d, end, ok := destination(b, i+2)
			if !ok {
				continue
			}
			close, ok := linkEnd(b, end)
			if !ok {
				continue
			}
			out = append(out, link{lineAt(i), d})
			if !image(b, open.at) {
				// A link's text holds no other link: the "[" before it
				// open no link now; an image's "![" still may.
				for k := range openers {
					if !image(b, openers[k].at) {
						openers[k].active = false
					}
				}
			}
			i = close
		}
	}
	return out
}

// refDefs returns the reference definitions a block starts with, one after
// another, and the offset after the last.
func refDefs(bl block) ([]link, int) {
	b := []byte(bl.text)
	var out []link
	start := 0
	for start < len(b) {
		m := refDef.FindIndex(b[start:])
		if m == nil {
			break
		}
		d, end, ok := destination(b, start+m[1])
		if !ok || d == "" && b[end-1] != '>' {
			break // no destination; only <> is an empty one
		}
		end, ok = refDefEnd(b, end)
		if !ok {
			break
		}
		out = append(out, link{bl.line + bytes.Count(b[:start], []byte("\n")), d})
		start = end
	}
	return out, start
}

// image reports whether the "[" at open starts an image ("![").
func image(b []byte, open int) bool {
	return open > 0 && b[open-1] == '!' && !escaped(b, open-1)
}

// escaped reports whether b[j] follows an odd number of backslashes.
func escaped(b []byte, j int) bool {
	n := 0
	for k := j - 1; k >= 0 && b[k] == '\\'; k-- {
		n++
	}
	return n%2 == 1
}

// skipSpace skips spaces and tabs and at most one newline from i. It returns
// the offset after them and whether there were any.
func skipSpace(b []byte, i int) (int, bool) {
	from := i
	for i < len(b) && (b[i] == ' ' || b[i] == '\t') {
		i++
	}
	if i < len(b) && b[i] == '\n' {
		i++
		for i < len(b) && (b[i] == ' ' || b[i] == '\t') {
			i++
		}
	}
	return i, i > from
}

// title parses a link title ("...", '...' or (...)) at i, returning the
// offset after it.
func title(b []byte, i int) (int, bool) {
	if i >= len(b) {
		return i, false
	}
	closer := map[byte]byte{'"': '"', '\'': '\'', '(': ')'}[b[i]]
	if closer == 0 {
		return i, false
	}
	for j := i + 1; j < len(b); j++ {
		if b[j] == '\\' {
			j++
			continue
		}
		if b[j] == closer {
			return j + 1, true
		}
		if closer == ')' && b[j] == '(' {
			return i, false
		}
	}
	return i, false
}

// linkEnd parses what follows an inline link's destination at i: an optional
// title after whitespace, then ")". It returns the offset of the ")".
func linkEnd(b []byte, i int) (int, bool) {
	j, space := skipSpace(b, i)
	if j < len(b) && b[j] == ')' {
		return j, true
	}
	if !space {
		return i, false
	}
	j, ok := title(b, j)
	if !ok {
		return i, false
	}
	j, _ = skipSpace(b, j)
	if j < len(b) && b[j] == ')' {
		return j, true
	}
	return i, false
}

// refDefEnd parses what follows a reference definition's destination at i:
// an optional title after whitespace (on the same line or the next), then
// the end of the line. It returns the offset of the next line.
func refDefEnd(b []byte, i int) (int, bool) {
	eol := func(j int) (int, bool) {
		for j < len(b) && (b[j] == ' ' || b[j] == '\t') {
			j++
		}
		if j == len(b) {
			return j, true
		}
		if b[j] == '\n' {
			return j + 1, true
		}
		return j, false
	}
	next, atEOL := eol(i)
	if j, space := skipSpace(b, i); space {
		if j, ok := title(b, j); ok {
			if j, ok := eol(j); ok {
				return j, true
			}
		}
	}
	return next, atEOL
}

// destination parses a link destination starting at i (after "(" or "]:"),
// with the spaces and at most one newline before it: <...> or a run without
// spaces whose parentheses balance. Backslash escapes of ASCII punctuation
// are removed and entities decoded. It returns the destination, the offset
// after it, and false when there is none.
func destination(b []byte, i int) (string, int, bool) {
	i, _ = skipSpace(b, i)
	var d strings.Builder
	if i < len(b) && b[i] == '<' {
		for i++; i < len(b); i++ {
			switch {
			case b[i] == '\n' || b[i] == '<':
				return "", i, false
			case b[i] == '>':
				return html.UnescapeString(d.String()), i + 1, true
			case b[i] == '\\' && i+1 < len(b) && isASCIIPunct(b[i+1]):
				i++
				d.WriteString(literal(b[i]))
				continue
			}
			d.WriteByte(b[i])
		}
		return "", i, false
	}
	depth := 0
	for ; i < len(b); i++ {
		c := b[i]
		if c == '\\' && i+1 < len(b) && isASCIIPunct(b[i+1]) {
			i++
			d.WriteString(literal(b[i]))
			continue
		}
		if c <= ' ' {
			break
		}
		if c == '(' {
			depth++
		} else if c == ')' {
			if depth == 0 {
				break
			}
			depth--
		}
		d.WriteByte(c)
	}
	if depth != 0 {
		return "", i, false
	}
	return html.UnescapeString(d.String()), i, true
}

// literal is an escaped character as it goes into a destination before its
// entities are decoded: an escaped "&" starts no entity.
func literal(c byte) string {
	if c == '&' {
		return "&amp;"
	}
	return string(c)
}

func isASCIIPunct(c byte) bool {
	return c < 0x80 && unicode.IsPunct(rune(c)) || strings.IndexByte("$+<=>^`|~", c) >= 0
}

// run is the length of the run of c at i.
func run(b []byte, i int, c byte) int {
	n := 0
	for i+n < len(b) && b[i+n] == c {
		n++
	}
	return n
}

// closingRun is the offset of the next run of exactly n backticks from i, or -1.
func closingRun(b []byte, i, n int) int {
	for j := i; j < len(b); j++ {
		if b[j] == '`' {
			m := run(b, j, '`')
			if m == n {
				return j
			}
			j += m - 1
		}
	}
	return -1
}

// inlineText is the text GitHub renders for a heading's inline Markdown, as
// far as its slug depends on it: code spans keep their content verbatim,
// links their text, an image none, autolinks their URL; outside code, HTML
// comments and tags go,
// entities and backslash escapes are decoded, and the "_" runs that pair up
// as emphasis go ("*" and "~" need no such care: the slug drops them).
func inlineText(s string) string {
	b := stripComments([]byte(s))
	s = string(b)
	drop := emphasis(b)
	var out, lit strings.Builder
	flush := func() {
		t := autolink.ReplaceAllString(lit.String(), "$1")
		out.WriteString(html.UnescapeString(htmlTag.ReplaceAllString(t, "")))
		lit.Reset()
	}
	for i := 0; i < len(b); i++ {
		c := b[i]
		switch {
		case c == '\\' && i+1 < len(b) && isASCIIPunct(b[i+1]):
			flush()
			i++
			out.WriteByte(b[i])
		case c == '`':
			n := run(b, i, '`')
			if end := closingRun(b, i+n, n); end >= 0 {
				code := s[i+n : end]
				if len(code) > 1 && code[0] == ' ' && code[len(code)-1] == ' ' && strings.TrimSpace(code) != "" {
					code = code[1 : len(code)-1]
				}
				flush()
				out.WriteString(code)
				i = end + n - 1
			} else {
				lit.WriteString(s[i : i+n])
				i += n - 1
			}
		case c == '!' && i+1 < len(b) && b[i+1] == '[':
			if _, next, ok := inlineLink(b, i+1); ok {
				i = next - 1 // an image renders no text
			} else {
				lit.WriteByte(c)
			}
		case c == '[':
			if text, next, ok := inlineLink(b, i); ok {
				flush()
				out.WriteString(inlineText(text))
				i = next - 1
			} else {
				lit.WriteByte(c)
			}
		case c == '_' && drop[i]:
			i += run(b, i, '_') - 1
		default:
			lit.WriteByte(c)
		}
	}
	flush()
	return out.String()
}

// stripComments removes the closed HTML comments of a heading that are not
// inside a code span, whichever of the two starts first winning.
func stripComments(b []byte) []byte {
	var out []byte
	for i := 0; i < len(b); i++ {
		switch {
		case b[i] == '\\' && i+1 < len(b):
			out = append(out, b[i], b[i+1])
			i++
		case b[i] == '`':
			n := run(b, i, '`')
			end := closingRun(b, i+n, n)
			if end < 0 {
				end = i
			}
			out = append(out, b[i:end+n]...)
			i = end + n - 1
		case bytes.HasPrefix(b[i:], []byte("<!--")) && bytes.Contains(b[i+4:], []byte("-->")):
			i += 4 + bytes.Index(b[i+4:], []byte("-->")) + 2
		default:
			out = append(out, b[i])
		}
	}
	return out
}

// emphasis returns the offsets of the "_" runs of s that pair up as emphasis
// delimiters outside code spans: a run that can open (a non-space follows it,
// no word character precedes it) and a later one that can close (a non-space
// precedes it, no word character follows it), matched innermost first.
func emphasis(b []byte) map[int]bool {
	drop := map[int]bool{}
	var openers []int
	space := func(c byte) bool { return c == ' ' || c == '\t' || c == '\n' }
	for i := 0; i < len(b); i++ {
		switch {
		case b[i] == '\\':
			i++
		case b[i] == '`':
			n := run(b, i, '`')
			if end := closingRun(b, i+n, n); end >= 0 {
				i = end + n - 1
			} else {
				i += n - 1
			}
		case b[i] == '_':
			n := run(b, i, '_')
			before := i > 0 && isWordByte(b[i-1])
			after := i+n < len(b) && isWordByte(b[i+n])
			canOpen := i+n < len(b) && !space(b[i+n]) && !before
			canClose := i > 0 && !space(b[i-1]) && !after
			if canClose && len(openers) > 0 {
				drop[openers[len(openers)-1]] = true
				drop[i] = true
				openers = openers[:len(openers)-1]
			} else if canOpen {
				openers = append(openers, i)
			}
			i += n - 1
		}
	}
	return drop
}

// inlineLink parses [text](dest ...) or [text][label] at i, returning the
// text and the offset after the link.
func inlineLink(b []byte, i int) (string, int, bool) {
	depth := 0
	for j := i; j < len(b); j++ {
		switch b[j] {
		case '\\':
			j++
		case '`':
			n := run(b, j, '`')
			if end := closingRun(b, j+n, n); end >= 0 {
				j = end + n - 1
			} else {
				j += n - 1
			}
		case '[':
			depth++
		case ']':
			depth--
			if depth > 0 {
				continue
			}
			text := string(b[i+1 : j])
			if j+1 < len(b) && b[j+1] == '(' {
				if _, end, ok := destination(b, j+2); ok {
					if close, ok := linkEnd(b, end); ok {
						return text, close + 1, true
					}
				}
			}
			if j+1 < len(b) && b[j+1] == '[' {
				if k := bytes.IndexByte(b[j+1:], ']'); k >= 0 {
					return text, j + 1 + k + 1, true
				}
			}
			return "", 0, false
		}
	}
	return "", 0, false
}

func isWordByte(c byte) bool {
	return c >= 0x80 || c == '_' || unicode.IsLetter(rune(c)) || unicode.IsDigit(rune(c))
}
