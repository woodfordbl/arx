// http.c: one HTTP request, start to end, on top of the platform's
// HttpStart and HttpFinish (curl natively, fetch in the browser). Model
// calls and `arx request` both come through here.

#include <errno.h>
#include <string.h>

#include "src/base/base.h"

// Runs a request to the end; see base.h.
int HttpRun(const HttpRequest* req, HttpResult* r) {
  ProcChild* c = HttpStart(req);
  if (!c) {
    int e = errno;
    memset(r, 0, sizeof(*r));
    r->retry_after = -1;
    r->net_error = -1;
    r->spawn_failed = 1;
    BufferAppendStr(&r->err, strerror(e));
    return -1;
  }
  while (!ProcDone(c)) ProcPoll(&c, 1, 0.1);
  HttpFinish(c, r);
  return 0;
}
