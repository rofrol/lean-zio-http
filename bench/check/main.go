// End-to-end checks of a running server over real sockets: each case sends raw
// bytes on a fresh connection and reads the responses it expects, then checks
// whether the server closed the connection when it should. Exit status 1 when
// any case fails. A server that never answers keeps the check from ending;
// that is a failure to trace.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
)

type exchange struct {
	method string // of the request this response answers (HEAD has no body)
	status int
}

type check struct {
	name    string
	request string
	answers []exchange
	closes  bool // the server closes the connection after the last answer
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8083", "server address")
	flag.Parse()
	maxHead := "GET / HTTP/1.1\r\nHost: a\r\nX: "
	maxHead += strings.Repeat("a", 8192-len(maxHead)) + "\r\n\r\n"
	maxReq := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 8192\r\nX: "
	maxReq += strings.Repeat("a", 8192-len(maxReq)) + "\r\n\r\n" + strings.Repeat("a", 8192)
	checks := []check{
		{"GET /", "GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n", []exchange{{"GET", 200}}, true},
		{"HEAD /", "HEAD / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n", []exchange{{"HEAD", 200}}, true},
		{"pipelined POST and GET", "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhelloGET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n",
			[]exchange{{"POST", 404}, {"GET", 200}}, true},
		{"keep-alive stays open", "GET / HTTP/1.1\r\nHost: a\r\n\r\n", []exchange{{"GET", 200}}, false},
		{"missing Host", "GET / HTTP/1.1\r\n\r\n", []exchange{{"GET", 400}}, true},
		{"chunked", "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", []exchange{{"POST", 501}}, true},
		{"HTTP/1.0", "GET / HTTP/1.0\r\n\r\n", []exchange{{"GET", 200}}, true},
		{"head of exactly the limit", maxHead, []exchange{{"GET", 200}}, false},
		{"largest request fits the loop's buffer", maxReq, []exchange{{"POST", 404}}, false},
		{"head over the limit", "GET / HTTP/1.1\r\nHost: a\r\nX: " + strings.Repeat("a", 9000) + "\r\n\r\n", []exchange{{"GET", 431}}, true},
	}
	failed := 0
	for _, c := range checks {
		if err := run(*addr, c); err != nil {
			fmt.Printf("FAIL %s: %v\n", c.name, err)
			failed++
		}
	}
	fmt.Printf("%d of %d checks failed\n", failed, len(checks))
	if failed > 0 {
		os.Exit(1)
	}
}

func run(addr string, c check) error {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := io.WriteString(conn, c.request); err != nil {
		return err
	}
	r := bufio.NewReader(conn)
	for i, want := range c.answers {
		resp, err := http.ReadResponse(r, &http.Request{Method: want.method})
		if err != nil {
			return fmt.Errorf("answer %d: %v", i, err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode != want.status {
			return fmt.Errorf("answer %d: status %d, want %d", i, resp.StatusCode, want.status)
		}
		if resp.Header.Get("Date") == "" || resp.Header.Get("Content-Length") == "" {
			return fmt.Errorf("answer %d: missing Date or Content-Length", i)
		}
	}
	if c.closes {
		// The server must end the stream: a read returns EOF, not more bytes.
		if n, err := r.Read(make([]byte, 1)); err != io.EOF {
			return fmt.Errorf("connection not closed (read %d bytes, err %v)", n, err)
		}
		return nil
	}
	// Still open: a second request on it is answered.
	if _, err := io.WriteString(conn, "GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"); err != nil {
		return err
	}
	resp, err := http.ReadResponse(r, &http.Request{Method: "GET"})
	if err != nil {
		return fmt.Errorf("follow-up on a kept-alive connection: %v", err)
	}
	resp.Body.Close()
	return nil
}
