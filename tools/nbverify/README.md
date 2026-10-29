# nbverify

`nbverify.py` grades a Pyking notebook's tasks and quizzes for the
[ID2202 autograder](https://johnwikman.github.io/id2202-autograder/index.html).
The autograder runs a student's program, then hands what it did to a
*verifier* -- a Python 3 script reading JSON on standard input
([`run_verifier`](https://johnwikman.github.io/id2202-autograder/tests.html#run-verifier)).
`nbverify.py` is that verifier, and makes the test files it is run
with from the notebook.

It is one file, needs Python 3.8 or later and nothing else, and can be
copied out alone. Making the test files and running an answer also
need `pyk`. Its `VERSION` line is the Pyking version it belongs to,
written in by `make` (`tools/nbverify/stamp.py`). The notebook's blocks
are described in [docs/notebook.md](../../docs/notebook.md).

## How it fits together

```
book.md ──pyk notebook --to-json──▶ book.json
                                        │
                     nbverify.py paramdata book.json --name square --output-dir tests/square
                                        │  runs the solution with pyk on each test's input
                                        ▼
              tests/square/square_t01.test.toml, square_t02.test.toml, ...
              (args, stdin, and verifier_params: what the answer must do)

the autograder, for each test file:
   runs  bin + args   = nbverify.py run solution.pyk -- ARGS   (stdin from the file)
   then  nbverify.py  with {cmd, code, stdout, stderr, files, params} on stdin
                      → {"accepted": true, "reason": null}            status 0
                      → {"accepted": false, "reason": "..."}          status 1
```

Everything the verdict needs is in the test's `params`: the expected
output, the tinyweb log, the exit status, the diff-allowed,
optional-last and any-order rules, a
quiz's right answers and explanations. The verifier reads no notebook
and runs nothing.

## Commands

| Command | What it does |
|---|---|
| `nbverify.py` | reads one run on standard input and prints the verdict |
| `nbverify.py paramschema` | prints the `[test.options.verifier_param_schema]` table for `config.toml` |
| `nbverify.py paramdata BOOK [--name NAME] [--case N \| --output-dir DIR] [--program FILE] [--pyk PYK]` | prints or writes each test's `[test.options]` |
| `nbverify.py run [--pyk PYK] [--events TEXT] [-L DIR] FILE [-- ARGS]` | runs an answer the way a test does |
| `nbverify.py try [--pyk PYK] [-L DIR] [--json] FILE` | runs an answer on the test whose `[test.options]` is on standard input, and prints the verdict, or with `--json` the run |
| `nbverify.py --help`, `--version` | the help; `nbverify <version>` |

With no argument it does not print the help: it waits for the JSON.

### `paramschema`

```
$ python3 nbverify.py paramschema
[test.options.verifier_param_schema]
kind = {type = "string", default = "task"}
name = {type = "string", default = ""}
compare_stdout = {type = "bool", default = false}
expected_stdout = {type = "string", default = ""}
...
quiz_explanations = {type = "string", default = "[]"}
```

It is the same for every notebook, and goes once in the test group's
`config.toml`.

A param is an int, a bool or a string, never a TOML list: a list is
written as a string holding it as JSON (`"[1, 3]"`), which the verifier
reads back into the list.

| Param | Type | Means |
|---|---|---|
| `kind` | string | `task` or `quiz`; a practice is graded as a task |
| `name` | string | the item's name |
| `compare_stdout`, `expected_stdout` | bool, string | standard output is compared with this |
| `compare_stderr`, `expected_stderr` | bool, string | what `debug` writes is compared with this |
| `compare_tinyweb`, `expected_tinyweb` | bool, string | tinyweb's log is compared with this |
| `compare_code`, `expected_code` | bool, int | the exit status is compared with this |
| `diff_allowed` | list, as JSON in a string | the lines of the task's diff-allowed blocks |
| `optional_last` | list, as JSON in a string | the lines of the task's optional-last blocks |
| `any_order` | list, as JSON in a string | the lines of the task's any-order blocks |
| `ignore_chars` | list, as JSON in a string | the lines of the task's ignore-chars blocks, as `[chars, pattern]` pairs |
| `max_calls` | list, as JSON in a string | the task's `max_calls`, as `[N, name]` pairs: the answer's source may write each name at most N times |
| `details` | bool | the reason also shows the test and both outputs, as the page does unless `attempts = 1` |
| `test_stdin`, `test_args`, `test_events` | string, list as JSON in a string, string | the test's input, for `details` |
| `quiz_alternatives` | int | how many alternatives the quiz has |
| `quiz_multiple` | bool | a `[]` quiz: any number may be chosen |
| `quiz_right` | list, as JSON in a string | the right alternatives, numbered from 1 |
| `quiz_explanations` | list, as JSON in a string | each alternative's explanation |

### `paramdata`

```
$ pyk notebook week1.md --to-json
$ python3 nbverify.py paramdata week1.json --name square --output-dir tests/square
$ cat tests/square/square_t01.test.toml
# nbverify paramdata: week1 task 'square', test 1 of 2
[test.options]
args = ["run", "solution.pyk"]
stdin = "4\n"
verifier_params.kind = "task"
verifier_params.name = "square"
verifier_params.compare_stdout = true
verifier_params.expected_stdout = "16\n"
...
```

- `BOOK` is the notebook's JSON, or its Markdown, which is turned into
  JSON with `pyk notebook --to-json`.
- `--name` picks the item: its `name = ` attribute, or `task-N`,
  `practice-N` or `quiz-N` (counting tasks, practices and quizzes
  apart, as the page does). A
  notebook with one item needs none, and an unnamed one is `default`.
  Several items and no `--name` is refused, with their names.
- A task gives one test file per test: per stdin block, or per
  piece of one split by `lines_per_multi_input`, or one on the
  task's own input where it has no tests. A quiz gives one.
  `--output-dir DIR` writes them all as `NAME_tNN.test.toml`, `--case N`
  prints the N-th, and with neither a single test is printed (several
  are refused).
- Where the task has a solution, it is run with pyk on each test's
  input, events and arguments, and what it prints, writes with `debug`,
  draws and ends with is what the answer must do; a solution that does
  not run is refused. Without one, the stdout and stderr blocks are what
  the answer must print. The solution itself is not in the params.
- `--program FILE` is the name the student's program has where the
  autograder runs it (`solution.pyk` by default). `--pyk` names pyk;
  else `$PYK`, else `pyk` on the `PATH`.

Every task is graded this way, `method = git` ones included: those
are the ones the page leaves to "elsewhere".

### `run`

The test's command. It runs `FILE` with pyk, standard input and output
its own, tinyweb writing its log to a temporary file
(`PYKING_TINYWEB_LOG`) and delivering `--events` once the top level has
ended (`PYKING_TINYWEB_EVENTS`), and ends with the program's status.
After what the program wrote to standard error it writes a line
`--- nbverify run ---` and one line of JSON:

```
{"status": "ok", "stderr": "...", "error": "", "tinyweb": "canvas \"canvas\" 40 40\n...", "source": "..."}
```

`status` is `failed` where pyk refused or stopped the program (a type
error, a runtime error) rather than the program ending itself, and
`error` is then pyk's report. `source` is `FILE`'s text, which
`max_calls` is checked against. The verifier reads the last such
trailer; without one, the whole of standard error is what `debug` wrote,
there is no tinyweb log, and a test with `max_calls` is refused.

### `try`

A test without the autograder. It reads one test file's TOML on
standard input, as `paramdata --case N` prints it, runs `FILE` with
`run` on that test's `stdin`, `--events` and arguments (`FILE` in place
of the program the test names), and verifies the run with the test's
`verifier_params`. It prints the verdict as the verifier does, with
status 0 or 1; a refusal (no program, TOML it cannot read, no
`[test.options]`) is status 2, on standard error.

```
$ python3 nbverify.py paramdata week1.json --name square --case 1 | python3 nbverify.py try mycode.pyk
{"accepted": false, "reason": "The output is not what it should be."}
```

The run it verifies is the one the autograder would hand over. With
`--json` it prints that run and verifies nothing, with status 0, so the
two halves can be run apart:

```
$ python3 nbverify.py paramdata week1.json --name square --case 1 | python3 nbverify.py try --json mycode.pyk > run.json
$ python3 nbverify.py < run.json
```

The run looks like this:

```
{"cmd": ["./graded-bin", "run", "mycode.pyk"], "code": 0,
 "stdout": {"enc": "utf8", "data": "..."}, "stderr": {"enc": "utf8", "data": "...--- nbverify run ---\n{...}\n"},
 "files": {}, "params": {...}}
```

It reads the TOML itself, so Python 3.8 is still enough: tables, dotted
keys, one-line strings, numbers, bools and arrays, which is what
`paramdata` writes.

## The config.toml

```toml
title = "Week 1"

[test]
kind = "run_verifier"

[test.options]
bin = "nbverify.py"            # this file, executable, where the tests run
verifier_path = "./nbverify.py"

[test.options.verifier_param_schema]
# paste `nbverify.py paramschema` here
kind = {type = "string", default = "task"}
...
```

and one `*.test.toml` per file `paramdata` wrote. The command a test
runs is `bin` and the test's `args`, so the program is found as
`solution.pyk` in the directory the autograder runs it in.

## The verdict

```
$ echo '{"cmd": ["nbverify.py", "run", "solution.pyk"], "code": 0,
         "stdout": {"enc": "utf8", "data": "15\n"},
         "stderr": {"enc": "utf8", "data": ""}, "files": {},
         "params": {"kind": "task", "compare_stdout": true, "expected_stdout": "16\n"}}' \
  | python3 nbverify.py
{"accepted": false, "reason": "The output is not what it should be."}
$ echo $?
1
```

A task's answer is compared as the notebook's Submit compares it,
and refused with the reason the page would give:

| Reason | When |
|---|---|
| `Your program uses NAME N times, and may use it at most M times.` | the source writes a name more often than `max_calls` allows, outside comments and strings; checked before the rest |
| `Your program did not run:` and pyk's report | pyk refused it or it stopped with a runtime error |
| `The output is not what it should be.` | standard output differs |
| `What it drew with tinyweb is not what it should be.` | tinyweb's log differs |
| `What debug printed is not what it should be.` | what `debug` wrote differs, where the test has a stderr block |
| `Your program ended with status N, and should end with M.` | the exit status differs |

Output is the same when it is the same apart from spaces at the end of a
line and blank lines at the end, and, on a line an ignore-chars pattern
matches, the characters of its `chars` (removed from both sides before
anything else compares them); numbers may differ where a
diff-allowed line's `[+/-N]` allows; lines an optional-last line
matches may end either side, each line at most one, and lines an any-order `ANY:` line matches
may come in any order between those its `BETWEEN:` lines match, as in
the notebook. Where they do, the first line that differs is counted
with each stretch's `ANY:` lines sorted among the places they hold, and
shown as written. With `details`, the reason goes on
with the test's stdin, arguments and events, what was expected and what
the answer printed.

A quiz is answered by a program printing the alternatives chosen,
numbered from 1, as a list: `print([1, 3])`, or `print([2])` for a `*`
quiz. Order does not matter. It is refused with:

| Reason | When |
|---|---|
| `Your answer is not a list of the alternatives chosen, such as [1, 3], printed on its own.` | it printed something else |
| `There is no alternative N: the quiz has M, numbered from 1.` | a number out of range |
| `Alternative N is chosen more than once.` | a duplicate |
| `Check at least one answer first.` / `Choose an answer first.` | an empty list |
| `Choose one answer.` | several, on a `*` quiz |
| `Not right.`, then `One or more right answers were not checked.` where one was missed, then `N: ` and the explanation of each wrong one chosen | the answer is wrong |

Input that is not JSON, or params that make no sense, are answered with
`accepted: false`, a reason starting `nbverify:`, and status 2.

## Tests

The `nbverify` suite (`tests/test_nbverify.py`) grades the student
solutions in `tests/nbverify/` -- `<book>_<name>_s<N>.pyk`, for the
notebooks in `tests/nbjson/` -- by every test `paramdata` makes, running
each as the autograder would, and holds the verdicts to
`tests/nbverify/<book>.toml`. Each solution is graded again by `try` on
every test, which must say the same; one solution per item goes through
a real `paramdata --case 1 | try` pipe, and `try`'s TOML reader must
read every test file as `tomllib` does. `--update` rewrites the reasons there;
whether a solution is accepted is written by hand. `--only BOOK,...`
grades some notebooks only.
