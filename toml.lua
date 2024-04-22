--[[
a "fast enough" toml parser/encoder

https://toml.io/en/v1.0.0#

TODO, minor perf improvement maybe from replacing the sub(1, 1)s with byte() and
numeric comparison. idk how much.

TODO bigger perf improvements by not doing all the substrings and instead
keeping track of indexes. but its not needed for our uses right now

https://github.com/toml-lang/toml-test
]]

local m = {}

--[[
===============

whitespace

===============
]]

--[[
hot function, so we optimize the index searching a bit
]]
local function r_ignore(s)
	local wsend = 1
	repeat
		-- comment
		local l, r = s:find('^#[^\r\n]*', wsend)
		if l then
			wsend = r + 1
		else
			-- whitespace
			l, r = s:find('^[\t \r\n]+', wsend)
			if l then
				wsend = r + 1
			end
		end
	until not l

	return (wsend == 1 and s) or s:sub(wsend)
end

local function r_ignore_whitespace(s)
	local l, r = s:find('^[\t ]+')
	if not l then
		return s
	end

	return s:sub(r + 1)
end


local function do_string_substitutions(s)
	return s:gsub('\\([btnfr"\\uU])((.?.?.?.?).?.?.?.?)', function(esc, uuuu, uuuuuuuu)
		if esc == 'b' then
			return '\b'
		elseif esc == 't' then
			return '\t'
		elseif esc == 'n' then
			return '\n'
		elseif esc == 'f' then
			return '\f'
		elseif esc == 'r' then
			return '\r'
		elseif esc == '"' then
			return '"'
		elseif esc == '\\' then
			return '\\'
		elseif esc == 'u' then
			assert(#uuuu == 4, 'incomplete unicode codepoint')
			return utf8.char(tonumber(uuuu, 16))
		elseif esc == 'U' then
			assert(#uuuuuuuu == 8, 'incomplete unicode codepoint')
			return utf8.char(tonumber(uuuuuuuu, 16))
		end
	end)
end

--[[
multiline strings have the added substitution:

> When the last non-whitespace character on a line is an unescaped \, it will be
> trimmed along with all whitespace (including newlines) up to the next
> non-whitespace character or closing delimiter

We need to do this transformation *before* we translate \n literals and the
other escape sequences

The other pass we will do here is to normalize \r\n to \n.
> TOML parsers should feel free to normalize newline to whatever makes sense for
> their platform.
]]
local function do_multiline_string_newline_normalization(s)
	return s:gsub('\r\n', '\n')
end

local function do_multiline_string_substitutions(s)
	-- normalize newlines
	s = do_multiline_string_newline_normalization(s)

	-- do escaped-whitespace.
	-- A backslash, a newline character, and 0 or more whitespace after that.
	s = s:gsub('\\[\t \n][\t \r\n]*', '')

	-- do the rest of the normal transformations
	return do_string_substitutions(s)
end

--[[
============================

Key Parsing

This includes parsing string values, since they can be keys too

============================
]]
local function r_string(s)
	local prefix = s:sub(1,3)

	--[[
	dquote strings support escape-sequences, while squote strings do not. Like
	bash, basically.
	
	multiline strings have this quirk with opening them:
	> A newline immediately following the opening delimiter will be trimmed. All
	> other whitespace and newline characters remain intact.

	This is true of both dquote and squote multilines
	]]
	if prefix == '"""' then
		--[[
		multiline dquote string
		
		see squote string for additional commentary, this is just that but with
		escape sequences
		]]
		local _, inner_l = s:find('^"""\r?\n?')

		--[[
		Now find the end quotes. We start the search on top of the last char of
		the opener, so that it can fill in the role of "not-a-backslash" in the
		event of an empty dquote multiline
		]]
		local inner_r, r = s:find('[^\\]"""', inner_l)

		if inner_r == nil then
			error('missing terminated multiline double-quote\t' .. s)
		end

		-- In the event of an empty string, `l` will be > `r`, and give emptystr
		local inner = s:sub(inner_l + 1, inner_r)

		-- process escape sequences and do newline normalization
		inner = do_multiline_string_substitutions(inner)

		return inner, s:sub(r + 1)
	elseif prefix == "'''" then
		--[[
		multiline squote string

		wouldn't you know it, this is just like parsing frontmatter fences. when
		we implemented that for our site generator, best we could tell there's
		no way to do it in a single match.

		At this point in the code we already know that it starts with ''', but
		note that if there's a newline *immediately after*, then we should
		exclude that from the string. Which is, again the behavior of our
		frontmatter splitter.

		I think technically this parses wrong if you have '''\r<content> but
		honestly if you are doing that then whatever that's on you.
		]]
		local l, r = s:find("^'''\r?\n?")

		-- Now find the end quotes
		s = s:sub(r + 1)
		l, r = s:find("'''")

		if l == nil then
			error('missing terminated multiline single-quote\t' .. s)
		end

		local inner = do_multiline_string_newline_normalization(s:sub(1, l - 1))

		return inner, s:sub(r + 1)
	elseif prefix:sub(1,1) == '"' then
		-- single line dquote string
		local l = 1

		-- Find the terminating quote (unescaped)
		local _, r = s:find('[^\\]"')

		if r then
			local inner = s:sub(l + 1, r - 1)

			-- Perform substitutions
			inner = do_string_substitutions(inner)

			return inner, s:sub(r + 1)
		else
			error('missing terminating double-quote\t' .. s)
		end
	elseif prefix:sub(1,1) == "'" then
		-- single line squote string
		-- the easiest to parse
		local l, r = s:find("^%b''")
		if l and l == 1 then
			-- return inside the quotes, and after the right quote
			return s:sub(l + 1, r - 1), s:sub(r + 1)
		else
			error('missing terminating single-quote\t' .. s)
		end
	end
	return nil, s
end

-- Minimum component of a key
local function r_key_atom(s)
	-- keys can be string constants
	local k, rem = r_string(s)
	if k then
		return k, rem
	end

	-- keys can be bare
	local l, r = s:find('^([a-zA-Z0-9_-]+)')
	if not l then
		return nil, s
	end

	return s:sub(l, r), s:sub(r + 1)
end

-- A key, with one or more atoms separated by dots
local function r_key(s)
	local k, s = r_key_atom(s)
	if not k then
		return nil, s
	end
	local key = { k }

	-- eat all the subkeys
	while s:sub(1, 1) == '.' do
		k, s = r_key_atom(s:sub(2))
		if k == nil then
			error('incomplete dotted key\t' .. s)
		end
		table.insert(key, k)
	end

	return key, s
end



--[[
==================

Value Parsing

TODO:

- integers/floats dont require the underscores be surrounded by digits right now

==================
]]

--[[
https://toml.io/en/v1.0.0#integer
> Integers are whole numbers. Positive numbers may be prefixed with a plus sign. Negative numbers are prefixed with a minus sign.
> 
> For large numbers, you may use underscores between digits to enhance readability. Each underscore must be surrounded by at least one digit on each side.
> 
> Leading zeros are not allowed. Integer values -0 and +0 are valid and identical to an unprefixed zero.
> 
> Non-negative integer values may also be expressed in hexadecimal, octal, or binary. In these formats, leading + is not allowed and leading zeros are allowed (after the prefix). Hex values are case-insensitive. Underscores are allowed between digits (but not between the prefix and the value).
]]
local function r_integer(s)
	-- try hex/oct/bin first, they are very simple
	local prefix = s:sub(1, 2)
	if prefix == '0x' then
		local l, r = s:find('^[%x_]+', 3)
		if not l then
			error('invalid hex literal\t' .. s)
		end

		local lit = s:sub(l, r):gsub('_', '')
		
		return tonumber(lit, 16), s:sub(r + 1)
	elseif prefix == '0o' then
		local l, r = s:find('^[0-7_]+', 3)
		if not l then
			error('invalid octal literal\t' .. s)
		end

		local lit = s:sub(l, r):gsub('_', '')
		
		return tonumber(lit, 8), s:sub(r + 1)
	elseif prefix == '0b' then
		local l, r = s:find('^[01_]+', 3)
		if not l then
			error('invalid binary literal\t' .. s)
		end

		local lit = s:sub(l, r):gsub('_', '')
		
		return tonumber(lit, 2), s:sub(r + 1)
	end

	-- Integers can be led with +, -
	local l, r, lead, rest = s:find('^([1-9+%-])([0-9_]*)')


	if not l then
		return nil, s
	end

	rest = rest:gsub('_', '')

	-- +/- without numbers is nonsense
	if (lead == '+' or lead == '-') and #rest == 0 then
		error('numeric literal started with a +/- but theres no digits!\t' .. lead .. '\t' .. s)
	end

	return tonumber(lead .. rest), s:sub(r + 1)
end

local function r_float(s)
	--[[
	It turns out that lua tonumber() supports all the float formats that toml
	does. so that's neat! (tested with lua5.4). We just need to match it and
	strip underscores
	]]

	-- Try the special types first though
	local l, r, sign = s:find('^([+-]?)inf')
	if l then
		if sign and sign == '-' then
			-- math.huge is infinity.
			return -math.huge, s:sub(r + 1)
		else
			return math.huge, s:sub(r + 1)
		end
	end
	local l, r = s:find('^[+-]?nan')
	if l then
		return 0 / 0, s:sub(r + 1)
	end

	-- Integer part
	local l_int, r_int, lead_int, int = s:find('^([1-9+%-])([0-9_]*)')
	if not l then
		return nil, s
	end

	-- Then try fractional
	local l_frac, r_frac, frac = s:find('^%.([0-9_]+)', r + 1)

	-- If fractional is present, then parse exponont after it. Otherwise try
	-- parsing exponent right after integer part
	--
	-- parsing the number here differs from integer because it can have lead 0s
	local l_exp, r_exp, exp = s:find('^[eE]([+%-]?[0-9_]+)', (r_frac or r_int) + 1)

	-- There had to be either an exp or frac, or this is just an int
	-- TODO: optimization in that case?
	if not (l_frac or l_exp) then
		return nil, s
	end

	-- Now collect the whole number
	local num_str = s:sub(l_int, r_exp or r_frac):gsub('_', '')
	return tonumber(num_str), s:sub((r_exp or r_frac) + 1)
end

local function r_boolean(s)
	if s:find('^true') then
		return true, s:sub(5)
	end
	if s:find('^false') then
		return false, s:sub(6)
	end
	return nil, s
end

--[[
=============

TIME

.. is TODO

=============
]]


-- referenced by r_array, but uses r_array also
local r_value

--[[
### the array metatables

We'll use these to indicate whether a lua table started as a kv toml table, or
a contiguous toml array. this is necessary to disambiguate empty tables from
empty arrays, which is particularly relevant when *re-encoding* the data after
a transformation
]]
local decode_meta_type_array = {
	moonrabbit_toml_table_type = 'array'
}

local decode_meta_type_table = {
	moonrabbit_toml_table_type = 'table'
}

local function r_array(s)
	if s:sub(1, 1) ~= '[' then
		return nil, s
	end

	local s = r_ignore(s:sub(2))
	if s:sub(1, 1) == ']' then
		local values = {}
		setmetatable(values, decode_meta_type_array)
		return values, s:sub(2)
	end


	local values = {}
	setmetatable(values, decode_meta_type_array)

	-- Values
	local v
	while true do
		v, s = r_value(s)
		-- important this is a nil check because false is a value
		if v == nil then
			error('expected list closing bracket or a value\t' .. s)
		end
		table.insert(values, v)

		-- Now we need a comma, or a termination bracker
		s = r_ignore(s)
		local c = s:sub(1, 1)
		if c ~= ',' then
			if c == ']' then
				return values, s:sub(2)
			else
				error('expected comma or closing bracket to end the list\t' .. s)
			end
		end

		-- we had a comma, but we could still terminate
		s = r_ignore(s:sub(2))
		if s:sub(1, 1) == ']' then
			return values, s:sub(2)
		end
	end
end

local function r_key_value_pair(s)
	local key, s = r_key(s)
	if not key then
		return nil, s
	end

	s = r_ignore(s)
	if s:sub(1, 1) ~= '=' then
		error('expected equals-sign after key!\t' .. s)
	end

	s = r_ignore(s:sub(2))
	local val, s = r_value(s)
	-- important this is a nil check because false is a value
	if val == nil then
		error('got key and equals-sign but no value!\t' .. s)
	end

	return { key, val }, s
end

-- a helper to merge a KV pair into a dict
local function merge_kv(dict, key, val)
	-- insert leading dicts as needed
	for i = 1, #key - 1 do
		local d = dict[key[i]]
		if not d then
			d = {}
			setmetatable(d, decode_meta_type_table)
			dict[key[i]] = d
		end
		dict = d
	end

	-- no redefines
	if dict[key[#key]] then
		error('duplicated value: ' .. table.concat(key, '.'))
	end

	dict[key[#key]] = val
end

local function lookup_kv(dict, key)
	for i = 1, #key - 1 do
		local d = dict[key[i]]
		if not d then
			return nil
		end
		dict = d
	end

	return dict[key[#key]]
end

local function r_inline_table(s)
	if s:sub(1, 1) ~= '{' then
		return nil, s
	end

	local s = r_ignore(s:sub(2))
	if s:sub(1, 1) == '}' then
		local dict = {}
		setmetatable(dict, decode_meta_type_table)
		return dict, s:sub(2)
	end


	local dict = {}
	setmetatable(dict, decode_meta_type_table)

	-- Values
	local kv
	while true do
		kv, s = r_key_value_pair(s)
		if kv == nil then
			error('expected table closing brace or KV pair\t' .. s)
		end

		-- merge kv pair into dict
		merge_kv(dict, kv[1], kv[2])

		-- Now we need a comma, or a termination bracker
		s = r_ignore(s)
		local c = s:sub(1, 1)
		if c ~= ',' then
			if c == '}' then
				return dict, s:sub(2)
			else
				error('expected comma or closing brace to end the table\t' .. s)
			end
		end

		-- we had a comma, but we could still terminate
		s = r_ignore(s:sub(2))
		if s:sub(1, 1) == '}' then
			return dict, s:sub(2)
		end
	end
end

r_value = function(s)
	local v, rem = r_boolean(s)
	if v ~= nil then
		return v, rem
	end

	v, rem = r_string(s)
	if v ~= nil then
		return v, rem
	end
		
	v, rem = r_float(s)
	if v ~= nil then
		return v, rem
	end
		
	v, rem = r_integer(s)
	if v ~= nil then
		return v, rem
	end
		
	v, rem = r_array(s)
	if v ~= nil then
		return v, rem
	end
		
	v, rem = r_inline_table(s)
	if v ~= nil then
		return v, rem
	end

	return nil, s
end



-- [key] k-v pairs
local function r_headed_table(s)
	if s:sub(1, 1) ~= '[' then
		return nil, s
	end

	local store = s

	local header_key, s = r_key(r_ignore(s:sub(2)))

	if header_key == nil then
		error('expected header key for table\t' .. s)
	end

	s = r_ignore(s)
	if s:sub(1, 1) ~= ']' then
		error('no closing bracket for table header\t' .. table.concat(header_key, '.') .. '\t' .. store)
	end
	s = s:sub(2)

	-- EOF i guess
	if #s == 0 then
		local dict = {}
		setmetatable(dict, decode_meta_type_table)
		return dict, s
	end

	local l, r = s:find('^\r?\n')
	if not l then
		error('expected newline after table heading\t' .. table.concat(header_key, '.'))
	end

	local dict = {}
	setmetatable(dict, decode_meta_type_table)

	while true do
		s = r_ignore(s)
		local kv, rem = r_key_value_pair(s)
		if not kv then
			-- end of table def
			break
		end
		s = rem

		-- merge kv pair into dict
		merge_kv(dict, kv[1], kv[2])
	end

	return { header_key , dict }, s
end

--[=[
[[key]] k-v pairs

This is just one entry in the headed array, and is used in a loop in the main
decoder function.
]=]
local function r_headed_array(s)
	if s:sub(1, 2) ~= '[[' then
		return nil, s
	end

	local header_key, s = r_key(r_ignore(s:sub(3)))

	s = r_ignore(s)
	if s:sub(1, 2) ~= ']]' then
		error('no closing bracket for array-of-table header\t' .. s)
	end
	s = s:sub(3)

	-- EOF i guess
	if #s == 0 then
		local dict = {}
		setmetatable(dict, decode_meta_type_table)
		return dict, s
	end

	local l, r = s:find('^\r?\n')
	if not l then
		error('expected newline after array-of-table heading\t' .. table.concat(header_key, '.'))
	end

	local dict = {}
	setmetatable(dict, decode_meta_type_table)

	while true do
		s = r_ignore(s)
		local kv, rem = r_key_value_pair(s)
		if kv == nil then
			-- end of table def
			break
		end
		s = rem

		-- merge kv pair into dict
		merge_kv(dict, kv[1], kv[2])
	end

	return { header_key, dict }, s
end



function m.decode(str)
	-- > A TOML file must be a valid UTF-8 encoded Unicode document.
	assert(utf8.len(str), 'invalid utf8')

	local data = {}

	-- Top level toml structure is *always* a table
	setmetatable(data, decode_meta_type_table)

	local s = str

	while true do
		s = r_ignore(s)

		-- EOF
		if #s == 0 then
			break
		end

		local arr, rem = r_headed_array(s)
		if arr then
			local existing_arr = lookup_kv(data, arr[1])
			if existing_arr then
				table.insert(existing_arr, arr[2])
			else
				--[[
				TODO:
				> Attempting to append to a statically defined array, even if
				> that array is empty, must produce an error at parse time.
				]]
				local values = { arr[2] }
				setmetatable(values, decode_meta_type_array)
				merge_kv(data, arr[1], values)
			end

			s = rem
			goto continue
		end

		local tbl, rem = r_headed_table(s)
		if tbl then
			-- will check for redefinitions of a table since we arent merging
			-- all the values in the dict individually
			merge_kv(data, tbl[1], tbl[2])

			s = rem
			goto continue
		end

		local kv, rem = r_key_value_pair(s)
		if kv then
			merge_kv(data, kv[1], kv[2])

			s = rem
			goto continue
		end

		error('unexpected trailing data\t' .. s)

		::continue::
	end

	return data
end

--[[

==
		ENCODING
						==

Encoders will use coroutine.yield() to emit fragments that we can combine into
our final toml. Right now we just collect them and concatenate them all, but
later we could also stream them to a file.

For pretty-printing, array/table encoders want to keep track of indentation
level for nested arrays/tables. We'll yield that as a second value, and the
processor can decide whether they care.
]]


--[[
encode a lua string as a dquote toml string, so we have access to escape
sequences. We'll reject any non-UTF8 inputs because TOML only allows UTF8
documents. Later, for perf reasons, it might be nice to be able to turn off the
UTF-8 checks. But for now, we don't have a usecase where that matters.
]]
local function e_string(s)
	-- reject invalid utf8
	if not utf8.len(s) then
		error('string is not utf8: ' .. s)
	end
	
	-- convert characters to be escaped as necessary
	s = s:gsub('[\b\t\n\f\r"\\]', {
		['\b'] = '\\b',
		['\t'] = '\\t',
		['\n'] = '\\n',
		['\f'] = '\\f',
		['\r'] = '\\r',
		['"'] = '\\"',
		['\\'] = '\\\\',
	})

	coroutine.yield('"')
	coroutine.yield(s)
	coroutine.yield('"')
end

--[[
For now I dont think we intend to use dot-notation, so just encode keys as
quoted strings since it's easiest and always valid. Note that if we change this
we need to handle whether `k` is valid utf8 separately

we tostring() it in case k is a number. numbers cant be keys! unless they're
quoted and then it's fine
]]
local function e_key(k)
	e_string(tostring(k))
end

local function e_boolean(b)
	coroutine.yield(tostring(b))
end

local function e_number(n)
	--[[
	to be as correct as possible when doing transformations, we should encode
	integers as integers and floats as floats. Lua's tostring() already *does*
	this as far as I can tell. When given a float, it always appends a trailing
	zero. It does exponent encoding too. When given an integer, it doesnt append
	a trailing zero. I don't know which lua version we can rely on this in, but
	we can at least rely on it in 5.4
	]]
	coroutine.yield(tostring(n))
end

--[[
dispatch for encoding a value based on its lua type
]]
local e_value

--[[
encode a key-value pair as KEY ' = ' VALUE
]]
local function e_kv(k, v)
	e_key(k)
	coroutine.yield(' = ')
	e_value(v)
end


--[[
is the lua table a contiguous array in toml terms? That is, all the indices are
numbers, they're all contiguous, and they start at 1

It's ambiguous as to whether an empty table is an array or a kv table, lol. we
will bias towards array, but also return whether it was empty as the second
return argument so the caller can do something with that information.

If the data receiver cares about the difference between an array and a kv table,
our guessing can be a problem. To make that easier to deal with, we'll also
check the metatable for a type hint. Our decoder will set those type hints too,
so we can transform data more accurately.
]]
local function is_array(tbl)
	local meta = getmetatable(tbl)
	if meta then
		if meta.moonrabbit_toml_table_type == 'array' then
			return true, #tbl > 0
		elseif meta.moonrabbit_toml_table_type == 'table' then
			for _, _ in pairs(tbl) do
				return false, false
			end
			return false, true
		end
	end

	local empty = true
	local prev = 0
	for k, _ in pairs(tbl) do
		empty = false
		-- non-numeric key
		if type(k) ~= 'number' or (k - 1) ~= prev then
			return false, empty
		end

		prev = k
	end
	return true, empty
end

--[[
encode a lua-table as a square-bracket array
]]
local function e_array(tbl)
	coroutine.yield('[ ')

	for _, v in ipairs(tbl) do
		e_value(v)
		-- trailing commas are allowed, yay!
		coroutine.yield(', ')
	end

	coroutine.yield(']')
end

--[[
encode a lua-table as a curly-brace table. Technically newlines should be
allowed in this as far as i can tell, but online validators reject them.
]]
local function e_table(tbl)
	coroutine.yield('{ ')

	local not_first = false
	for k, v in pairs(tbl) do
		if not_first then
			-- trailing commas are NOT allowed! lol.
			coroutine.yield(', ')
		end
		not_first = true

		-- the actual k/v pair
		e_kv(k, v)
	end

	coroutine.yield(' }')
end


--[[
top-level table.
]]
local function e_headed_table(tbl_name, tbl)
	coroutine.yield('[')
	e_key(tbl_name)
	coroutine.yield(']\n')
	for k, v in pairs(tbl) do
		e_kv(k, v)
		coroutine.yield('\n')
	end
	coroutine.yield('\n')
end

--[[
top-level array. may only contain tables
]]
local function e_headed_array_of_tables(array_name, array)
	for _, tbl in ipairs(array) do
		if type(tbl) ~= 'table' then
			error(array_name .. '\tarray-of-tables cannot contain ' .. type(tbl))
		end
		local is_arr, is_empty = is_array(tbl)
		if not is_empty and is_arr then
			error(array_name .. '\tarray-of-tables cannot contain an array')
		end

		coroutine.yield('[[')
		e_key(array_name)
		coroutine.yield(']]\n')

		for k, v in pairs(tbl) do
			e_kv(k, v)
			coroutine.yield('\n')
		end
	end
	coroutine.yield('\n')
	
end


--[[
decide how to encode something, and do it This is pretty straightforward, except
for tables, where we need to traverse the table and verify whether it is in fact
a map or an array.
]]
local e_value_dispatch = {
	['string']	= e_string,
	['boolean']	= e_boolean,
	['number']	= e_number,
	['table']	= function(tbl)
		if is_array(tbl) then
			e_array(tbl)
		else
			e_table(tbl)
		end
	end,
	__index = function(t)
		error('no way to encode type ' .. t)
	end
}
setmetatable(e_value_dispatch, e_value_dispatch)

e_value = function(v)
	return e_value_dispatch[type(v)](v)
end


--[[
top level dispatch is a bit different. We'll take the key and value.
tables/arrays get headed syntax because it's nicer to read. string/boolean/num
end up with a double-typecheck since e_kv uses e_value() that checks the value
type a second time. Could optimize that later.
]]
local e_value_dispatch_toplevel = {
	['string']	= function(k, v)
		e_kv(k, v)
		coroutine.yield('\n')
	end,
	['boolean']	= function(k, v)
		e_kv(k, v)
		coroutine.yield('\n')
	end,
	['number']	= function(k, v)
		e_kv(k, v)
		coroutine.yield('\n')
	end,
	['table']	= function(name, tbl)
		if is_array(tbl) then
			e_headed_array_of_tables(name, tbl)
		else
			e_headed_table(name, tbl)
		end
	end,
	__index = function(t)
		return function(name, v)
			error(name .. '\tno way to encode type ' .. t)
		end
	end
}
setmetatable(e_value_dispatch_toplevel, e_value_dispatch_toplevel)

local function e_value_toplevel(k, v)
	return e_value_dispatch_toplevel[type(v)](k, v)
end


--[[
TODO: right now output is pretty ugly because we are using inline tables/arrays
for everything. we can make this better by stacking keys up with dotted key
syntax, using headed tables/arrays for everything except the last level. Which
requires more traversals to see if we're actually at a leaf or not. But that is
technically optional, right now we do encode syntactically valid toml!
]]
function m.encode(tbl)
	-- Top level *must* be a table
	if type(tbl) ~= 'table' then
		error('Cannot encode a ' .. type(tbl) .. ' as a toml document, only tables')
	end
	
	local is_arr, is_empty = is_array(tbl)

	if is_empty then
		return ''
	end

	if is_arr then
		error('Cannot encode an array as a TOML document. the top level must be a k-v map')
	end

	--[[
	Create our coroutine. Right now we'll collect all the strings it emits into
	into an array, and then concat it at the end. Later we could also use this
	to stream bytes into a file output if we wanted
	]]
	local iter_fragments = coroutine.wrap(function()
		for k, v in pairs(tbl) do
			e_value_toplevel(k, v)
		end
	end)

	local fragments = {}
	for fragment in iter_fragments do
		table.insert(fragments, fragment)
	end

	return table.concat(fragments)
end

return m

