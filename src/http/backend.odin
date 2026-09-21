package http

import "core:io"

// Backend names the transport compiled into the binary. The scaffold ships
// exactly one: libcurl (see libcurl.odin, curl_transport.odin, and the
// "Transport" paragraph in README.md). A second backend would be added here and
// selected in the session.
Backend :: enum {
	Libcurl,
}

BACKEND :: Backend.Libcurl

// send performs the exchange described by `req` and buffers the reply into
// `res`. Ownership: `res` belongs to the caller, who frees it with
// response_destroy; its allocations come from req.allocator, so that is the
// allocator response_destroy needs. `res` must be zeroed before the call, and
// it is left zeroed when send returns an error.
//
// `req` is used as it stands: call request_prepare first, so that the body and
// the headers derived from it (Content-Length, Accept, Authorization,
// Content-Type) are in place.
send :: proc(req: ^Request, res: ^Response) -> Error {
	return send_to(req, res, nil)
}

// send_to is the download path: when `sink` is not nil the reply body is
// written to it as it arrives instead of being buffered, so a large download
// never has to fit in memory. A write failure aborts the transfer and is
// reported as Error.Write_Failed.
send_to :: proc(req: ^Request, res: ^Response, sink: Maybe(io.Writer)) -> Error {
	switch BACKEND {
	case .Libcurl:
		return transport_send(req, res, sink)
	}
	return .Not_Implemented
}
