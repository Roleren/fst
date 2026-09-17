"""Row-append interoperability, cooperative locking and injected write failure."""
import fcntl
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile

root = Path.cwd().resolve()
fork_env = dict(os.environ, R_LIBS=str(root / "R-library"))
upstream_env = dict(os.environ)
upstream_env.pop("R_LIBS", None)


def run(code, env=fork_env, preexec_fn=None):
    result = subprocess.run(["Rscript", "-e", code], env=env, text=True,
                            capture_output=True, preexec_fn=preexec_fn)
    if result.returncode:
        raise RuntimeError(f"R failed ({result.returncode}): {result.stdout}\n{result.stderr}")
    print(result.stdout.strip(), flush=True)


with tempfile.TemporaryDirectory(dir=root / "benchmarks") as directory:
    path, export = Path(directory) / "test.fst", Path(directory) / "export.fst"
    p, q = repr(str(path)), repr(str(export))
    run(f'library(fst); write_fst(data.frame(a=1:100), {p}); '
        'cat("Upstream writer:", as.character(packageVersion("fstcore")), "\\n")', upstream_env)
    original = path.read_bytes()
    with path.open("r+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for call in [f'append_rows_fst(data.frame(a=101:200), {p})',
                     f'append_columns_fst(data.frame(b=101:200), {p})']:
            run(f'library(fst); e <- tryCatch({call}, error=identity); '
                'stopifnot(inherits(e,"error"), grepl("lock",conditionMessage(e))); '
                'cat("Cooperative lock exclusion: PASS\\n")')
            assert path.read_bytes() == original
    run(f'library(fst); append_rows_fst(data.frame(a=101:200), {p}); '
        f'stopifnot(identical(read_fst({p}), data.frame(a=1:200))); '
        f'write_fst(read_fst({p}), {q}); cat("Append upstream file / export: PASS\\n")')
    run(f'library(fst); e <- tryCatch(read_fst({p}),error=identity); '
        'stopifnot(inherits(e,"error"), grepl("newer version",conditionMessage(e))); '
        f'stopifnot(identical(read_fst({q}), data.frame(a=1:200))); '
        'cat("Upstream rejects version 3 and reads version 1 export: PASS\\n")', upstream_env)
    committed = path.read_bytes()

    def limit_file_size():
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (len(committed) + 512, len(committed) + 512))

    run(f'library(fst); e <- tryCatch(append_rows_fst(data.frame(a=201:10000), {p}, compress=0),error=identity); '
        'stopifnot(inherits(e,"error")); cat("Injected write failure:",conditionMessage(e),"\\n")',
        preexec_fn=limit_file_size)
    assert path.read_bytes()[:len(committed)] == committed
    run(f'library(fst); stopifnot(identical(read_fst({p}), data.frame(a=1:200))); '
        f'append_rows_fst(data.frame(a=201:300), {p}); '
        f'stopifnot(identical(read_fst({p}), data.frame(a=1:300))); '
        'cat("Failed append preserves committed table; subsequent append succeeds: PASS\\n")')
