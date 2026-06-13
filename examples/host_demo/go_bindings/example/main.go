// Go example for a {.ffiHost.} host callback.
//
// `fetchToken` is implemented HERE (the Go app) and registered with
// SetFetchToken. When we call UseToken, the Nim library calls back into this Go
// closure for a token — the closure runs on a goroutine the generated wrapper
// spawns (never blocking the FFI thread) and answers via host_complete.
package main

import (
	"fmt"
	"log"

	hd "host_demo"
)

func main() {
	node, err := hd.NewHost_demo()
	if err != nil {
		log.Fatalf("create: %v", err)
	}
	defer node.Destroy()

	// The host's implementation of the {.ffiHost.} fetchToken.
	node.SetFetchToken(func(key string) (string, error) {
		return "TOK-" + key, nil
	})

	res, err := node.UseToken("session")
	if err != nil {
		log.Fatalf("useToken: %v", err)
	}
	fmt.Printf("result: %s\n", res)
	if res != "token[TOK-session]" {
		log.Fatalf("unexpected result: %q", res)
	}
	fmt.Println("OK")
}
