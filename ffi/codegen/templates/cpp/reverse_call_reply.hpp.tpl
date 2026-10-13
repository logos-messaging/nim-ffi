        bool reply(const {{REPLY_TYPE}}& r) const {
            auto enc = encodeCborFFI(r);
            if (enc.isErr()) return fail(enc.error());
            const auto& b = enc.value();
            return {{LIB}}_reverse_reply(ctx, id, 0, b.data(), b.size()) == 0;
        }
