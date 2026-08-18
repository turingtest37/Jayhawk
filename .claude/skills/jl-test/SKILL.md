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

~6 seconds, 221 assertions, no server required. **Prefer this over `Pkg.test()`** —
`julia --project=. -e 'using Pkg; Pkg.test()'` does the same work but re-resolves the
environment and spawns a second process, roughly doubling the wall time for identical
results. There is no `test/Project.toml`; test dependencies (`Test`, `URIs`, `Logging`)
resolve from the main `Project.toml`.

**The exit code is the signal.** 0 = all pass, 1 = something failed. Julia prints per-testset
summaries either way, so never judge by eyeballing the tail alone.

Beware that piping loses the exit code, and this environment's shell is **zsh**, where the
bash idiom `${PIPESTATUS[0]}` is silently empty — zsh spells it `${pipestatus[1]}`. The
portable move is to capture first and filter after:

```bash
julia --project=. test/runtests.jl > <scratchpad>/test.log 2>&1; echo "exit: $?"
grep -v -E '^[┌│└]' <scratchpad>/test.log
```

## The four suites

`runtests.jl` is **not** the whole suite. Three more files run standalone and are *not*
included by it, so they are the ones that rot unnoticed — run them before calling a change
done:

```bash
julia --project=. test/runtests.jl                          # 221, hermetic
julia --project=. test/adversarial.jl                       #  36, hermetic part
julia --project=. test/review_fixes.jl                      #  39
julia --project=. test/review_round4.jl                     #  17
```

Each of the last three grows a store-backed part under `JAYHAWK_TEST_SPARQL=1`, and
`runtests.jl` grows `sparql_integration.jl` (223 + 13):

```bash
./bin/fuseki-test.sh start
JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl
```

## Filtering the output

The bulk of the noise is `┌ Warning:` blocks — the dangling-reference warning a `Rewrite`
test deliberately triggers, and a Mustache "binding matches nothing" check. Both are
expected. Strip the multi-line log blocks:

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

The `golden snapshot` testset asserts compiled SPARQL **byte for byte**. When it fails,
compare the `Evaluated:` block against the expected string literally — a one-character
whitespace or ordering change is a real behavioural change in the compiler's output, not a
cosmetic diff to paper over. Emission order is deliberate and asserted elsewhere too
(`VALUES precedes the BIND that may consume it`, `the WHERE body orders match, then BIND,
then filters`).

The characterization testsets that used to be listed here — `blank-node rdf:type for
bootstrap owl types silently degrades to Unknown` and `colliding sanitized names merge two
distinct properties` — moved to `RdfMaterializer` with the materialiser at v0.4.0.

## Turning on debug logging

Off by default. `test/runtests.jl` used to force it on via `ENV["JULIA_DEBUG"]=all`, which
buried the summary under ~63,000 lines. To enable it for one run:

```bash
JULIA_DEBUG=Jayhawk julia --project=. test/runtests.jl
```

Always redirect to a file when debug is on — it is far too large to read inline.

## Running a subset

Julia's `Test` has no built-in testset name filter, and the whole suite is only ~6 seconds,
so **default to running everything**. When iterating tightly on one testset, copy it into a
scratch file instead of editing `test/runtests.jl`:

```julia
# <scratchpad>/one.jl
using Test, Jayhawk, URIs, Logging

@testset "the one I care about" begin
    # ...paste the testset body...
end
```

Testsets in `compiler (pure)` lean on helper bindings defined once at the top of that
outer testset — `G`, `HR`, `R`, `TYPE`, `iri`, `var`, `person_to_employee`. Copy those
across with the body or the paste will not run.

```bash
julia --project=. <scratchpad>/one.jl
```

Delete the scratch file when done; never leave it in `test/`.
