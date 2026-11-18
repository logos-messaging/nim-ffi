        let bytes = if args.is_null() || len == 0 {
            &[][..]
        } else {
            slice::from_raw_parts(args, len)
        };
        match decode_cbor::<{{ARGS}}>(bytes) {
            Ok(a) => (b.f)(call, a),
            Err(e) => {
                let _ = call.fail(&format!("reverse args decode failed: {e}"));
            }
        }
