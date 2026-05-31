// Native (same-process) Go example for the timer library.
//
// The generated cgo package marshals each {.ffi.} struct param into its flat
// C-POD form and passes it to the native ABI by value — so methods that take
// structs, sequences and optionals (Echo, Complex, Schedule) are now callable
// directly with idiomatic Go types. Struct-returning calls hand back a typed Go
// struct too (read out of the C-POD inside the result callback).
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

	// Native typed event: Echo fires onEchoFired(EchoEvent) inside the library.
	// Register a typed handler — the payload arrives as a Go struct, no CBOR.
	events := make(chan timer.EchoEvent, 4)
	node.OnEchoFired(func(e timer.EchoEvent) { events <- e })

	// Struct param + typed struct return: EchoResponse { Echoed; TimerName }.
	if resp, err := node.Echo(timer.EchoRequest{Message: "hello from Go", DelayMs: 5}); err != nil {
		log.Printf("echo: %v", err)
	} else {
		fmt.Printf("echo: echoed=%q timerName=%q\n", resp.Echoed, resp.TimerName)
	}
	select {
	case e := <-events:
		fmt.Printf("event OnEchoFired: message=%q echoCount=%d\n", e.Message, e.EchoCount)
	default:
		fmt.Println("event OnEchoFired: (none received)")
	}

	// Deeply nested param + typed return: slice of structs, slice of strings,
	// two optionals in; ComplexResponse { Summary; ItemCount; HasNote } out.
	cresp, err := node.Complex(timer.ComplexRequest{
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
		fmt.Printf("complex: itemCount=%d hasNote=%v summary=%q\n",
			cresp.ItemCount, cresp.HasNote, cresp.Summary)
	}

	// Multiple struct params at once; ScheduleResult out.
	sresp, err := node.Schedule(
		timer.JobSpec{Name: "nightly", Payload: []string{"x"}, Priority: 5},
		timer.RetryPolicy{MaxAttempts: 3, BackoffMs: 100, RetryOn: []string{"timeout"}},
		timer.ScheduleConfig{StartAtMs: 1000, IntervalMs: 5000, Jitter: intp(50)},
	)
	if err != nil {
		log.Printf("schedule: %v", err)
	} else {
		fmt.Printf("schedule: jobId=%q willRunCount=%d\n", sresp.JobId, sresp.WillRunCount)
	}

	fmt.Println("done")
}
