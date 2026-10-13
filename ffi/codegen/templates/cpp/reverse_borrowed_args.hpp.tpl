    // `fn` runs on a reverse worker. Its arguments are borrowed: valid only until
    // `fn` returns, so a deferred reply must copy what it needs.
