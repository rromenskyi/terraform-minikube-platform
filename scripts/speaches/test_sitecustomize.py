"""Tests for the speaches ONNX thread hook (sitecustomize.py next to this file).

The hook acts at interpreter start, so every case runs a fresh Python with this
directory on PYTHONPATH, the way the speaches container does. Needs
onnxruntime and onnx:

    uv run --with onnxruntime --with onnx python -m unittest scripts/speaches/test_sitecustomize.py
"""

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

import onnx
from onnx import TensorProto, helper

HERE = os.path.dirname(os.path.abspath(__file__))


def _identity_model(path):
    tensor = helper.make_tensor_value_info("x", TensorProto.FLOAT, [1])
    out = helper.make_tensor_value_info("y", TensorProto.FLOAT, [1])
    graph = helper.make_graph([helper.make_node("Identity", ["x"], ["y"])], "identity", [tensor], [out])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
    model.ir_version = 8
    onnx.save(model, path)


class OnnxThreadHookTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.model = os.path.join(cls.tmp.name, "identity.onnx")
        _identity_model(cls.model)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_python(self, code, threads=None):
        env = {k: v for k, v in os.environ.items() if k != "ONNX_SESSION_THREADS"}
        env["PYTHONPATH"] = HERE
        if threads is not None:
            env["ONNX_SESSION_THREADS"] = threads
        proc = subprocess.run(
            [sys.executable, "-c", textwrap.dedent(code)],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(proc.stdout), proc.stderr

    def session_threads(self, setup, threads=None):
        """Builds a session with `setup` and returns (intra, inter, stderr)."""
        code = f"""
            import json
            import onnxruntime as ort
            from onnxruntime import InferenceSession
            model = {self.model!r}
            {setup}
            opts = sess.get_session_options()
            print(json.dumps([opts.intra_op_num_threads, opts.inter_op_num_threads]))
        """
        (intra, inter), stderr = self.run_python(code, threads)
        return intra, inter, stderr

    def test_session_without_options_gets_the_thread_count(self):
        intra, inter, _ = self.session_threads("sess = InferenceSession(model, providers=['CPUExecutionProvider'])", "3")
        self.assertEqual((intra, inter), (3, 3))

    def test_module_attribute_is_patched_too(self):
        intra, inter, _ = self.session_threads("sess = ort.InferenceSession(model)", "2")
        self.assertEqual((intra, inter), (2, 2))

    def test_default_options_object_gets_the_thread_count(self):
        intra, inter, _ = self.session_threads("sess = InferenceSession(model, sess_options=ort.SessionOptions())", "4")
        self.assertEqual((intra, inter), (4, 4))

    def test_explicit_counts_are_left_alone(self):
        setup = (
            "o = ort.SessionOptions(); o.intra_op_num_threads = 1; o.inter_op_num_threads = 1; "
            "sess = InferenceSession(model, o)"
        )
        intra, inter, _ = self.session_threads(setup, "3")
        self.assertEqual((intra, inter), (1, 1))

    def test_one_explicit_count_keeps_it_and_fills_the_other(self):
        setup = "o = ort.SessionOptions(); o.intra_op_num_threads = 5; sess = InferenceSession(model, sess_options=o)"
        intra, inter, _ = self.session_threads(setup, "3")
        self.assertEqual((intra, inter), (5, 3))

    def test_without_the_var_sessions_and_imports_are_untouched(self):
        (loaded,), _ = self.run_python("import json, sys; print(json.dumps(['onnxruntime' in sys.modules]))")
        self.assertFalse(loaded)
        intra, inter, _ = self.session_threads("sess = InferenceSession(model)")
        self.assertEqual((intra, inter), (0, 0))

    def test_empty_var_is_the_same_as_unset(self):
        intra, inter, stderr = self.session_threads("sess = InferenceSession(model)", "")
        self.assertEqual((intra, inter), (0, 0))
        self.assertEqual(stderr, "")

    def test_bad_value_warns_and_leaves_sessions_alone(self):
        for bad in ("two", "0", "-1", "1.5"):
            with self.subTest(value=bad):
                intra, inter, stderr = self.session_threads("sess = InferenceSession(model)", bad)
                self.assertEqual((intra, inter), (0, 0))
                self.assertIn("ONNX_SESSION_THREADS", stderr)


if __name__ == "__main__":
    unittest.main()
