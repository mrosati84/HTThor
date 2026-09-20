// urllib3's skippable headers and its SKIP_HEADER sentinel — the two constants
// httpie borrows so that a header it must not send is still "set" in the dict
// it hands to `requests`.
//
//     urllib3/util/request.py:17-19
//         SKIPPABLE_HEADERS = {"accept-encoding", "host", "user-agent"}
//         SKIP_HEADER = "@@@SKIP_HEADER@@@"
//     urllib3/connection.py:477-487
//         putheader writes nothing when a value is the sentinel, and raises
//         ValueError when the name is not one of the three above
//
// httpie uses it for the one case where a header has to disappear while the
// name stays in the dict: an item that *unsets* one of those three names
// (`Name:` with an empty value) becomes `None` in `args.headers`, and
// `finalize_headers` turns a `None` of a skippable name into the sentinel
// instead of dropping the pair (client.py:190-209). Everything downstream then
// agrees without a second rule: the rendered head drops the line
// (models.py:153-157) and urllib3 does not write it (putheader above).
//
// The set lives in this package because both sides need it and neither can own
// it: the renderer, the session and the transport. `output` renders the
// sentinel, `session` records it in the session file and `http` decides whether
// libcurl's own header of that name has to be suppressed with a `Name:` removal
// entry.
package http

import "core:strings"

// SKIPPABLE_HEADERS is urllib3's set (urllib3/util/request.py:17-18): names
// urllib3 would add a header of its own for, which is why a caller can switch
// them off with the sentinel rather than by omitting them.
SKIPPABLE_HEADERS :: [?]string{"accept-encoding", "host", "user-agent"}

// SKIP_HEADER is urllib3's sentinel (urllib3/util/request.py:19).
SKIP_HEADER :: "@@@SKIP_HEADER@@@"

// is_skippable_header is `name.lower() in SKIPPABLE_HEADERS`. Header names
// compare case-insensitively everywhere else in the port, which is what
// urllib3's `.lower()` does for these three ASCII names.
is_skippable_header :: proc(name: string) -> bool {
	for candidate in SKIPPABLE_HEADERS {
		if strings.equal_fold(candidate, name) {
			return true
		}
	}
	return false
}
