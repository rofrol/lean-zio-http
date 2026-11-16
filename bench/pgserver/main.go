// Baseline for lsrv-db: Go net/http with a pgx pool, serving GET /db?id=N with
// the same query and the same JSON as App.Db, on 127.0.0.1:8082. pgx prepares
// the statement once per connection and executes it by name after that, as
// lsrv-db's pool does (zig/src/glue.c, ekk_pg).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	conninfo := flag.String("pg", "", "libpq conninfo")
	conns := flag.Int("conns", 32, "the pool's size")
	flag.Parse()
	cfg, err := pgxpool.ParseConfig(*conninfo)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	cfg.MaxConns = int32(*conns)
	cfg.MinConns = int32(*conns)
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	http.HandleFunc("/db", func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.Atoi(r.URL.Query().Get("id"))
		if err != nil {
			http.Error(w, "bad id", 400)
			return
		}
		var i, n int32
		err = pool.QueryRow(r.Context(), "SELECT id, randomnumber FROM world WHERE id = $1", id).Scan(&i, &n)
		if errors.Is(err, pgx.ErrNoRows) {
			http.Error(w, "no such row", 404)
			return
		} else if err != nil {
			http.Error(w, "database error", 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"id":%d,"randomNumber":%d}`, i, n)
	})
	l, err := net.Listen("tcp", "127.0.0.1:8082")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("ready") // bench.sh waits for this line
	http.Serve(l, nil)
}
