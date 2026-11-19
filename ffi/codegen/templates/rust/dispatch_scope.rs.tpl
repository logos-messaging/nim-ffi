thread_local! {
    static DISPATCH_DEPTH: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static DEFERRED_LISTENERS: std::cell::RefCell<Vec<Box<dyn std::any::Any + Send>>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

struct DispatchScope;

impl DispatchScope {
    fn enter() -> Self {
        DISPATCH_DEPTH.with(|d| d.set(d.get() + 1));
        DispatchScope
    }
}

impl Drop for DispatchScope {
    fn drop(&mut self) {
        let depth = DISPATCH_DEPTH.with(|d| {
            d.set(d.get() - 1);
            d.get()
        });
        if depth == 0 {
            drop(DEFERRED_LISTENERS.with(|l| std::mem::take(&mut *l.borrow_mut())));
        }
    }
}
