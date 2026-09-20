// Package format turns bytes into a shape the output layer can render: it
// decides what a response body *is* from its Content-Type, and it carries the
// pretty-printing parameters the CLI collects.
//
// The renderers themselves (JSON pretty printing, ANSI styles, --format-options)
// land with the output task, t_9a017f57; this package is their home and the
// place the shared parameter types live.
package format

import "core:strings"

// Kind is what the output layer thinks a body is.
Kind :: enum {
	Unknown,
	Json,
	Form,
	Multipart,
	Xml,
	Html,
	Text,
	Binary,
}

// Indent is the JSON pretty-printing indent (--format-options json.indent, and
// what --pretty=format resolves to). Auto means "two spaces, as httpie does".
Indent :: enum {
	Auto,
	None,
	Two,
	Four,
	Tabs,
}

// kind_for_content_type maps a Content-Type header value to a Kind. The media
// type is compared case-insensitively and parameters (`; charset=utf-8`) are
// ignored.
kind_for_content_type :: proc(content_type: string) -> Kind {
	media_type := content_type
	if semi := strings.index(media_type, ";"); semi >= 0 {
		media_type = media_type[:semi]
	}
	media_type = strings.trim_space(media_type)

	switch {
	case strings.equal_fold(media_type, "application/json"),
	     strings.equal_fold(media_type, "text/json"),
	     strings.has_suffix(media_type, "+json"):
		return .Json
	case strings.equal_fold(media_type, "application/x-www-form-urlencoded"):
		return .Form
	case strings.equal_fold(media_type, "multipart/form-data"):
		return .Multipart
	case strings.equal_fold(media_type, "application/xml"),
	     strings.equal_fold(media_type, "text/xml"),
	     strings.has_suffix(media_type, "+xml"):
		return .Xml
	case strings.equal_fold(media_type, "text/html"):
		return .Html
	case strings.has_prefix(media_type, "text/"):
		return .Text
	case media_type == "":
		return .Unknown
	}
	return .Binary
}
