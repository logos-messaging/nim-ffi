    // `{.ffiStatic.}` replies arrive on the library's static context, which has
    // one pump per process, started by the first static call.
    static Result<std::shared_ptr<NimFfiPump>> staticPump_() {
        return staticPumpHolder_().acquire(&{{LIB}}_static_ctx, &{{LIB}}_poll, &{{LIB}}_last_error);
    }
    // Never destroyed: no static destructor may race the pump thread at exit.
    static NimFfiStaticPump& staticPumpHolder_() {
        static NimFfiStaticPump* holder = new NimFfiStaticPump();
        return *holder;
    }
