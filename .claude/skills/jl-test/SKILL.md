---
name: jl-test
description: Run the Jayhawk Julia test suite and report a clean pass/fail summary. Use whenever you need to run, re-run, or check the tests in this repo — after editing anything in src/ or test/, before committing, or when asked "do the tests pass". Handles the output filtering that makes results readable.
---

# Running the Jayhawk test suite

## The command

Run from the repo root:

```bash
julia --project=. test/runtests.jl
```

~6 seconds. **Prefer this over `Pkg.test()`** — `julia --project=. -e 'using Pkg; Pkg.test()'`
does the same work but re-resolves the environment and spawns a second process, roughly
doubling the wall time for identical results. There is no `test/Project.toml`; test
dependencies (`Test`, `Serd`, `URIs`, `Logging`) resolve from the main `Project.toml`.

**The exit code is the signal.** 0 = all pass, 1 = something failed. Julia prints per-testset
summaries either way, so never judge by eyeballing the tail alone.

Beware that piping loses the exit code, and this environment's shell is **zsh**, where the
bash idiom `${PIPESTATUS[0]}` is silently empty — zsh spells it `${pipestatus[1]}`. The
portable move is to capture first and filter after:

```bash
julia --project=. test/runtests.jl > <scratchpad>/test.log 2>&1; echo "exit: $?"
grep -v -E '^[┌│└]' <scratchpad>/test.log
```

## Filtering the output

Output is ~450 lines, of which ~110 are harmless `Prefix already defined. Overwriting with
new value.` warnings emitted by Serd itself (not by Jayhawk) every time a test snippet
redeclares a prefix. They are noise. Strip the multi-line log blocks:

```bash
julia --project=. test/runtests.jl 2>&1 | grep -v -E '^[┌│└]'
```

For just the verdict:

```bash
julia --project=. test/runtests.jl 2>&1 | grep -E 'Test Summary|Fail|Error|did not pass' -A1
```

If output is still unwieldy, redirect to the scratchpad and grep the file rather than
re-running the suite.

## When something fails

Julia reports failures as `<testset name>: Test Failed at test/runtests.jl:<line>` followed
by `Expression:` and `Evaluated:`. The `Evaluated:` line is the useful one — it shows the
actual values, which is usually enough to tell a genuine regression from a test that encoded
the wrong expectation.

Two testsets in this suite are **characterization tests**: they assert current, known-wrong
behavior on purpose, and say so in their comments.

- `blank-node rdf:type for bootstrap owl types silently degrades to Unknown`
- `colliding sanitized names merge two distinct properties`

If one of those starts failing, that most likely means somebody **fixed the underlying bug**.
Read the comment block above the assertion before treating it as a regression — the comment
states what the assertion should become once fixed.

## Turning on debug logging

Off by default. `test/runtests.jl` used to force it on via `ENV["JULIA_DEBUG"]=all`, which
buried the summary under ~63,000 lines. To enable it for one run:

```bash
JULIA_DEBUG=Jayhawk julia --project=. test/runtests.jl
```

Use `JULIA_DEBUG=all` only if you also need Serd's internals. Always redirect to a file when
debug is on — it is far too large to read inline.

## Running a subset

Julia's `Test` has no built-in testset name filter, and the whole suite is only ~6 seconds,
so **default to running everything**. When iterating tightly on one testset, copy it into a
scratch file instead of editing `test/runtests.jl`:

```julia
# <scratchpad>/one.jl
using Test, Jayhawk, URIs, Serd, Serd.RDF, Serd.RDF.Prefixes, Logging
Jayhawk.set_def_prefixes()

@testset "the one I care about" begin
    # ...paste the testset body...
end
```

```bash
julia --project=. <scratchpad>/one.jl
```

Delete the scratch file when done; never leave it in `test/`.
