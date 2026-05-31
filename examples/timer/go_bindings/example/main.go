// Native (same-process) Go example for the timer library.
//
// The generated cgo package marshals each {.ffi.} struct param into its flat
// C-POD form and passes it to the native ABI by value — so methods that take
// structs, sequences and optionals (Echo, Complex, Schedule) are now callable
// directly with idiomatic Go types. String-returning calls (Version) come back
// as a Go string; struct-returning calls deliver their CBOR encoding.
package main

import (
	"fmt"
	"log"

	timer "my_timer"
)

func strp(s string) *string { return &s }
func intp(i int64) *int64   { return &i }

func main() {
	// Construct with a TimerConfig struct.
	node, err := timer.NewMy_timer(timer.TimerConfig{Name: "go-native-demo"})
	if err != nil {
		log.Fatalf("create: %v", err)
	}
	defer node.Destroy()
	fmt.Println("created timer")

	// String return.
	if v, err := node.Version(); err == nil {
		fmt.Printf("version: %s\n", v)
	}

	// Struct param: EchoRequest { Message string; DelayMs int64 }.
	if _, err := node.Echo(timer.EchoRequest{Message: "hello from Go", DelayMs: 5}); err != nil {
		log.Printf("echo: %v", err)
	} else {
		fmt.Println("echo: ok (struct param round-tripped)")
	}

	// Deeply nested: slice of structs, slice of strings, two optionals.
	_, err = node.Complex(timer.ComplexRequest{
		Messages: []timer.EchoRequest{
			{Message: "one", DelayMs: 0},
			{Message: "two", DelayMs: 0},
		},
		Tags:    []string{"a", "b"},
		Note:    strp("a note"),
		Retries: intp(3),
	})
	if err != nil {
		log.Printf("complex: %v", err)
	} else {
		fmt.Println("complex: ok (seq/option graph deep-copied)")
	}

	// Multiple struct params at once.
	_, err = node.Schedule(
		timer.JobSpec{Name: "nightly", Payload: []string{"x"}, Priority: 5},
		timer.RetryPolicy{MaxAttempts: 3, BackoffMs: 100, RetryOn: []string{"timeout"}},
		timer.ScheduleConfig{StartAtMs: 1000, IntervalMs: 5000, Jitter: intp(50)},
	)
	if err != nil {
		log.Printf("schedule: %v", err)
	} else {
		fmt.Println("schedule: ok (three struct params in one call)")
	}

	fmt.Println("done")
}
