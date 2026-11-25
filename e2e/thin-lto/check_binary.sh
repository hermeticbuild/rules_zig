#!/usr/bin/env bash
set -euo pipefail

objdump=$1
binary=$2
expected=$3
entry=$("$objdump" --disassemble-symbols=cpp_entry "$binary")

if ! grep -q '<cpp_entry>:' <<< "$entry"; then
    printf '%s\n' 'The executable has no cpp_entry symbol.' >&2
    exit 1
fi

actual=no-call
if grep -Eq '<zig_eval([.$@+][^>]*)?>' <<< "$entry"; then
    actual=call
fi

if [[ $actual != "$expected" ]]; then
    printf 'Expected %s to zig_eval, got %s\n%s\n' "$expected" "$actual" "$entry" >&2
    exit 1
fi
