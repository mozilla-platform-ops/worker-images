"""uv run scripts/cache-seeds/test_benchmark.py"""

from pathlib import Path
import sys
import tempfile
import unittest

from benchmark import benchmark


class BenchmarkTest(unittest.TestCase):
    def test_cold_seeded_and_replaced_store(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            store = root / "store"
            checkout = root / "checkout"
            command = [sys.executable, "-c",
                       "from pathlib import Path; import sys; "
                       "Path(sys.argv[1]).mkdir(parents=True); "
                       "Path(sys.argv[2]).mkdir(parents=True, exist_ok=True); "
                       "(Path(sys.argv[1]) / 'sharedpath').write_text(sys.argv[2])",
                       str(checkout / ".hg"), str(store / ".hg")]
            self.assertTrue(benchmark(store, checkout, None, command)["passed"])
            with self.assertRaises(ValueError):
                benchmark(store, checkout, None, command)
            (checkout / ".hg/sharedpath").unlink()
            (checkout / ".hg").rmdir()
            checkout.rmdir()
            marker = store / ".hg/worker-image-seed"
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text("a" * 40 + "\n")
            with self.assertRaises(ValueError):
                benchmark(store, checkout, None, command)
            with self.assertRaises(ValueError):
                benchmark(store, checkout, "b" * 40, command)
            result = benchmark(store, checkout, "a" * 40, command)
            self.assertTrue(result["passed"])
            self.assertTrue(result["seed_reused"])
            (checkout / ".hg/sharedpath").unlink()
            (checkout / ".hg").rmdir()
            checkout.rmdir()
            replace = command.copy()
            replace[2] += "; Path(sys.argv[3]).unlink()"
            replace.append(str(marker))
            self.assertFalse(benchmark(store, checkout, "a" * 40, replace)["passed"])

    def test_wrong_store_and_failed_command(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for command in ([sys.executable, "-c", "raise SystemExit(1)"],
                            [sys.executable, "-c", "pass"]):
                self.assertFalse(benchmark(root / "store", root / "checkout", None,
                                           command)["passed"])


if __name__ == "__main__":
    unittest.main()
