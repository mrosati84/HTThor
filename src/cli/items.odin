// The request-item mini-language: `name=value`, `name:=json`, `name==query`,
// `name:header`, `name@upload`, their `@file` variants, bare `@file`, bracket
// paths (`user[name]=John`), and backslash escaping.
//
// The grammar is httpie's (docs/PARITY.md §3, httpie/cli/argtypes.py +
// httpie/cli/requestitems.py). Parsing happens while the command line is being
// read, exactly as it does in the reference, so a malformed item, a missing
// file or a bad `:=` JSON becomes a usage error before anything is sent.
//
// This module owns the *grammar*; turning an Item_Set into the bytes on the
// wire (header order, Content-Type, urlencoded/multipart framing) belongs to
// the transport engine (t_3d62ca31).
package cli

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import "src:format"
import "src:http"

// Sep is one of the item separators. The spelling is pinned by
// httpie/cli/constants.py; `sep_text` maps back to it.
Sep :: enum {
	Header, // ":"     request header
	Header_Empty, // ";"  header with an empty value
	Header_Embed, // ":@"
	Query_Param, // "=="
	Query_Embed, // "==@"
	Data_String, // "="
	Data_Embed_File, // "=@"
	Data_Raw_JSON, // ":="
	Data_Raw_JSON_File, // ":=@"
	File_Upload, // "@"
}

sep_text :: proc(sep: Sep) -> string {
	switch sep {
	case .Header:            return ":"
	case .Header_Empty:      return ";"
	case .Header_Embed:      return ":@"
	case .Query_Param:       return "=="
	case .Query_Embed:       return "==@"
	case .Data_String:       return "="
	case .Data_Embed_File:   return "=@"
	case .Data_Raw_JSON:     return ":="
	case .Data_Raw_JSON_File: return ":=@"
	case .File_Upload:       return "@"
	}
	return ""
}

// ALL_SEPARATORS is SEPARATOR_GROUP_ALL_ITEMS: every separator accepted in a
// REQUEST_ITEM argument. Order does not matter, the scan picks by position.
ALL_SEPARATORS :: []Sep {
	.Header,
	.Header_Empty,
	.Header_Embed,
	.Query_Param,
	.Query_Embed,
	.Data_String,
	.Data_Embed_File,
	.Data_Raw_JSON,
	.Data_Raw_JSON_File,
	.File_Upload,
}

// NESTED_JSON_SEPARATORS is SEPARATOR_GROUP_NESTED_JSON_ITEMS: the items whose
// keys may carry bracket paths in JSON mode.
NESTED_JSON_SEPARATORS :: bit_set[Sep] {
	.Data_String,
	.Data_Raw_JSON,
	.Data_Embed_File,
	.Data_Raw_JSON_File,
}

// MULTIPART_SEPARATORS is SEPARATORS_GROUP_MULTIPART: the data items that become
// fields of a multipart body. It is the set the reference fills
// `instance.multipart_data` from (`if arg.sep in SEPARATORS_GROUP_MULTIPART`,
// httpie/cli/requestitems.py:112-113), so a `:=`/`:=@` item is *not* in it and
// contributes no part — while the JSON body and the urlencoded form body are
// built from `args.data`, which keeps it (docs/PARITY.md §1.2). The file fields
// (`@`, and the `@file` whose key is empty) are part of the group and are
// interleaved with the data items in the session, not filtered here.
MULTIPART_SEPARATORS :: bit_set[Sep] {
	.Data_String,
	.Data_Embed_File,
	.File_Upload,
}

Header_Item :: struct {
	name:  string,
	value: string,
	unset: bool, // `Header:` — httpie drops the header the session supplied
}

Param_Item :: struct {
	name:  string,
	value: string,
}

File_Item :: struct {
	name:       string, // field name
	filename:   string, // basename, as sent in Content-Disposition
	path:       string, // path as given on the command line
	mime:       string, // guessed or `;type=`-overridden; "" when unguessable
	content:    []byte, // read at parse time, like the reference opens it there
	after_data: int,    // how many data items preceded this file on the line
}

Data_Item :: struct {
	key:   string, // owned
	orig:  string, // owned; the original argument, for error text
	sep:   Sep,
	value: format.Value, // owned
}

// Item_Set is the parsed command line's request items, in the groups httpie
// keeps them in. Every field is owned by `allocator`; item_set_destroy frees
// the whole set and zeroes it.
Item_Set :: struct {
	allocator: mem.Allocator,
	headers:   [dynamic]Header_Item,
	params:    [dynamic]Param_Item,
	data:      [dynamic]Data_Item,
	files:     [dynamic]File_Item,

	// bare `@file`: the whole request body comes from a file
	body_file:          string,
	body_file_contents: []byte,
	body_file_given:    bool,

	// The key of every `@file` item, in command-line order, empty key included
	// — the reference's `args.files`, which is a *list* of (key, file) pairs, so
	// two bare `@file`s are two entries and the keys are what its two error
	// messages print (argparser.py:470-489). Only filled for a command line that
	// cannot carry a legal file field (no --form/--multipart): that is the only
	// place the list is read, every other road reports the missing --form first
	// (item_set_validate).
	file_keys: [dynamic]string,

	// set when ordering/validation needs it
	has_data:        bool,
	any_file_field:  bool,
}

// item_set_body_file_content_type is the Content-Type a bare `@file` body
// carries: the file extension's guess, or "" when the extension says nothing.
// There is no fallback: httpie sets the header only when the guess is truthy
// (`if content_type: self.args.headers['Content-Type'] = content_type`,
// argparser.py:485-488 — `get_content_type` is
// `mimetypes.guess_type(...)[0]`, utils.py:140), so an unguessable name leaves
// the request type's own default in place (docs/PARITY.md §3.1).
//
// The returned string is owned by the caller.
item_set_body_file_content_type :: proc(set: ^Item_Set, allocator: mem.Allocator) -> (mime: string, ok: bool) {
	if !set.body_file_given {
		return "", true
	}
	return guess_content_type(set.body_file, allocator)
}

item_set_create :: proc(allocator: mem.Allocator) -> Item_Set {
	return Item_Set {
		allocator = allocator,
		headers = make([dynamic]Header_Item, allocator),
		params = make([dynamic]Param_Item, allocator),
		data = make([dynamic]Data_Item, allocator),
		files = make([dynamic]File_Item, allocator),
		file_keys = make([dynamic]string, allocator),
	}
}

item_set_destroy :: proc(set: ^Item_Set) {
	if set == nil {
		return
	}
	for h in set.headers {
		delete(h.name, set.allocator)
		delete(h.value, set.allocator)
	}
	delete(set.headers)
	for p in set.params {
		delete(p.name, set.allocator)
		delete(p.value, set.allocator)
	}
	delete(set.params)
	for i in 0 ..< len(set.data) {
		delete(set.data[i].key, set.allocator)
		delete(set.data[i].orig, set.allocator)
		format.value_destroy(&set.data[i].value, set.allocator)
	}
	delete(set.data)
	for f in set.files {
		delete(f.name, set.allocator)
		delete(f.filename, set.allocator)
		delete(f.path, set.allocator)
		delete(f.mime, set.allocator)
		delete(f.content, set.allocator)
	}
	delete(set.files)
	for key in set.file_keys {
		delete(key, set.allocator)
	}
	delete(set.file_keys)
	delete(set.body_file, set.allocator)
	delete(set.body_file_contents, set.allocator)
	set^ = {}
}

// ---------------------------------------------------------------------------
// The item header dict
// ---------------------------------------------------------------------------

// Header_Value is one value of a folded header name. The spelling travels with
// the value: `args.headers` is a CIMultiDict, so `x-note:A X-NoTe:B` keeps both
// spellings and renders one line each (docs/PARITY.md §3.1).
Header_Value :: struct {
	name:  string, // borrowed from the item set
	value: string, // borrowed from the item set
}

// Header_Entry is one *name* of `args.headers` as `HTTPHeadersDict` leaves it.
Header_Entry :: struct {
	// name is the spelling the dict stores for the name: the one the first item
	// that set it spelled, or — after an unset — the one the item that revived
	// it spelled (`self[key] = None` stores the assignment's spelling,
	// cli/dicts.py:26-28).
	name:   string,
	values: [dynamic]Header_Value,
	// unset is true when the name's last state is a `None` (`Name:` with an
	// empty value): the dict carries the name with no value at all.
	unset: bool,
}

// Header_Fold is the item headers as httpie's `args.headers` holds them, in the
// dict's own order. Every entry is either an unset or a list of values.
//
// The rules are `HTTPHeadersDict.add` (httpie/cli/dicts.py:18-36):
//
//   * a value is appended to the name's values, keeping the item's spelling;
//   * a `None` (an item whose separator is `:` and whose value is empty) is
//     `self[key] = None`: every value of that name is replaced and the name
//     *keeps its slot* in the dict;
//   * a value added to a name whose only value is the `None` discards it
//     (`popone`) and appends at the end of the dict, so a name that was unset
//     and then set again moves behind every name the items named after it:
//     `X-Note: X-A:1 X-Note:B` is the dict `X-A, X-Note` (docs/PARITY.md §3.1).
//
// Everything downstream reads this: the merge into the request (`Name:` drops
// the name where `Name;` keeps an empty value) and the rendered order, which is
// the dict's order.
Header_Fold :: struct {
	allocator: mem.Allocator,
	entries:   [dynamic]Header_Entry,
}

// header_fold collapses the item headers into that dict. The strings are
// borrowed from the item set, which must outlive the fold.
header_fold :: proc(set: ^Item_Set, allocator: mem.Allocator) -> Header_Fold {
	fold := Header_Fold {
		allocator = allocator,
		entries   = make([dynamic]Header_Entry, allocator),
	}
	for header in set.headers {
		key := -1
		for entry, index in fold.entries {
			if strings.equal_fold(entry.name, header.name) {
				key = index
				break
			}
		}
		if header.unset {
			if key < 0 {
				append(&fold.entries, Header_Entry{name = header.name, unset = true})
				continue
			}
			// The assignment keeps the name's slot and drops its values.
			entry := &fold.entries[key]
			clear(&entry.values)
			entry.unset = true
			entry.name = header.name
			continue
		}
		if key < 0 {
			append(&fold.entries, Header_Entry {
				name = header.name,
				values = make([dynamic]Header_Value, allocator),
			})
			key = len(fold.entries) - 1
		}
		if fold.entries[key].unset {
			// `add` discards the `None` and appends at the end of the dict.
			revived := fold.entries[key]
			clear(&revived.values)
			revived.unset = false
			revived.name = header.name
			for i in key ..< len(fold.entries) - 1 {
				fold.entries[i] = fold.entries[i + 1]
			}
			fold.entries[len(fold.entries) - 1] = revived
			key = len(fold.entries) - 1
		}
		append(&fold.entries[key].values, Header_Value {
			name = header.name,
			value = header.value,
		})
	}
	return fold
}

// header_fold_destroy releases the fold's own allocations. The names and values
// in it belong to the item set.
header_fold_destroy :: proc(fold: ^Header_Fold) {
	for entry in fold.entries {
		delete(entry.values)
	}
	delete(fold.entries)
	fold^ = {}
}

// ---------------------------------------------------------------------------
// Separator scan
// ---------------------------------------------------------------------------

// split_point finds the separator httpie would choose: the earliest position
// holding an unescaped separator, longest separator first at that position.
// Returns the byte offset, the separator, and whether one was found.
@(private)
split_point :: proc(arg: string, allocator: mem.Allocator) -> (offset: int, sep: Sep, found: bool) {
	escaped := make([dynamic]bool, 0, len(arg), allocator)
	clean := make([dynamic]u8, 0, len(arg), allocator)
	defer {
		delete(escaped)
		delete(clean)
	}

	i := 0
	for i < len(arg) {
		c := arg[i]
		if c == '\\' && i + 1 < len(arg) {
			next := arg[i + 1]
			if next == ':' || next == ';' || next == '@' || next == '=' {
				append(&clean, next)
				append(&escaped, true)
				i += 2
				continue
			}
			// A backslash before anything else is kept *with* the character
			// it precedes: the pair is consumed, so a second backslash cannot
			// open an escape of its own. `\\:` is two literal backslashes and
			// a live `:` there, not an escaped one — the difference between
			// the character the reference appends (`tokens[-1] += '\\' +
			// char`, argtypes.py:122-127) and the one-byte advance this scan
			// used to make (t_7dce3f8a).
			append(&clean, '\\')
			append(&escaped, false)
			append(&clean, next)
			append(&escaped, false)
			i += 2
			continue
		}
		append(&clean, c)
		append(&escaped, false)
		i += 1
	}

	text := string(clean[:])
	best_offset := -1
	best_sep: Sep
	for pos in 0 ..< len(text) {
		for candidate in ALL_SEPARATORS {
			candidate_text := sep_text(candidate)
			if !strings.has_prefix(text[pos:], candidate_text) {
				continue
			}
			// No byte of the separator may be escaped.
			ok := true
			for k in 0 ..< len(candidate_text) {
				if escaped[pos + k] {
					ok = false
					break
				}
			}
			if !ok {
				continue
			}
			if best_offset == -1 || pos < best_offset ||
			   (pos == best_offset && len(candidate_text) > len(sep_text(best_sep))) {
				best_offset = pos
				best_sep = candidate
			}
		}
	}
	if best_offset < 0 {
		return 0, .Header, false
	}
	return best_offset, best_sep, true
}

// unescape turns an argument into the byte string httpie would produce after
// resolving backslash escapes. A backslash consumes the character that
// follows it: when that character is one of the separators it is emitted
// without the backslash, and when it is anything else the *pair* is emitted as
// it stands — so `\\:` keeps both backslashes (`\:` alone loses the one).
// `split_point`'s scan is the same rule over the same bytes; a change to one
// of the two is a change to both (t_7dce3f8a).
@(private)
unescape :: proc(s: string, allocator: mem.Allocator) -> (text: string, ok: bool) {
	escaped := make([dynamic]bool, 0, len(s), allocator)
	clean := make([dynamic]u8, 0, len(s), allocator)
	defer {
		delete(escaped)
		delete(clean)
	}

	i := 0
	for i < len(s) {
		c := s[i]
		if c == '\\' && i + 1 < len(s) {
			next := s[i + 1]
			if next == ':' || next == ';' || next == '@' || next == '=' {
				append(&clean, next)
				i += 2
				continue
			}
			// The pair is taken: the reference appends `'\\' + char`, so the
			// second backslash of a run is a character like any other and not
			// the start of another escape (`tokens[-1] += '\\' + char`,
			// httpie/cli/argtypes.py:122-127).
			append(&clean, '\\')
			append(&clean, next)
			i += 2
			continue
		}
		append(&clean, c)
		i += 1
	}
	// The copy is the last step, and its failure is reported by the caller:
	// an empty key or value is a legitimate item, so an absorbed allocation
	// error would build a wrong request (backlog M5).
	return http.clone_or_oom(string(clean[:]), allocator)
}

// ---------------------------------------------------------------------------
// Item parsing
// ---------------------------------------------------------------------------

// Item_Parse is one tokenised request item.
Item_Parse :: struct {
	key:   string, // unescaped, owned
	value: string, // unescaped, owned
	sep:   Sep,
	orig:  string, // the argument as typed, owned
}

item_parse_destroy :: proc(item: ^Item_Parse, allocator: mem.Allocator) {
	delete(item.key, allocator)
	delete(item.value, allocator)
	delete(item.orig, allocator)
	item^ = {}
}

// parse_item_arg splits one REQUEST_ITEM argument. The error is httpie's
// wording, without the `argument REQUEST_ITEM: ` prefix the caller adds.
parse_item_arg :: proc(arg: string, allocator: mem.Allocator) -> (item: Item_Parse, message: string) {
	offset, sep, found := split_point(arg, allocator)
	if !found {
		repr := python_repr(arg, allocator)
		defer delete(repr, allocator)
		return {}, fmt.aprintf("%s is not a valid value", repr, allocator = allocator)
	}
	unescaped, unescape_ok := unescape(arg, allocator)
	if !unescape_ok {
		return {}, strings.clone("not enough memory", allocator) or_else ""
	}
	defer delete(unescaped, allocator)
	sep_len := len(sep_text(sep))
	// Every field is an owned copy, and a copy that could not be made is
	// reported: an empty key or value is a legitimate item, so absorbing the
	// failure would send a wrong one (backlog M5).
	item.sep = sep
	if !http.clone_into(&item.key, unescaped[:offset], allocator) ||
	   !http.clone_into(&item.value, unescaped[offset + sep_len:], allocator) ||
	   !http.clone_into(&item.orig, arg, allocator) {
		item_parse_destroy(&item, allocator)
		return {}, strings.clone("not enough memory", allocator) or_else ""
	}
	return item, ""
}

// item_set_add parses one argument and folds it into the set. `is_json` is
// true for the default content type (--json); `form_like` is true for --form
// and --multipart; `env` is the environment the file items resolve `~` against
// (`os.path.expanduser` reads $HOME). `message` is a usage-error body, owned by
// `allocator`.
item_set_add :: proc(
	set: ^Item_Set,
	arg: string,
	is_json: bool,
	form_like: bool,
	env: Env_Info,
	allocator: mem.Allocator,
) -> (message: string) {
	item, parse_message := parse_item_arg(arg, allocator)
	if parse_message != "" {
		return parse_message
	}
	defer item_parse_destroy(&item, allocator)

	switch item.sep {
	case .Header:
		// `Header:` unsets a header; `Header:value` sets it.
		unset := item.value == ""
		value := item.value
		if unset {
			value = ""
		}
		header := Header_Item{unset = unset}
		if !http.clone_into(&header.name, item.key, allocator) ||
		   !http.clone_into(&header.value, value, allocator) {
			// The copy that was made is released here, so the failure leaks
			// nothing on its way out (backlog M5).
			delete(header.name, allocator)
			delete(header.value, allocator)
			return strings.clone("not enough memory", allocator) or_else ""
		}
		append(&set.headers, header)
	case .Header_Empty:
		if item.value != "" {
			repr := python_repr(item.orig, allocator)
			defer delete(repr, allocator)
			return fmt.aprintf(
				"Invalid item %s (to specify an empty header use `Header;`)",
				repr,
				allocator = allocator,
			)
		}
		header := Header_Item{}
		if !http.clone_into(&header.name, item.key, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		append(&set.headers, header)
	case .Header_Embed:
		contents, file_message := read_text_file(item.value, item.orig, env, allocator)
		if file_message != "" {
			return file_message
		}
		header_value, value_ok := rstrip_newlines(contents, allocator)
		delete(contents, allocator)
		if !value_ok {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		header := Header_Item{value = header_value}
		if !http.clone_into(&header.name, item.key, allocator) {
			delete(header.value, allocator)
			return strings.clone("not enough memory", allocator) or_else ""
		}
		append(&set.headers, header)
	case .Query_Param:
		param := Param_Item{}
		if !http.clone_into(&param.name, item.key, allocator) ||
		   !http.clone_into(&param.value, item.value, allocator) {
			delete(param.name, allocator)
			delete(param.value, allocator)
			return strings.clone("not enough memory", allocator) or_else ""
		}
		append(&set.params, param)
	case .Query_Embed:
		contents, file_message := read_text_file(item.value, item.orig, env, allocator)
		if file_message != "" {
			return file_message
		}
		param_value, value_ok := rstrip_newlines(contents, allocator)
		delete(contents, allocator)
		if !value_ok {
			return strings.clone("not enough memory", allocator) or_else ""
		}
		param := Param_Item{value = param_value}
		if !http.clone_into(&param.name, item.key, allocator) {
			delete(param.value, allocator)
			return strings.clone("not enough memory", allocator) or_else ""
		}
		append(&set.params, param)
	case .File_Upload:
		// A `@file` item is a *file field*, with or without a key: the reference
		// reads every one of them through process_file_upload_arg, where the
		// `;type=` suffix is split off the name and the file is opened
		// (requestitems.py:147-161), and only the file-list check that follows
		// decides that a bare one — the file field whose key is empty — is the
		// request body (argparser.py:470-489).
		if item.key == "" && !form_like {
			// Bare `@file` without --form/--multipart: the body, typed by the
			// *name*'s extension. Its own `;type=` is unused on this road — the
			// reference types the body from `fn`, the basename of the split-off
			// name, not from the field's type (argparser.py:485-488) — but the
			// name is still the split one, so the file that is opened is the
			// file the suffix was stripped from.
			path, _ := split_file_upload_arg(item.value)
			contents, file_message := read_binary_file(path, item.orig, env, allocator)
			if file_message != "" {
				return file_message
			}
			delete(set.body_file_contents, allocator)
			if !http.clone_into(&set.body_file, path, allocator) {
				delete(contents, allocator)
				return strings.clone("not enough memory", allocator) or_else ""
			}
			set.body_file_contents = contents
			set.body_file_given = true
		} else {
			// A file field is only legal for --form/--multipart. httpie opens
			// the file first and reports the "you probably meant --form" error
			// later, so a missing file still wins here.
			file, file_message := load_upload(item.key, item.value, item.orig, env, allocator)
			if file_message != "" {
				return file_message
			}
			// The multipart body is serialised in command-line order, so a file
			// field has to remember where it sat among the data items
			// (`args.multipart_data` is a dict: insertion order is item order).
			// A bare `@file` under --form/--multipart is one of these, with an
			// empty name — the unnamed part the reference sends.
			file.after_data = len(set.data)
			append(&set.files, file)
			set.any_file_field = true
		}
		if !form_like && !append_owned(&set.file_keys, item.key, allocator) {
			return strings.clone("not enough memory", allocator) or_else ""
		}
	case .Data_String, .Data_Embed_File, .Data_Raw_JSON, .Data_Raw_JSON_File:
		value: format.Value
		#partial switch item.sep {
		case .Data_String:
			cloned, clone_ok := http.clone_or_oom(item.value, allocator)
			if !clone_ok {
				return strings.clone("not enough memory", allocator) or_else ""
			}
			value = cloned
		case .Data_Embed_File:
			contents, file_message := read_text_file(item.value, item.orig, env, allocator)
			if file_message != "" {
				return file_message
			}
			value = contents
		case .Data_Raw_JSON:
			parsed, json_error := format.parse_json(item.value, allocator)
			if json_error.message != "" {
				// httpie's convert_json_value_to_form_if_needed: a `:=` value that
				// does not parse has no form representation either, and reports
				// the complex-value error rather than the JSON one.
				if form_like {
					format.json_error_destroy(&json_error)
					return strings.clone(COMPLEX_JSON_IN_FORM_MESSAGE, allocator) or_else ""
				}
				repr := python_repr(item.orig, allocator)
				defer delete(repr, allocator)
				message = fmt.aprintf(
					"%s: %s",
					repr,
					json_error.message,
					allocator = allocator,
				)
				format.json_error_destroy(&json_error)
				return message
			}
			value = parsed
		case .Data_Raw_JSON_File:
			contents, file_message := read_text_file(item.value, item.orig, env, allocator)
			if file_message != "" {
				// The reader's refusal is inside the same wrapper as the
				// decoder's: httpie's convert_json_value_to_form_if_needed
				// catches *every* ParseError the processor raises —
				// load_text_file's `[Errno 2]` and its non-UTF-8
				// `cannot embed the content of …` included — and reports the
				// complex-value error instead.
				if form_like {
					delete(file_message, allocator)
					return strings.clone(COMPLEX_JSON_IN_FORM_MESSAGE, allocator) or_else ""
				}
				return file_message
			}
			parsed, json_error := format.parse_json(contents, allocator)
			delete(contents, allocator)
			if json_error.message != "" {
				// ...and the decoder's own error is caught by the same
				// wrapper, exactly like the inline `:=` road above.
				if form_like {
					format.json_error_destroy(&json_error)
					return strings.clone(COMPLEX_JSON_IN_FORM_MESSAGE, allocator) or_else ""
				}
				repr := python_repr(item.orig, allocator)
				defer delete(repr, allocator)
				message = fmt.aprintf(
					"%s: %s",
					repr,
					json_error.message,
					allocator = allocator,
				)
				format.json_error_destroy(&json_error)
				return message
			}
			value = parsed
		case:
			value = format.Null{}
		}

		// A `:=`/`:=@` value is parsed the reference's way: every object in it is
		// a `JsonDictPreservingDuplicateKeys`, so it renders the pairs it was
		// parsed with and a later bracket-path write into it lands in a live dict
		// json.dumps never reads (httpie/utils.py:27-71, docs/PARITY.md §3.3).
		// The freeze is the *parse* half of that rule, which is where the
		// reference has it — `load_json_preserve_order_and_dupe_keys` is the
		// parser behind both separators, in either content type (the value a form
		// cannot carry is refused just below).
		#partial switch item.sep {
		case .Data_Raw_JSON, .Data_Raw_JSON_File:
			format.value_freeze(&value, allocator)
		}

		if form_like {
			// Complex JSON values make no sense in a form body. The
			// reference's test is `isinstance(output, (str, int, float))`
			// (requestitems.py:186), so `null` — Python's `None` — is
			// complex too, and `true`/`false` are not (a `bool` *is* an
			// `int` there, and prints as `True`/`False`).
			#partial switch v in value {
			case format.Object, []format.Value, format.Null:
				format.value_destroy(&value, allocator)
				return strings.clone(COMPLEX_JSON_IN_FORM_MESSAGE, allocator) or_else ""
			}
			// Primitives are stringified the way Python prints them. The copy
			// inside that answer is reported: an empty form value is a legitimate
			// part, so absorbing it would send the wrong body (backlog M5).
			converted, converted_ok := format.value_to_form_string(value, allocator)
			if !converted_ok {
				format.value_destroy(&value, allocator)
				return strings.clone("not enough memory", allocator) or_else ""
			}
			value = converted
		}

		data_key, data_orig: string
		if !http.clone_into(&data_key, item.key, allocator) ||
		   !http.clone_into(&data_orig, item.orig, allocator) {
			// The parsed value travels with the item, so the failure has to
			// release it as well as the copies already made (backlog M5).
			delete(data_key, allocator)
			delete(data_orig, allocator)
			format.value_destroy(&value, allocator)
			return strings.clone("not enough memory", allocator) or_else ""
		}
		append(&set.data, Data_Item {
			key   = data_key,
			orig  = data_orig,
			sep   = item.sep,
			value = value,
		})
		set.has_data = true
	}
	return ""
}

// SEPARATOR_FILE_UPLOAD_TYPE is `SEPARATOR_FILE_UPLOAD_TYPE = ';type='`
// (httpie/cli/constants.py), the suffix that names a file field's type.
SEPARATOR_FILE_UPLOAD_TYPE :: ";type="

// split_file_upload_arg is the splitting half of the reference's
// process_file_upload_arg (requestitems.py:148-150):
//
//	parts = arg.value.split(SEPARATOR_FILE_UPLOAD_TYPE)   # every occurrence
//	filename = parts[0]                                   # …before the first
//	mime_type = parts[1] if len(parts) > 1 else None      # …between 1st and 2nd
//
// `str.split` cuts at *every* occurrence and only the first two parts are read,
// so the name ends at the first `;type=` and the type at the second — anything
// from the second one on is dropped (`f@x.txt;type=text/a;type=text/b` is the
// field `x.txt` typed `text/a`). An empty `;type=` yields the empty string,
// which the reference's `mime_type or get_content_type(filename)` treats as
// "no override".
split_file_upload_arg :: proc(value: string) -> (path: string, mime: string) {
	first := strings.index(value, SEPARATOR_FILE_UPLOAD_TYPE)
	if first < 0 {
		return value, ""
	}
	rest := value[first + len(SEPARATOR_FILE_UPLOAD_TYPE):]
	if second := strings.index(rest, SEPARATOR_FILE_UPLOAD_TYPE); second >= 0 {
		rest = rest[:second]
	}
	return value[:first], rest
}

// load_upload reads one `name@file` item — the reference's
// process_file_upload_arg (requestitems.py:147-161): `;type=` overrides the
// type, the path is expanded with `os.path.expanduser` and opened, and the type
// falls back to the extension's guess when the override is missing or empty
// ("`mime_type or get_content_type(filename)`"; an unguessable name carries no
// type at all, docs/PARITY.md §3.1).
@(private)
load_upload :: proc(
	name, raw_value, orig: string,
	env: Env_Info,
	allocator: mem.Allocator,
) -> (
	file: File_Item,
	message: string,
) {
	path, mime := split_file_upload_arg(raw_value)
	expanded, expanded_ok := expand_user_path(path, env, allocator)
	if !expanded_ok {
		return {}, strings.clone("not enough memory", allocator) or_else ""
	}
	defer delete(expanded, allocator)
	contents, file_message := read_file_bytes(expanded, orig, allocator)
	if file_message != "" {
		return {}, file_message
	}
	// `mime_type or get_content_type(filename)`: the `;type=` override wins,
	// and a guess whose copy failed is reported rather than sent as a field
	// with no type (backlog M5).
	mime_value := mime
	guessed := ""
	if mime_value == "" {
		guess, guess_ok := guess_content_type(path, allocator)
		if !guess_ok {
			delete(contents, allocator)
			return {}, strings.clone("not enough memory", allocator) or_else ""
		}
		guessed, mime_value = guess, guess
	}
	owned := http.clone_into(&file.name, name, allocator) &&
	         // The basename of the *unexpanded* name: `os.path.basename(filename)`,
	         // so the part's filename-parameter is what the command line spelled.
	         http.clone_into(&file.filename, base_name(path), allocator) &&
	         http.clone_into(&file.path, expanded, allocator) &&
	         http.clone_into(&file.mime, mime_value, allocator)
	if !owned {
		// What was copied before the failure is released here, together with
		// the guess and the bytes the item would have carried (backlog M5).
		delete(file.name, allocator)
		delete(file.filename, allocator)
		delete(file.path, allocator)
		delete(file.mime, allocator)
		delete(guessed, allocator)
		delete(contents, allocator)
		return {}, strings.clone("not enough memory", allocator) or_else ""
	}
	delete(guessed, allocator)
	file.content = contents
	return file, ""
}

// expand_user_path is `os.path.expanduser` for the paths a file item names
// (posixpath.py:expanduser): `~` and `~/…` take $HOME, and a `~user` form the
// port cannot look up is left as it is. The reference resolves `~user` through
// the password database; that lookup is a libc call the CLI does not make
// (docs/ARCHITECTURE.md: only the transport talks to C), and the remainder is
// recorded in docs/PARITY.md §8.18. The result is owned by the caller.
@(private)
expand_user_path :: proc(name: string, env: Env_Info, allocator: mem.Allocator) -> (path: string, ok: bool) {
	if !strings.has_prefix(name, "~") {
		return http.clone_or_oom(name, allocator)
	}
	end := strings.index_byte(name, '/')
	if end < 0 {
		end = len(name)
	}
	home := ""
	have_home := false
	if end == 1 {
		home, have_home = env_get(env, "HOME")
	} else {
		// `~user`: posixpath looks the login up in the password database. The
		// port has no such lookup, so the `~`-form is the only one expanded.
		have_home = false
	}
	if !have_home {
		return http.clone_or_oom(name, allocator)
	}
	// `userhome = userhome.rstrip('/')`, then the path is glued back on; an
	// empty result is '/'. Both the join and the copy are reported rather
	// than read as the empty path, which is a path the reference never
	// produces (backlog M5).
	joined, join_err := strings.concatenate({strings.trim_right(home, "/"), name[end:]}, allocator)
	if join_err != .None {
		return "", false
	}
	if joined == "" {
		return http.clone_or_oom("/", allocator)
	}
	return joined, true
}

base_name :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			return path[i + 1:]
		}
	}
	return path
}

// guess_content_type is httpie's content type for a file field or a bare
// `@file` body: `mimetypes.guess_type(filename, strict=False)[0]`
// (utils.py:136-140), whose table is CPython's built-in maps overridden by the
// host's mime.types files. The port carries the subset the scenario matrix
// exercises (docs/PARITY.md §8.17 measures the difference); an extension
// outside it guesses nothing, exactly as the reference's `None` does — there is
// no octet-stream fallback anywhere in the reference. The returned string is
// owned by the caller and is "" when the extension says nothing.
guess_content_type :: proc(path: string, allocator: mem.Allocator) -> (mime: string, ok: bool) {
	lower := strings.to_lower(path, allocator)
	defer delete(lower, allocator)
	// Every entry of the table is a copy whose failure the caller reports:
	// an empty type means "the extension says nothing" to httpie, so the
	// absorbed error would send the file untyped (backlog M5). The last
	// return is that empty answer itself, with nothing to build.
	switch {
	case strings.has_suffix(lower, ".txt"):
		return http.clone_or_oom("text/plain", allocator)
	case strings.has_suffix(lower, ".json"):
		return http.clone_or_oom("application/json", allocator)
	case strings.has_suffix(lower, ".html"), strings.has_suffix(lower, ".htm"):
		return http.clone_or_oom("text/html", allocator)
	case strings.has_suffix(lower, ".xml"):
		return http.clone_or_oom("application/xml", allocator)
	case strings.has_suffix(lower, ".png"):
		return http.clone_or_oom("image/png", allocator)
	case strings.has_suffix(lower, ".jpg"), strings.has_suffix(lower, ".jpeg"):
		return http.clone_or_oom("image/jpeg", allocator)
	case strings.has_suffix(lower, ".gif"):
		return http.clone_or_oom("image/gif", allocator)
	case strings.has_suffix(lower, ".pdf"):
		return http.clone_or_oom("application/pdf", allocator)
	case strings.has_suffix(lower, ".bin"):
		return http.clone_or_oom("application/octet-stream", allocator)
	}
	return "", true
}

// ---------------------------------------------------------------------------
// File helpers (the error texts are Python's OSError strings)
// ---------------------------------------------------------------------------

// read_file_bytes is the raw reader used by every file item: it opens exactly
// the path it is given. `os.path.expanduser` belongs to the two wrappers below,
// where the reference applies it (requestitems.py:153-161 and 212-223).
@(private)
read_file_bytes :: proc(path: string, orig: string, allocator: mem.Allocator) -> (contents: []byte, message: string) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return nil, missing_file_message(orig, path, allocator)
	}
	return data, ""
}

// read_text_file is the reference's load_text_file (requestitems.py:212-223),
// the road every `=@`, `:@`, `:=@` and `==@` item takes: the path is expanded
// with `os.path.expanduser`, read as bytes, and *decoded* — `f.read().decode()`
// is a strict UTF-8 decode, so a file whose bytes are not UTF-8 is refused
// right here, as a ParseError (a usage block, rc 1, nothing on stdout). The
// bare `@file` body and a file field do not come through here: they keep the
// raw bytes (read_binary_file).
@(private)
read_text_file :: proc(
	path: string,
	orig: string,
	env: Env_Info,
	allocator: mem.Allocator,
) -> (
	contents: string,
	message: string,
) {
	expanded, expanded_ok := expand_user_path(path, env, allocator)
	if !expanded_ok {
		return "", strings.clone("not enough memory", allocator) or_else ""
	}
	defer delete(expanded, allocator)
	data, file_message := read_file_bytes(expanded, orig, allocator)
	if file_message != "" {
		return "", file_message
	}
	// `str.decode()` rejects exactly what a strict UTF-8 validator rejects: a
	// stray continuum, a truncated sequence, an overlong form, a surrogate
	// (U+D800-U+DFFF) and anything above U+10FFFF. `core:unicode/utf8`'s
	// validator is that rule (accept_ranges: the C0/C1 and F5-FF leads, the
	// ED A0-BF surrogate range and the F4 90+ range are all rejected).
	if !utf8.valid_string(string(data)) {
		delete(data, allocator)
		return "", cannot_embed_message(orig, path, allocator)
	}
	return string(data), ""
}

// read_binary_file is the same expansion for the roads whose bytes are not
// decoded: a bare `@file` body and a file field.
@(private)
read_binary_file :: proc(
	path: string,
	orig: string,
	env: Env_Info,
	allocator: mem.Allocator,
) -> (
	contents: []byte,
	message: string,
) {
	expanded, expanded_ok := expand_user_path(path, env, allocator)
	if !expanded_ok {
		return nil, strings.clone("not enough memory", allocator) or_else ""
	}
	defer delete(expanded, allocator)
	return read_file_bytes(expanded, orig, allocator)
}

// missing_file_message renders the OSError httpie prints for an unreadable
// file item: `'f=@/nope.txt': [Errno 2] No such file or directory: '/nope.txt'`
@(private)
missing_file_message :: proc(orig, path: string, allocator: mem.Allocator) -> string {
	errno, text := 2, "No such file or directory"
	switch {
	case os.is_dir(path):
		errno, text = 21, "Is a directory"
	}
	orig_repr := python_repr(orig, allocator)
	defer delete(orig_repr, allocator)
	path_repr := python_repr(path, allocator)
	defer delete(path_repr, allocator)
	return fmt.aprintf(
		"%s: [Errno %d] %s: %s",
		orig_repr,
		errno,
		text,
		path_repr,
		allocator = allocator,
	)
}

// cannot_embed_message is the other ParseError of the reference's text reader
// (requestitems.py:216-221), for a file that does not decode as UTF-8:
//
//	'note=@bad.txt': cannot embed the content of 'bad.txt', not a UTF-8 or
//	ASCII-encoded text file
//
// Both halves are `repr()`s of *argv strings*: `item.orig`, the item as the
// command line spelled it, and `item.value`, the path as spelled — the raw
// value, before `os.path.expanduser` turned `~` into $HOME. The port's
// python_repr spells a non-UTF-8 byte as the lone surrogate CPython's argv
// decode made of it, so a path with a bad byte in it matches too.
@(private)
cannot_embed_message :: proc(orig, value: string, allocator: mem.Allocator) -> string {
	orig_repr := python_repr(orig, allocator)
	defer delete(orig_repr, allocator)
	value_repr := python_repr(value, allocator)
	defer delete(value_repr, allocator)
	return fmt.aprintf(
		"%s: cannot embed the content of %s, not a UTF-8 or ASCII-encoded text file",
		orig_repr,
		value_repr,
		allocator = allocator,
	)
}

@(private)
rstrip_newlines :: proc(s: string, allocator: mem.Allocator) -> (text: string, ok: bool) {
	end := len(s)
	for end > 0 && s[end - 1] == '\n' {
		end -= 1
	}
	// The callers (the `:@`/`==@` arms of item_set_add) report the failure:
	// an empty header or query value is a legitimate item (backlog M5).
	return http.clone_or_oom(s[:end], allocator)
}

// python_repr renders a string the way Python's repr() renders it, which is
// what httpie splices into its error messages.
//
// repr() walks the string by *character*: a printable code point is copied as
// itself — `é` stays `é`, and the program then writes the two UTF-8 bytes the
// argv string holds — and a character that is *not* printable is escaped,
// `\xNN` below 0x100, `\uNNNN` below 0x10000 and `\UNNNNNNNN` above it, all
// lowercase, with the short escapes and the delimiter above taking precedence.
// `str_utf8_seq_len` is the port's walk of the same kind — a well-formed
// sequence is one code point, so no continuation byte is escaped — and the
// predicate is `http.str_is_printable`, CPython's `str.isprintable()` over the
// *reference interpreter's* Unicode database
// (src/http/unicode_printable_generated.odin): the `C*` and `Z*` categories
// apart from the ASCII space. That one rule covers the controls of
// t_b7f70eee's rows, the C1 controls, the format characters (U+200B, U+FEFF),
// the separators (U+00A0, U+3000, U+2028), the unassigned code points and the
// private-use ones; and it is why the walk cannot be a byte test — U+00A1 and
// the C1 control U+0085 are the same `0xc2` lead byte, and only the first is
// printable.
//
// A byte that starts no sequence at all is the one case where the port has to
// do more than copy: CPython's argv decode (surrogateescape) made that byte the
// lone surrogate U+DC80+byte, and repr() spells a lone surrogate `\udcXX`. So
// the reference quotes `a:=\xff` as `'a:=\udcff'` — the same string the port
// would otherwise print with the byte in it (httpie/cli/requestitems.py:230,
// `f'{arg.orig!r}: {e}'`).
//
// The delimiter and the backslash are escaped as CPython escapes them. The http
// package's copy of the same spelling (src/http/header_validity.odin:python_str_repr)
// walks the sequence the same way, but escapes Python's *whitespace* characters
// above 0x7f and copies every other code point: the only strings it renders are
// ones its own rule refused for a whitespace character, and that set is a
// subset of this one, so the two agree wherever both are reachable
// (build/probe_header_c1.py).
python_repr :: proc(s: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	quote := byte('\'')
	if strings.contains_rune(s, '\'') && !strings.contains_rune(s, '"') {
		quote = '"'
	}
	strings.write_byte(&builder, quote)
	for i := 0; i < len(s); {
		c := s[i]
		if c >= 0x80 {
			// A well-formed sequence is one code point, and the escape it may
			// need is as wide as the code point: `\xNN` below 0x100, `\uNNNN`
			// below 0x10000 and `\UNNNNNNNN` above it.
			if width := http.str_utf8_seq_len(s[i:]); width > 0 {
				code, _ := utf8.decode_rune_in_string(s[i:i + width])
				if !http.str_is_printable(code) {
					switch {
					case code < 0x100:
						fmt.sbprintf(&builder, "\\x%02x", int(code))
					case code < 0x10000:
						fmt.sbprintf(&builder, "\\u%04x", int(code))
					case:
						fmt.sbprintf(&builder, "\\U%08x", int(code))
					}
					i += width
					continue
				}
				strings.write_string(&builder, s[i:i + width])
				i += width
				continue
			}
			fmt.sbprintf(&builder, "\\u%04x", int(0xdc00) + int(c))
			i += 1
			continue
		}
		switch c {
		case '\\':
			strings.write_string(&builder, "\\\\")
		case '\n':
			strings.write_string(&builder, "\\n")
		case '\r':
			strings.write_string(&builder, "\\r")
		case '	':
			strings.write_string(&builder, "\\t")
		case:
			// Every other byte below 0x20 and DEL are non-printable too, and
			// repr() spells a non-printable code point below 0x100 as `\xNN`
			// with two lowercase hex digits — `'\x01'`, `'\x7f'`.
			if c < 0x20 || c == 0x7f {
				fmt.sbprintf(&builder, "\\x%02x", int(c))
			} else {
				if c == quote {
					strings.write_byte(&builder, '\\')
				}
				strings.write_byte(&builder, c)
			}
		}
		i += 1
	}
	strings.write_byte(&builder, quote)
	return strings.to_string(builder)
}

// ---------------------------------------------------------------------------
// Nested JSON (bracket) paths
// ---------------------------------------------------------------------------

// Path_Action mirrors httpie's PathAction.
Path_Action :: enum {
	Key,
	Index,
	Append,
	Set,
}

// Path is one bracket step of a nested item key.
Path :: struct {
	action:   Path_Action,
	accessor: string, // Key: the key text; Index: the index digits ("" when absent)
	start:    int, // byte range of this step inside the key, for the ^^^ marker
	end:      int,
}

// apply_nested_json folds one data item into `root` following httpie's
// bracket-path semantics (docs/PARITY.md §3.3). The error message is the body
// of the `HTTPie Syntax Error:`/`HTTPie Type Error:` block.
apply_nested_json :: proc(root: ^format.Value, item: ^Data_Item, allocator: mem.Allocator) -> (message: string) {
	paths, paths_message := parse_nested_path(item.key, allocator)
	if paths_message != "" {
		return paths_message
	}
	defer {
		for path in paths {
			delete(path.accessor, allocator)
		}
		delete(paths, allocator)
	}

	cursor := root
	for i in 0 ..< len(paths) {
		path := paths[i]
		is_last := i == len(paths) - 1

		switch path.action {
		case .Key:
			if !is_object_or_null(cursor) {
				return type_error(item, paths[:i], path, cursor, "key", "object", allocator)
			}
			if is_last {
				object_set(cursor, path.accessor, clone_value(&item.value, allocator), allocator)
				return ""
			}
			cursor = object_child(cursor, path.accessor, paths[i + 1].action, allocator)
		case .Index:
			if !is_array_or_null(cursor) {
				return type_error(item, paths[:i], path, cursor, "index", "array", allocator)
			}
			index, ok := strconv.parse_int(path.accessor)
			if !ok || index < 0 {
				return syntax_error_text(item.key, path.start, path.end, "Negative indexes are not supported.", allocator)
			}
			ensure_array_index(cursor, index, allocator)
			if is_last {
				array_set(cursor, index, clone_value(&item.value, allocator), allocator)
				return ""
			}
			cursor = array_child(cursor, index, paths[i + 1].action, allocator)
		case .Append:
			if !is_array_or_null(cursor) {
				return type_error(item, paths[:i], path, cursor, "append", "array", allocator)
			}
			if is_last {
				array_append(cursor, clone_value(&item.value, allocator), allocator)
				return ""
			}
			array_append(cursor, empty_for(paths[i + 1].action), allocator)
			cursor = array_child(cursor, array_len(cursor) - 1, paths[i + 1].action, allocator)
		case .Set:
			return ""
		}
	}
	return ""
}

@(private)
is_object_or_null :: proc(root: ^format.Value) -> bool {
	#partial switch v in root^ {
	case format.Null:
		return true
	case format.Object:
		return true
	}
	return false
}

@(private)
is_array_or_null :: proc(root: ^format.Value) -> bool {
	#partial switch v in root^ {
	case format.Null:
		return true
	case []format.Value:
		return true
	}
	return false
}

@(private)
empty_for :: proc(action: Path_Action) -> format.Value {
	switch action {
	case .Key:
		object: format.Object
		return object
	case .Index, .Append:
		empty: []format.Value
		return empty
	case .Set:
		return format.Null{}
	}
	return format.Null{}
}

// M5 KEEP (this proc, clone_member, object_child and object_set below): every
// one of them *builds* a `format.Value` — they answer a value, not a status —
// and the copies they make are read back by the nested-path drill, which is
// called from the `:=` item path and recursively from here. Reporting a failed
// copy means giving the whole drill a failure channel (clone_value →
// clone_member → object_set/array_set → apply_nested_json); that is this
// sweep's recorded residual in docs/rating/HTThor-remediation-backlog.md rather
// than a half-threaded bool. Each site says so in one line.
@(private)
clone_value :: proc(v: ^format.Value, allocator: mem.Allocator) -> format.Value {
	#partial switch value in v^ {
	case string:
		return strings.clone(value, allocator) or_else "" // M5 keep: see above.
	case format.Surrogate_String:
		// The marks are owned like the text: a clone that shared them would be
		// freed twice, so both halves are copied.
		marks := make([]format.Surrogate_Mark, len(value.marks), allocator)
		copy(marks, value.marks)
		return format.Surrogate_String {
			text  = strings.clone(value.text, allocator) or_else "", // M5 keep: see above.
			marks = marks,
		}
	case format.Object:
		// A frozen `:=` object owns two lists that both have to be copied: the
		// pairs it renders and the live dict a later write lands in. Sharing
		// either would free it twice.
		pairs := make([]format.Member, len(value.frozen_pairs), allocator)
		for i in 0 ..< len(value.frozen_pairs) {
			pairs[i] = clone_member(&value.frozen_pairs[i], allocator)
		}
		members := make([]format.Member, len(value.members), allocator)
		for i in 0 ..< len(value.members) {
			members[i] = clone_member(&value.members[i], allocator)
		}
		return format.Object {
			members = members,
			frozen = value.frozen,
			frozen_pairs = pairs,
		}
	case []format.Value:
		items := make([]format.Value, len(value), allocator)
		for i in 0 ..< len(value) {
			items[i] = clone_value(&value[i], allocator)
		}
		return items
	}
	return v^
}

// clone_member deep-copies one member of an object (its key, the key's
// out-of-band surrogates and its value) into `allocator`.
@(private)
clone_member :: proc(member: ^format.Member, allocator: mem.Allocator) -> format.Member {
	key_marks := make([]format.Surrogate_Mark, len(member.key_marks), allocator)
	copy(key_marks, member.key_marks)
	return format.Member {
		key       = strings.clone(member.key, allocator) or_else "", // M5 keep: see clone_value.
		key_marks = key_marks,
		value     = clone_value(&member.value, allocator),
	}
}

// object_child returns a pointer to the child at `key`, creating a container of
// the type the next path step needs when it is absent (httpie's
// `setdefault(..., object_for(next_path.kind))`).
@(private)
object_child :: proc(root: ^format.Value, key: string, next: Path_Action, allocator: mem.Allocator) -> ^format.Value {
	if _, is_null := root^.(format.Null); is_null {
		root^ = format.Object{members = make([]format.Member, 0, allocator)}
	}
	object := &root.(format.Object)
	if index := format.object_find(object, key); index >= 0 {
		return &object.members[index].value
	}
	members := make([]format.Member, len(object.members) + 1, allocator)
	for i in 0 ..< len(object.members) {
		members[i] = object.members[i]
	}
	members[len(object.members)] = format.Member {
		key   = strings.clone(key, allocator) or_else "", // M5 keep: see clone_value.
		value = empty_for(next),
	}
	delete(object.members, allocator)
	object.members = members
	return &object.members[len(members) - 1].value
}

@(private)
object_set :: proc(root: ^format.Value, key: string, value: format.Value, allocator: mem.Allocator) {
	if _, is_null := root^.(format.Null); is_null {
		root^ = format.Object{members = make([]format.Member, 0, allocator)}
	}
	object := &root.(format.Object)
	if index := format.object_find(object, key); index >= 0 {
		format.value_destroy(&object.members[index].value, allocator)
		object.members[index].value = value
		return
	}
	members := make([]format.Member, len(object.members) + 1, allocator)
	for i in 0 ..< len(object.members) {
		members[i] = object.members[i]
	}
	members[len(object.members)] = format.Member {
		key   = strings.clone(key, allocator) or_else "", // M5 keep: see clone_value.
		value = value,
	}
	delete(object.members, allocator)
	object.members = members
}

@(private)
array_len :: proc(root: ^format.Value) -> int {
	if items, ok := root^.([]format.Value); ok {
		return len(items)
	}
	return 0
}

@(private)
ensure_array_index :: proc(root: ^format.Value, index: int, allocator: mem.Allocator) {
	if _, is_null := root^.(format.Null); is_null {
		empty: []format.Value
		root^ = empty
	}
	items := &root.([]format.Value)
	if index < len(items^) {
		return
	}
	grown := make([]format.Value, index + 1, allocator)
	for i in 0 ..< len(items^) {
		grown[i] = items^[i]
	}
	for i in len(items^) ..< len(grown) {
		grown[i] = format.Null{}
	}
	delete(items^, allocator)
	items^ = grown
}

@(private)
array_set :: proc(root: ^format.Value, index: int, value: format.Value, allocator: mem.Allocator) {
	items := &root.([]format.Value)
	format.value_destroy(&items^[index], allocator)
	items^[index] = value
}

@(private)
array_append :: proc(root: ^format.Value, value: format.Value, allocator: mem.Allocator) {
	if _, is_null := root^.(format.Null); is_null {
		empty: []format.Value
		root^ = empty
	}
	items := &root.([]format.Value)
	grown := make([]format.Value, len(items^) + 1, allocator)
	for i in 0 ..< len(items^) {
		grown[i] = items^[i]
	}
	grown[len(items^)] = value
	delete(items^, allocator)
	items^ = grown
}

@(private)
array_child :: proc(root: ^format.Value, index: int, next: Path_Action, allocator: mem.Allocator) -> ^format.Value {
	items := &root.([]format.Value)
	if _, is_null := items^[index].(format.Null); is_null {
		items^[index] = empty_for(next)
	}
	return &items^[index]
}

// parse_nested_path tokenises a nested item key into paths (httpie's
// nested_json.parse). Every accessor is owned by `allocator`; the caller frees
// the slice and its accessors. `message` is empty on success.
parse_nested_path :: proc(key: string, allocator: mem.Allocator) -> (paths: []Path, message: string) {
	result := make([dynamic]Path, 0, 4, allocator)

	// root_path: literal | index_path | append_path
	i := 0
	root_start := i
	for i < len(key) && key[i] != '[' && key[i] != ']' {
		i += 1
	}
	if i > root_start {
		accessor, accessor_ok := unescape_key(key[root_start:i], allocator)
		if !accessor_ok {
			return nil, nested_path_oom(&result, allocator)
		}
		append(&result, Path {
			action   = .Key,
			accessor = accessor,
			start    = root_start,
			end      = i,
		})
	} else if i < len(key) && key[i] == '[' {
		open := i
		i += 1
		inner_start := i
		for i < len(key) && key[i] != ']' {
			i += 1
		}
		if i >= len(key) {
			return nil, syntax_error_text(key, i, i + 1, "Expecting ']'", allocator)
		}
		inner := key[inner_start:i]
		i += 1
		if inner == "" {
			append(&result, Path{action = .Append, start = open, end = i})
		} else {
			accessor, accessor_ok := http.clone_or_oom(inner, allocator)
			if !accessor_ok {
				return nil, nested_path_oom(&result, allocator)
			}
			append(&result, Path {
				action   = .Index,
				accessor = accessor,
				start    = open,
				end      = i,
			})
		}
	} else {
		// An empty root (e.g. `[0]=x`): httpie yields an empty TEXT root path.
		// Its accessor is the empty string itself rather than a copy of it:
		// there is nothing to allocate, so nothing that could fail (backlog M5).
		append(&result, Path {
			action   = .Key,
			accessor = "",
			start    = 0,
			end      = 0,
		})
	}

	// path*
	for i < len(key) {
		if key[i] != '[' {
			break
		}
		open := i
		i += 1
		inner_start := i
		for i < len(key) && key[i] != ']' {
			i += 1
		}
		if i >= len(key) {
			return nil, syntax_error_text(key, i, i + 1, "Expecting ']'", allocator)
		}
		inner := key[inner_start:i]
		i += 1
		if inner == "" {
			append(&result, Path{action = .Append, start = open, end = i})
		} else if _, is_number := strconv.parse_int(inner); is_number {
			accessor, accessor_ok := http.clone_or_oom(inner, allocator)
			if !accessor_ok {
				return nil, nested_path_oom(&result, allocator)
			}
			append(&result, Path {
				action   = .Index,
				accessor = accessor,
				start    = open,
				end      = i,
			})
		} else {
			accessor, accessor_ok := unescape_key(inner, allocator)
			if !accessor_ok {
				return nil, nested_path_oom(&result, allocator)
			}
			append(&result, Path {
				action   = .Key,
				accessor = accessor,
				start    = open,
				end      = i,
			})
		}
	}
	return result[:], ""
}

// nested_path_oom reports a copy that could not be made while a nested key was
// being tokenised: the paths built so far are released here (the success path
// hands them to the caller, which frees them), and the message is the parser's
// own out-of-memory wording -- empty only if that copy fails too (backlog M5).
@(private)
nested_path_oom :: proc(result: ^[dynamic]Path, allocator: mem.Allocator) -> string {
	for path in result^ {
		delete(path.accessor, allocator)
	}
	delete(result^)
	return strings.clone("not enough memory", allocator) or_else ""
}

// unescape_key is the bracket-path reader's own backslash rule (httpie's
// nested_json `_unescape`); the copy it makes is reported, because an empty
// accessor is a legitimate key (backlog M5).
@(private)
unescape_key :: proc(s: string, allocator: mem.Allocator) -> (text: string, ok: bool) {
	if !strings.contains(s, "\\") {
		return http.clone_or_oom(s, allocator)
	}
	builder := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case '[', ']', '\\':
				i += 1
			}
		}
		strings.write_byte(&builder, s[i])
	}
	text = strings.to_string(builder)
	if text == "" {
		// A key that carries a backslash writes at least one byte, so an
		// empty answer is the allocation that failed (backlog M5).
		return "", false
	}
	return text, true
}

// syntax_error_text renders the `HTTPie Syntax Error:` block httpie prints for
// a token span (docs/PARITY.md §3.3). The result is owned by `allocator`; the
// caller appends the single trailing newline the reference's error printer
// adds.
syntax_error_text :: proc(source: string, start, end: int, reason: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	fmt.sbprintf(&builder, "HTTPie Syntax Error: %s\n", reason)
	fmt.sbprintf(&builder, "%s\n", source)
	for _ in 0 ..< start {
		strings.write_byte(&builder, ' ')
	}
	for _ in 0 ..< max(end - start, 1) {
		strings.write_byte(&builder, '^')
	}
	return strings.to_string(builder)
}

@(private)
type_error :: proc(
	item: ^Data_Item,
	paths_before: []Path,
	failing: Path,
	current: ^format.Value,
	action: string,
	required: string,
	allocator: mem.Allocator,
) -> string {
	// The reference's type name is `JSON_TYPE_MAPPING.get(type(cursor),
	// type(cursor).__name__)` (interpret.py:14-20, :47): only dict/list/int/
	// float/str are *mapped*, every other cursor prints its own Python class
	// name. So a JSON boolean is `bool` — Python's name, not `boolean` — and a
	// `:=`/`:=@` object, which the reference materialises as
	// `JsonDictPreservingDuplicateKeys` (utils.py:27-71), prints that class
	// name. `format.Object.frozen` is exactly that distinction: true for an
	// object json.loads produced, false for one the bracket interpreter built
	// itself (`empty_for`), which the reference sees as a plain `dict` and
	// which must keep printing `object` (docs/PARITY.md §3.3).
	actual := "object"
	#partial switch v in current^ {
	case []format.Value:
		actual = "array"
	case string, format.Surrogate_String:
		// A string that carries an out-of-band surrogate is the reference's
		// `str` like any other, so a path through it reports "string".
		actual = "string"
	case i64, f64:
		actual = "number"
	case bool:
		actual = "bool"
	case format.Object:
		actual = v.frozen ? "JsonDictPreservingDuplicateKeys" : "object"
	case format.Null:
		actual = "null"
	}
	// httpie's wording, verbatim: the action and the reconstructed prefix are
	// Python reprs, so they carry single quotes.
	//
	// `reconstruct_paths` hands back the builder's own buffer, so the prefix is
	// freed here: it is formatted into the message and nothing else holds it.
	// Without this free every type error leaked those bytes — the 23 bytes
	// the suite's `item-json-frozen-error` case reports, on the road
	// this card's rule makes reachable (the reference reads a dropped write back
	// and refuses it, so `a:={"b": 1}` `a[c]:=3` `a[c][d]:=4` now ends in a type
	// error where before the port had no error at all).
	reconstructed := reconstruct_paths(paths_before, allocator)
	defer delete(reconstructed, allocator)
	builder := strings.builder_make(allocator)
	fmt.sbprintf(
		&builder,
		"HTTPie Type Error: Cannot perform '%s' based access on '%s' which has a type of '%s' but this operation requires a type of '%s'.\n",
		action,
		reconstructed,
		actual,
		required,
	)
	fmt.sbprintf(&builder, "%s\n", item.key)
	for _ in 0 ..< failing.start {
		strings.write_byte(&builder, ' ')
	}
	for _ in 0 ..< max(failing.end - failing.start, 1) {
		strings.write_byte(&builder, '^')
	}
	return strings.to_string(builder)
}

@(private)
reconstruct_paths :: proc(paths: []Path, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	for path, i in paths {
		switch path.action {
		case .Key:
			if i == 0 {
				strings.write_string(&builder, path.accessor)
			} else {
				fmt.sbprintf(&builder, "[%s]", path.accessor)
			}
		case .Index:
			fmt.sbprintf(&builder, "[%s]", path.accessor)
		case .Append:
			strings.write_string(&builder, "[]")
		case .Set:
		}
	}
	return strings.to_string(builder)
}

// ---------------------------------------------------------------------------
// Cross-item rules and the JSON data tree
// ---------------------------------------------------------------------------

// COMPLEX_JSON_IN_FORM_MESSAGE is httpie's ParseError for a `:=` value that
// cannot be represented in a form body (cli/requestitems.py:184).
COMPLEX_JSON_IN_FORM_MESSAGE :: "Cannot use complex JSON value types with --form/--multipart."

// BODY_MIXED_MESSAGE is httpie's wording for a request with more than one body
// source (docs/PARITY.md §3.5). It is one sentence and one line in the source;
// the reference's error printer wraps it into three lines.
BODY_MIXED_MESSAGE :: "Request body (from stdin, --raw or a file) and request data (key=value) cannot be mixed. Pass --ignore-stdin to let key/value take priority. See https://httpie.io/docs#scripting for details."

// item_set_validate applies the cross-item rules: without --form/--multipart
// every `@file` item has to be the single bare one — the body — and at most one
// body source may be present (stdin / --raw / a file field / key=value data).
// `message` is empty when the set is legal.
item_set_validate :: proc(
	set: ^Item_Set,
	form_like: bool,
	raw_given: bool,
	stdin_body: bool,
) -> (message: string) {
	// The file-list check of _parse_items (argparser.py:470-489), which walks
	// `args.files` in command-line order: a named file field is the "perhaps you
	// meant --form?" error — whose message lists *every* key, the empty ones of
	// the bare `@file`s included, joined with a bare comma — and a second bare
	// `@file` is "Can't read request from multiple files".
	if !form_like && len(set.file_keys) > 0 {
		seen_bare := false
		for key in set.file_keys {
			if key != "" {
				builder := strings.builder_make(set.allocator)
				strings.write_string(&builder, "Invalid file fields (perhaps you meant --form?): ")
				for other, i in set.file_keys {
					if i > 0 {
						strings.write_string(&builder, ",")
					}
					strings.write_string(&builder, other)
				}
				return strings.to_string(builder)
			}
			if seen_bare {
				return strings.clone("Can't read request from multiple files", set.allocator) or_else ""
			}
			seen_bare = true
		}
	}
	// A file field is the fourth source the reference's _ensure_one_data_source
	// sees (argparser.py:382-398): `_body_from_file`/`_body_from_input` pass it
	// and reject it next to stdin or --raw. With `--form`/`--multipart` the
	// fields survive into the request, so a piped stdin or a `--raw` value
	// cannot come with them; the bare `@file` of a non-form command line is
	// `body_file_given` below instead (the reference clears `args.files` before
	// reading it).
	if (raw_given || stdin_body) && len(set.files) > 0 {
		return strings.clone(BODY_MIXED_MESSAGE, set.allocator) or_else ""
	}
	sources := 0
	if set.body_file_given {
		sources += 1
	}
	if raw_given {
		sources += 1
	}
	if stdin_body {
		sources += 1
	}
	if set.has_data {
		sources += 1
	}
	if sources > 1 {
		return strings.clone(BODY_MIXED_MESSAGE, set.allocator) or_else ""
	}
	return ""
}

// item_set_json_data folds the data items into one JSON value in command-line
// order, applying the bracket paths of docs/PARITY.md §3.3. The result is what
// the JSON request body serialises (`--json`, the default). On a nested-path
// error the partially built tree is released and `message` carries the
// `HTTPie Syntax Error:`/`HTTPie Type Error:` block body.
item_set_json_data :: proc(set: ^Item_Set, allocator: mem.Allocator) -> (root: format.Value, message: string) {
	root = format.Object{members = make([]format.Member, 0, allocator)}
	for i in 0 ..< len(set.data) {
		message = apply_nested_json(&root, &set.data[i], allocator)
		if message != "" {
			format.value_destroy(&root, allocator)
			return format.Null{}, message
		}
	}
	return root, ""
}
