// Baseline: Go net/http serving GET / with "Hello, World!".
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("Hello, World!"))
	})
	// A port the kernel picks; bench.sh reads it from the "listening on" line.
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("listening on", l.Addr())
	fmt.Println("ready") // bench.sh waits for this line
	http.Serve(l, nil)
}
