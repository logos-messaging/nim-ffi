    /// Static calls still waiting fail with a "context closed" error, and a
    /// later static call starts over. Must not race a call in flight.
    static Result<void> shutdown() {
        // The static dispatch thread goes first: nothing polls a context being torn down.
        staticDispatcherHolder_().stop();
        if ({{LIB}}_shutdown() != 0) return Result<void>::err("{{LIB}}_shutdown: a context was left running");
        return Result<void>::ok();
    }
