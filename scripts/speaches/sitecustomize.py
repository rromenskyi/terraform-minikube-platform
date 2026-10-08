"""Size every ONNX Runtime session's thread pools from ONNX_SESSION_THREADS.

ONNX Runtime starts one intra-op thread per core it can see, not per core the
container may use, and reads no environment variable for it. speaches builds
its Piper and Kokoro sessions with no session options, so on a many-core node
under a 2-CPU limit those threads burn the CFS quota a few milliseconds into
each period and sit throttled for the rest: a 0.1 s sentence takes 2 s.

Python imports this module at interpreter start when its directory is on
PYTHONPATH (speaches.tf mounts it from a ConfigMap). With ONNX_SESSION_THREADS
set to a positive integer it wraps InferenceSession so that a session whose
options leave intra_op_num_threads or inter_op_num_threads at 0 (the "pick for
me" default) gets that count instead. A count the caller set is kept, e.g.
faster-whisper's VAD pins both to 1. The caller's SessionOptions object is
updated in place. With the variable unset or empty, nothing is imported or
changed.
"""

import functools
import os
import sys

_ENV_VAR = "ONNX_SESSION_THREADS"


def _threads_from_env():
    raw = os.environ.get(_ENV_VAR, "")
    if raw == "":
        return None
    try:
        count = int(raw)
    except ValueError:
        count = 0
    if count > 0:
        return count
    print(f"sitecustomize: ignoring {_ENV_VAR}={raw!r}, want a positive integer", file=sys.stderr)
    return None


def _install(threads):
    try:
        import onnxruntime
    except ImportError:
        return

    session = onnxruntime.InferenceSession
    original_init = session.__init__

    @functools.wraps(original_init)
    def __init__(self, path_or_bytes, sess_options=None, *args, **kwargs):
        if sess_options is None:
            sess_options = onnxruntime.SessionOptions()
        if sess_options.intra_op_num_threads == 0:
            sess_options.intra_op_num_threads = threads
        if sess_options.inter_op_num_threads == 0:
            sess_options.inter_op_num_threads = threads
        original_init(self, path_or_bytes, sess_options, *args, **kwargs)

    session.__init__ = __init__


_threads = _threads_from_env()
if _threads is not None:
    _install(_threads)
