            {{ARGS}} a{};
            if (decodeReverseArgs_(args, len, a) != CborNoError) {
                call.failRaw("reverse args decode failed");
                return;
            }
            box->fn(call, a);
