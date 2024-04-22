# artemis's toml.lua

This is my toml parser/generator. It's hand-written in lua. It functions.


## what you should consider using instead of this

- [lebje/toml.lua](https://github.com/LebJe/toml.lua)
    - wrapper around [toml++](https://github.com/marzer/tomlplusplus/), a C++
      toml implementation
    - supports parsing/serialization
    - luarocks: [https://luarocks.org/modules/LebJe/toml](https://luarocks.org/modules/LebJe/toml)
- [vhyrro/toml-edit.lua](https://github.com/vhyrro/toml-edit.lua)
    - wrapper around rust's excellent `toml_edit` crate.
    - supports parsing/serialization
    - supports toml edits while preserving toml structure
    - luarocks: [https://luarocks.org/modules/neorg/toml-edit](https://luarocks.org/modules/neorg/toml-edit)

But both of those have a native dependency, and I wanted a pure-lua
implementation that supported serialization. So that's why this exists.


## usage

```
local toml = require('toml')

-- decode a toml string
local my_table = toml.decode(my_toml_string)

-- encode a table as toml
local my_generated_toml = toml.encode(my_table)
```


## things you should know

This file was written to serve my purposes, and may not serve yours. I've
mostly tested it with Cargo.toml / Cargo.lock files.


### implemented

- encoding, barely
  - it is syntactically valid but violates most toml style guides.
  - it will not look anything like the input, if you decode and then re-encode.
  - you can set a metatable on a lua table, with `moonrabbit_toml_table_type`
    set to either `array` or `table`. This will tell the encoder explicitly
    whether to encode it as a toml array or a toml table, rather than relying
    on my automatic decision.
- decoding, mostly.
  - decoded arrays/dicts are tagged with `moonrabbit_toml_table_type` to allow
    for decode/transform/encode while guaranteed preserving these data types.


### unimplemented

- time values
- good encoding
- structure-preserving edits

Also, it will be a little slow when processing large files.


## bugs

you can report them, and i might fix them.