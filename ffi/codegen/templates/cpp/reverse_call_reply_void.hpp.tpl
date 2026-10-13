        bool reply() const {
            return {{LIB}}_reverse_reply(ctx, id, 0, nullptr, 0) == 0;
        }
