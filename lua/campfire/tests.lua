local quickfix = require('campfire.quickfix')
local resource = require('campfire.resource')
local runtime = require('campfire.runtime')
local stacktrace = require('campfire.stacktrace')

local M = {}

-- Test-runner strategies. Three layers, picked in this order per request:
--
--   1. cider-nrepl `test-var-query` op when the server advertises it.
--      Returns structured `:results` (ns→var→report maps) and `:summary`.
--      Source-relative `:file` paths get resolved via classpath cache.
--
--   2. Stdout-TSV report-fn hijack for JVM-ish runtimes (clj/bb/cljs/nbb)
--      without cider middleware. We `with-redefs` clojure.test/report to emit
--      `file<TAB>line<TAB>kind<TAB>name` rows, plus extra rows for ns load
--      failures, runtime exceptions, and zero-test outcomes. Without those
--      guards the report-fn trick silently passes when nothing runs.
--
--   3. let-go: no `with-redefs`, no report multimethod. We parse the runtime's
--      raw PASS/FAIL/ERROR stdout and attach the buffer filename so qf jumps
--      land somewhere usable.

-- require_sym: how to load a namespace before running its tests. JVM clj/bb and
-- SCI nbb resolve the namespaced `clojure.core/require` regardless of the current
-- ns's :refer-clojure exclusions, so they use it (a bare `require` would break
-- under `(:refer-clojure :exclude [require])`). Real ClojureScript (shadow-cljs,
-- piggieback) instead treats `require` as a REPL special matched on the symbol
-- itself — bare `require` survives an :exclude AND fires inside the load-guard's
-- try, whereas the namespaced `clojure.core/require` trips shadow's repl-require
-- spec ("Unable to resolve spec :shadow.cljs.repl/repl-require"). So cljs uses the
-- bare symbol; everyone else stays namespaced.
local CLJ_TEST = {
  test_ns = 'clojure.test',
  user_ns = 'user',
  catch_class = 'Throwable',
  require_sym = 'clojure.core/require',
}

-- split_load: cljs.test/run-tests is a MACRO that resolves its target namespace
-- at macroexpand (compile) time. On real ClojureScript (shadow-cljs, piggieback)
-- compilation precedes execution, so a `(require 'ns :reload)` sitting in the
-- same compilation unit (a wrapping `(do …)`) hasn't run yet when run-tests
-- expands → "Namespace ns does not exist". The require must therefore be its own
-- earlier top-level form (shadow evals top-level forms read-eval-sequentially).
-- We also pin the eval to user_ns so the reload can't form a circular dependency
-- through whatever buffer ns the session happens to be parked in. SCI (nbb)
-- interprets without a separate compile phase, so it keeps the simpler do-wrap.
local CLJS_TEST = {
  test_ns = 'cljs.test',
  user_ns = 'cljs.user',
  catch_class = ':default',
  require_sym = 'require',
  split_load = true,
}

local NBB_TEST = {
  test_ns = 'cljs.test',
  user_ns = 'cljs.user',
  catch_class = ':default',
  require_sym = 'clojure.core/require',
}

local function tsv_row(kind, message)
  -- A printable TSV row that parse_line turns into a qf item of the given kind.
  -- The filename column is empty so qf shows just the text.
  return '(clojure.core/println (clojure.core/str "NO_SOURCE_FILE" \\tab 0 \\tab "' .. kind .. '" \\tab '
    .. message .. '))'
end

-- Collect the distinct namespaces that need loading before the run body:
-- the explicit nses[] plus each var's owning ns. Preserves first-seen order
-- so the generated `(require 'a 'b :reload)` reads predictably in scratch.
local function involved_nses(opts)
  local seen, out = {}, {}
  local function add(n)
    if n and n ~= '' and not seen[n] then seen[n] = true; out[#out + 1] = n end
  end
  for _, n in ipairs(opts.nses or {}) do add(n) end
  for _, v in ipairs(opts.vars or {}) do add(v:match('^([^/]+)/')) end
  return out
end

-- Prefix each list entry (e.g. "'" for a quoted sym, "#'" for a var) and join
-- with spaces, for splicing into a generated Clojure form.
local function quoted(list, prefix)
  local out = {}
  for _, n in ipairs(list) do out[#out + 1] = prefix .. n end
  return table.concat(out, ' ')
end

local function build_tsv_wrap(spec, kind, opts)
  local test_ns = spec.test_ns
  local catch = spec.catch_class
  local require_sym = spec.require_sym or 'clojure.core/require'
  local nses = opts.nses or {}
  local vars = opts.vars or {}
  local patterns = opts.patterns or {}
  -- Legacy fallback: `request('ns', {runtime='cljs', describe={ops={}}})`
  -- (no explicit ns/var) used to fall through to the runtime's user_ns.
  -- Preserve that for callers that pass `kind == 'ns'` without targets.
  if kind == 'ns' and #nses == 0 and #vars == 0 and #patterns == 0 then
    nses = { spec.user_ns }
  end

  -- Body. Fireplace parity:
  --   :RunTests        → (run-all-tests)
  --   :RunTests pat … → (run-all-tests #"pat1|pat2") — line1==0 with args
  --   :.RunTests       → (test-vars [#'cur/foo])     — cursor var
  --   :RunTests ns/x ns/y → (test-vars [#'ns/x #'ns/y])
  --   :RunTests ns1 ns2  → (run-tests 'ns1 'ns2)
  --   Mixed → both forms wrapped in `(do …)`.
  local body
  if #patterns > 0 then
    body = '(' .. test_ns .. '/run-all-tests #"' .. table.concat(patterns, '|') .. '")'
  elseif kind == 'all' and #nses == 0 and #vars == 0 then
    body = '(' .. test_ns .. '/run-all-tests)'
  else
    local parts = {}
    if #vars > 0 then
      parts[#parts + 1] = '(' .. test_ns .. '/test-vars [' .. quoted(vars, "#'") .. '])'
    end
    if #nses > 0 then
      parts[#parts + 1] = '(' .. test_ns .. '/run-tests ' .. quoted(nses, "'") .. ')'
    end
    if #parts == 0 then
      body = '(' .. test_ns .. '/run-all-tests)'
    elseif #parts == 1 then
      body = parts[1]
    else
      -- Sequence both; the run-tests summary map ends up as the last value
      -- (matters for the zero-test check below — though that only fires for
      -- the single-ns no-vars shape, so this is just for shape consistency).
      body = '(do ' .. table.concat(parts, ' ') .. ')'
    end
  end

  -- Caught-exception text for guard error rows: message plus an explicit
  -- ex-data tail. JVM reads class+message via interop; js errors have no
  -- .getMessage and cljs ExceptionInfo's toString omits the data map, so the
  -- cljs shape is str + ex-data instead.
  local ex_text
  if test_ns == 'clojure.test' then
    ex_text = '(.getName (clojure.core/class e#)) ": " (clojure.core/ex-message e#)'
      .. ' (clojure.core/when-let [d# (clojure.core/ex-data e#)]'
      .. ' (clojure.core/str " ex-data: " (clojure.core/pr-str d#)))'
  else
    ex_text = '(str e#)'
      .. ' (when-let [d# (ex-data e#)] (str " ex-data: " (pr-str d#)))'
  end

  -- Load guard. Skipped for `all` and regex patterns: those operate over
  -- whatever's already loaded by design (run-all-tests). With targets we
  -- require each involved ns :reload up front so a stale def can't pass.
  local load_guard = ''
  local to_load = involved_nses(opts)
  if kind ~= 'all' and #patterns == 0 and #to_load > 0 then
    local syms = quoted(to_load, "'")
    local listed = '"' .. table.concat(to_load, ',') .. '"'
    if spec.split_load then
      -- cljs: the require MUST be a bare top-level form. shadow only treats
      -- `(require …)` as the REPL-special that registers the ns in the analyzer
      -- (so the later run-tests macro can find it) when it's bare — wrapping it
      -- in try/catch makes it an ordinary runtime call and the macroexpand of the
      -- run body fails with "Namespace … does not exist". So we forgo the
      -- namespace-load-failed TSV row here; a genuine load failure still surfaces
      -- as shadow's own REPL error (caught by the eval-error path).
      load_guard = '(' .. require_sym .. ' ' .. syms .. ' :reload)'
    else
      load_guard = '(try (' .. require_sym .. ' ' .. syms .. ' :reload) '
        .. '(catch ' .. catch .. ' e# '
        ..   tsv_row('error', '"namespace-load-failed: " ' .. listed .. ' ": " ' .. ex_text) .. ' '
        ..   '(throw e#))) '
    end
  end

  -- Optimistic stack frames for test errors, emitted as `frame` TSV rows with a
  -- real file+line so parse_line turns them into jumpable qf items beneath the
  -- error row (capped to keep the list useful, not a wall of noise).
  --   clojure.test (clj/bb): (:actual m) is a Throwable; Throwable->map gives a
  --     :trace of [class method file line] vectors.
  --   cljs.test (nbb): (:actual m) is a js error. Only SCI ExceptionInfo from an
  --     analysis-phase failure carries source coords — (ex-data e) :sci.impl/
  --     callstack is a volatile of {:file :line} frames; bare runtime js/Errors
  --     have nil ex-data and yield no frames (we emit the error row alone rather
  --     than fabricating lines). try/and/or/when bare — special forms on SCI.
  -- Exception detail rows for an :error report (emit_error_detail): the
  -- thrown class+message and an explicit ex-data row — cljs gets `str` of the
  -- error instead of interop (js errors lack .getMessage, and its
  -- ExceptionInfo toString omits the data map, hence the separate ex-data row
  -- on both). The cider path carries the same via the :error string and the
  -- test-stacktrace :data field; this keeps the eval/TSV path at parity.
  local emit_frames = ''
  local emit_error_detail = ''
  if test_ns == 'clojure.test' then
    emit_frames = " (let [tr (try "
      ..   "(:trace (clojure.core/Throwable->map (:actual m))) "
      ..   "(catch " .. catch .. " _# nil))] "
      .. "(doseq [fr (clojure.core/take 16 "
      ..   "(clojure.core/filter "
      ..     "(fn [fr] (let [fl (clojure.core/nth fr 2 nil) "
      ..                    "ln (clojure.core/nth fr 3 nil)] "
      ..       "(and (clojure.core/string? fl) "
      ..            "(clojure.core/integer? ln) (clojure.core/pos? ln)))) "
      ..     "tr))] "
      ..   "(let [fcls (clojure.core/nth fr 0) fmth (clojure.core/nth fr 1) "
      ..         "fl (clojure.core/nth fr 2) ln (clojure.core/nth fr 3)] "
      ..     "(clojure.core/println (clojure.core/str fl \\tab ln \\tab \"frame\" \\tab "
      ..       "fcls \"/\" fmth \" (\" fl \":\" ln \")\")))))"
    emit_error_detail = ' (clojure.core/when-let [a (:actual m)] '
      .. '(clojure.core/println (clojure.core/str "" \\tab 0 \\tab "detail" \\tab '
      ..   '"error: " (.getName (clojure.core/class a)) ": " (clojure.core/ex-message a))) '
      .. '(clojure.core/when-let [d (clojure.core/ex-data a)] '
      ..   '(clojure.core/println (clojure.core/str "" \\tab 0 \\tab "detail" \\tab '
      ..     '"ex-data: " (clojure.core/pr-str d)))))'
  else
    emit_frames = " (let [e (:actual m) d (when e (ex-data e)) "
      ..   "csv (:sci.impl/callstack d) cs (when csv (deref csv)) "
      ..   "frames (cons d cs)] "
      .. "(doseq [fr (take 16 (filter (fn [fr] (and (:file fr) (:line fr))) frames))] "
      ..   "(println (str (:file fr) \\tab (:line fr) \\tab \"frame\" \\tab "
      ..     "(some-> (:ns fr) str) \" (\" (:file fr) \":\" (:line fr) \")\"))))"
    emit_error_detail = ' (when-let [a (:actual m)] '
      .. '(println (str "" \\tab 0 \\tab "detail" \\tab "error: " a)) '
      .. '(when-let [d (ex-data a)] '
      ..   '(println (str "" \\tab 0 \\tab "detail" \\tab "ex-data: " (pr-str d)))))'
  end

  -- Expected/actual detail rows for a :fail report (clojure.test AND cljs.test).
  -- The report map carries :expected and :actual; emit each as a non-jumpable
  -- `detail` TSV row so the user sees what was expected vs got — the cider path
  -- shows this, the eval/TSV path now approaches parity. pr-str so structured
  -- values read; clojure.core-qualified for the clojure.test path's bare reader.
  local q = test_ns == 'clojure.test' and 'clojure.core/' or ''
  local emit_expected_actual = ' (' .. q .. 'println (' .. q .. 'str "" \\tab 0 \\tab "detail" \\tab '
    .. '"expected: " (' .. q .. 'pr-str (:expected m)))) '
    .. '(' .. q .. 'println (' .. q .. 'str "" \\tab 0 \\tab "detail" \\tab '
    .. '"actual: " (' .. q .. 'pr-str (:actual m))))'

  -- Report interceptor. `cur` tracks the current :begin-test-var event so
  -- subsequent :fail/:error rows can attribute filename/line to the var's
  -- metadata when the report map doesn't carry them. We fully replace report,
  -- so clojure.test's own counter/summary never runs — `tally` reconstructs
  -- the counts it would have printed: :begin-test-var → tests, :pass/:fail/
  -- :error → assertions. `emit-summary` prints one TSV row whose name field is
  -- the rendered summary text (same wording as append_summary, the cider path),
  -- with empty file + lnum 0 so parse_line renders it non-jumpable; `emitted`
  -- guards it from being printed twice.
  local interceptor = "(let [cur (clojure.core/atom nil) "
    ..   "tally (clojure.core/atom {:test 0 :pass 0 :fail 0 :error 0}) "
    ..   "emitted (clojure.core/atom false) "
    ..   "emit-summary (fn [] "
    ..     "(let [t (clojure.core/deref tally) "
    ..           "tn (:test t) p (:pass t) fl (:fail t) er (:error t) "
    ..           "a (clojure.core/+ p fl er) "
    ..           "txt (clojure.core/str \"Ran \" tn \" test\" "
    ..              "(if (clojure.core/= 1 tn) \"\" \"s\") \", \" a \" assertions — \" "
    ..              "p \" pass, \" fl \" fail, \" er \" error\")] "
    ..       "(clojure.core/reset! emitted true) "
    ..       "(clojure.core/println (clojure.core/str \"\" \\tab 0 \\tab \"summary\" \\tab txt))))] "
    .. "(with-redefs [" .. test_ns .. "/report "
    ..   "(fn [m] "
    ..     "(case (:type m) "
    ..       ":begin-test-var (do (clojure.core/reset! cur (:var m)) "
    ..         "(clojure.core/swap! tally clojure.core/update :test clojure.core/inc)) "
    ..       ":pass (clojure.core/swap! tally clojure.core/update :pass clojure.core/inc) "
    ..       ":fail (do (clojure.core/swap! tally clojure.core/update :fail clojure.core/inc) "
    ..         "(let [v (clojure.core/deref cur) "
    ..               "mta (when v (clojure.core/meta v)) "
    ..               "f (or (:file m) (:file mta) \"NO_SOURCE_FILE\") "
    ..               "l (or (:line m) 0) "
    ..               "nm (clojure.core/str (clojure.core/some-> mta :ns) \"/\" "
    ..                  "(clojure.core/some-> mta :name))] "
    ..           "(clojure.core/println (clojure.core/str f \\tab l \\tab \"fail\" \\tab nm))"
    ..           emit_expected_actual .. ")) "
    ..       ":error (do (clojure.core/swap! tally clojure.core/update :error clojure.core/inc) "
    ..         "(let [v (clojure.core/deref cur) "
    ..               "mta (when v (clojure.core/meta v)) "
    ..               "f (or (:file m) (:file mta) \"NO_SOURCE_FILE\") "
    ..               "l (or (:line m) 0) "
    ..               "nm (clojure.core/str (clojure.core/some-> mta :ns) \"/\" "
    ..                  "(clojure.core/some-> mta :name))] "
    ..           "(clojure.core/println (clojure.core/str f \\tab l \\tab \"error\" \\tab nm)))"
    ..           emit_error_detail .. emit_frames .. ") "
    ..       ":summary (emit-summary) "
    ..       "nil))] "
    -- After the synchronous body, emit the summary from tally when no :summary
    -- report fired. clojure.test/test-vars (var/cursor runs) never reports
    -- :summary, so without this they'd show no count line; run-tests/run-all-tests
    -- DO report :summary, which sets `emitted`, so this never double-emits.
    -- Gated to clojure.test: cljs.test is async — the body returns a channel
    -- before tests finish, so an after-body emit there would print premature
    -- zero-counts — hence the fallback runs only for the synchronous runtime.
    -- The body's value (the run-tests summary map) is bound and returned so the
    -- downstream zero-test check still sees it.
    .. (test_ns == 'clojure.test'
        and ("(let [r# " .. body .. "] "
          .. "(when-not (clojure.core/deref emitted) (emit-summary)) r#)")
        or body)
    .. "))"

  -- Guard against runtime throws inside the body (broken deftest, NPE in a
  -- fixture, etc). Without this an exception kills the eval before any
  -- :fail/:error rows are printed, and the user sees an empty quickfix
  -- alongside an "eval-error" nREPL status — easy to misread as success.
  local guarded = '(try ' .. interceptor .. ' '
    .. '(catch ' .. catch .. ' e# '
    ..   tsv_row('error', '"eval-threw: " ' .. ex_text) .. ' '
    ..   '(throw e#)))'

  -- Zero-test warning. clojure.test's report fn doesn't fire :fail/:error when
  -- no vars match, so we have to read the summary off the result. JVM clj/bb
  -- return the summary map directly from run-tests / test-vars; cljs.test's
  -- async returns a Promise/Channel, so skip the check for cljs/nbb (the
  -- summary text is still emitted via :summary report calls — caller can read
  -- the regular test output). Only meaningful for the single-ns no-vars
  -- shape: with multiple run forms the inner summary maps are discarded.
  local with_zero_check
  if test_ns == 'clojure.test'
      and #patterns == 0
      and #vars == 0
      and #nses == 1
      and kind ~= 'all' then
    with_zero_check = '(let [r# ' .. guarded .. '] '
      .. '(when (and (clojure.core/map? r#) '
      ..   '(clojure.core/zero? (clojure.core/get r# :test 0))) '
      ..   tsv_row('warn', '"no tests matched: " \'' .. nses[1]) .. ') '
      .. 'r#)'
  else
    with_zero_check = guarded
  end

  local require_test = '(' .. require_sym .. " '" .. test_ns .. ')'
  if spec.split_load then
    -- Separate top-level forms (not one (do …)): shadow reads-evals them in
    -- sequence, so the requires EXECUTE — registering the target ns in the cljs
    -- analyzer — before the run body's cljs.test/run-tests macro expands. See
    -- the CLJS_TEST split_load note. Empty load_guard ('all' kind) drops out.
    return table.concat({ require_test, load_guard, with_zero_check }, '\n')
  end
  return '(do ' .. require_test .. ' ' .. load_guard .. with_zero_check .. ')'
end

local function build_lg_wrap(kind, opts)
  -- let-go: load via require (which goes through let-go's classpath search)
  -- and run via `clojure.test/run-tests` (alias to `test/run-tests`). The
  -- `is` macro prints PASS/FAIL form lines straight to stdout; parsing
  -- happens on the lua side.
  local target_ns = opts.ns
  if kind == 'all' then
    return "(do (require 'clojure.test) (clojure.test/run-tests))"
  end

  if opts.var then
    local var_ns = opts.var:match('^([^/]+)/')
    target_ns = var_ns or target_ns
  end

  if not target_ns then
    return nil, 'Campfire: lg tests need a target namespace'
  end

  -- let-go's `require` is best-effort: if the file isn't on its source path
  -- it returns nil rather than throwing. So we can't rely on a try/catch
  -- to detect load failure — we have to check `find-ns` afterwards. The
  -- catch is still useful for the rare case where the file is found but
  -- evaluating it throws (e.g. a syntax error in the user's deftest).
  local load_guard = "(try (require '" .. target_ns .. ") "
    .. "(catch Throwable e "
    ..   '(println (str "NO_SOURCE_FILE" \\tab 0 \\tab "error" \\tab '
    ..     '"namespace-load-failed: " \'' .. target_ns .. ' ": " (str e))) '
    ..   "(throw e))) "

  local run_body
  if opts.var then
    -- let-go has no test-vars in clojure.test alias; the closest equivalent
    -- is calling the var as a fn (deftest expands to a 0-arg fn).
    run_body = "(#'" .. opts.var .. ")"
  else
    -- run-tests's per-ns cleanup path (`(in-ns (symbol (name old-ns)))`)
    -- crashes on `name` of a Namespace value in current let-go. The PASS/
    -- FAIL output is already on the wire before the crash, so we swallow
    -- it here rather than letting it surface as a failed eval.
    run_body = "(try (clojure.test/run-tests '" .. target_ns
        .. ") (catch Throwable _ nil))"
  end

  -- let-go's `require` creates an empty placeholder namespace even when the
  -- backing `.lg` file is missing from the source path, so `find-ns` alone
  -- can't tell us whether the file was actually loaded. Instead, look at
  -- the test-registry side-effect of `deftest`: `*registered-tests*` only
  -- gains an entry when a real deftest from the user's source ran. Empty
  -- vector ⇒ ns wasn't actually loaded.
  local guarded_run = "(if (clojure.core/seq "
    .. "(clojure.core/get test/*registered-tests* "
    ..   "(clojure.core/find-ns '" .. target_ns .. ") [])) "
    .. run_body .. " "
    .. '(println (str "NO_SOURCE_FILE" \\tab 0 \\tab "error" \\tab '
    ..   '"namespace-load-failed: " \'' .. target_ns .. ' ": not found on source path")))'

  return "(do " .. load_guard .. guarded_run .. ")"
end

-- clj and bb share one spec value; the keys stay distinct so lang routing and
-- per-lang tags remain independent.
local STRATEGIES = {
  clj = CLJ_TEST,
  bb = CLJ_TEST,
  cljs = CLJS_TEST,
  nbb = NBB_TEST,
}

-- cider-nrepl's test-var-query op runs clojure.test on the JVM. Through
-- cider-nrepl 0.60.x it was blind to cljs.test, yet shadow-cljs (and piggieback
-- carrying cider on its JVM tooling session) advertised it — so a cljs run
-- returned zero results ("no matching tests"). cider-nrepl 0.61.0 (#555) makes
-- the op run cljs.test in the JS runtime and return the same report shape, so a
-- new-enough server takes the op; older ones and nbb (never advertises it) take
-- the cljs.test TSV eval wrap. Mirrors stacktrace.is_cljs_family.
local CLJS_FAMILY = { cljs = true, nbb = true }

-- cider-nrepl >= 0.61.0 runs cljs tests through the test ops (#555). The version
-- rides in describe's :aux (cider merges {:cider-version version} there; see
-- cider.nrepl/nrepl.clj). Absent/older ⇒ false ⇒ cljs falls back to the wrap.
local function cider_runs_cljs_tests(describe)
  local v = describe and describe.aux and describe.aux['cider-version']
  if type(v) ~= 'table' then return false end
  local major = tonumber(v.major) or 0
  local minor = tonumber(v.minor) or 0
  return major > 0 or minor >= 61
end

-- Fold singular ns/var/targets/patterns inputs into canonical opts.nses/.vars/.patterns
-- lists, preserving the singular keys for legacy paths (lg, existing tests).
local function normalize_opts(opts)
  opts.nses = opts.nses or {}
  opts.vars = opts.vars or {}
  opts.patterns = opts.patterns or {}
  if opts.targets then
    for _, t in ipairs(opts.targets) do
      if t:find('/', 1, true) then opts.vars[#opts.vars + 1] = t
      else opts.nses[#opts.nses + 1] = t end
    end
  end
  if opts.ns and not vim.tbl_contains(opts.nses, opts.ns) then
    opts.nses[#opts.nses + 1] = opts.ns
  end
  if opts.var and not vim.tbl_contains(opts.vars, opts.var) then
    opts.vars[#opts.vars + 1] = opts.var
  end
  -- keep singulars in sync so build_lg_wrap (legacy) still works
  if not opts.ns and opts.nses[1] then opts.ns = opts.nses[1] end
  if not opts.var and opts.vars[1] then opts.var = opts.vars[1] end
end

-- Build cider var-query from canonical opts.nses/.vars. Returns nil when the
-- shape doesn't map cleanly to a single query (mixed ns+var, or no targets
-- with a non-`all` kind) — the caller falls back to eval.
local function cider_query_for(kind, opts)
  if opts.var_query then return opts.var_query end
  if kind == 'expr' then return nil end
  if #opts.patterns > 0 then return nil end
  if kind == 'all' then
    return { ['ns-query'] = { ['project?'] = true, ['load-project-ns?'] = true } }
  end
  if #opts.vars > 0 and #opts.nses == 0 then
    return { exactly = vim.deepcopy(opts.vars) }
  end
  if #opts.nses > 0 and #opts.vars == 0 then
    return { ['ns-query'] = { exactly = vim.deepcopy(opts.nses), ['load-project-ns?'] = true } }
  end
  return nil
end

function M.request(kind, opts)
  opts = opts or {}
  normalize_opts(opts)
  local runtime_name = opts.runtime or require('campfire').runtime({})
  local ops = opts.describe and opts.describe.ops

  if kind == 'expr' then
    return { op = 'eval', code = opts.expr, session = opts.session, scope = 'user' }
  end

  local use_op = ops and ops['test-var-query']
    and (not CLJS_FAMILY[runtime_name] or cider_runs_cljs_tests(opts.describe))
  if use_op then
    local query = cider_query_for(kind, opts)
    if query then
      return { op = 'test-var-query', ['var-query'] = query, session = opts.session, scope = 'user' }
    end
    if kind ~= 'all' and #opts.nses == 0 and #opts.vars == 0 and #opts.patterns == 0 then
      return nil, 'Campfire: tests need a namespace or var for cider test-var-query'
    end
    -- Otherwise (mixed nses+vars, or regex pattern) fall through to eval.
  end

  if runtime_name == 'lg' then
    local code, err = build_lg_wrap(kind, opts)
    if err then return nil, err end
    return { op = 'eval', code = code, session = opts.session, scope = 'user' }
  end

  local spec = STRATEGIES[runtime_name]
  if not spec then
    return nil, ('Campfire: tests unavailable for %s runtime without test op'):format(runtime_name)
  end

  local code = build_tsv_wrap(spec, kind, opts)
  local req = { op = 'eval', code = code, session = opts.session, scope = 'user' }
  -- Pin cljs test evals to a neutral ns so the :reload can't form a circular
  -- dependency through whatever buffer ns the session is parked in (e.g. running
  -- a test from foo.bar's buffer, where foo.bar-test requires foo.bar).
  if spec.split_load then req.ns = spec.user_ns end
  return req
end

-- A non-jumpable quickfix item (empty filename). type defaults to '' so
-- quickfix.item renders it verbatim rather than defaulting it to a jumpable 'E'.
local function plain(text, type)
  return { filename = '', lnum = 0, type = type or '', text = text }
end

function M.parse_line(line)
  local file, lnum, kind, name = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$')
  if file then
    -- The summary row from the eval/TSV interceptor is informational: type ''
    -- so it renders plain and is excluded from after_done's failure count.
    if kind == 'summary' then
      return plain(name)
    end
    -- A frame row carries a Throwable stack frame from the eval/TSV :error path.
    -- It is jumpable (filename + lnum set) but type '' so it renders plain under
    -- the error row and doesn't inflate after_done's failure count — matching
    -- the cider test-stacktrace frames. Indented "      at …" like those.
    if kind == 'frame' then
      return {
        filename = file ~= 'NO_SOURCE_FILE' and file or '',
        lnum = tonumber(lnum) or 0,
        type = '',
        text = '      at ' .. name,
      }
    end
    -- A detail row is expected/actual context under a :fail (eval/TSV path).
    -- Non-jumpable (type '', no file/line) so it renders plain and stays out of
    -- after_done's failure count — like push_block's continuation lines on the
    -- cider path.
    if kind == 'detail' then
      return plain('    ' .. name)
    end
    local type_code = 'E'
    if kind == 'fail' then type_code = 'W'
    elseif kind == 'warn' then type_code = 'W' end
    return {
      filename = file ~= 'NO_SOURCE_FILE' and file or '',
      lnum = tonumber(lnum) or 0,
      type = type_code,
      text = name,
    }
  end
  -- Untagged stdout (app logs, user println). type '' so it renders verbatim,
  -- stays non-jumpable for :cnext, and is excluded from after_done's failure
  -- count — same treatment as detail/summary rows. Without it, quickfix.item's
  -- `type or 'E'` default turns every log line into a jumpable error entry.
  return plain(line)
end

-- let-go's `is` macro prints `PASS <form>` / `FAIL <form>` and `ERROR in
-- test: <ex>` straight to stdout. There is no per-test file/line metadata
-- — `(meta #'x/foo-test)` returns nil — and run-tests crashes during its
-- own cleanup, so we have very little to work with. Stuff every output
-- line into the quickfix verbatim and let the user read what the runtime
-- said. The buffer filename is attached upstream so jumping into the qf
-- entry at least lands in the right file.
local function parse_lg_line(line)
  local kind = 'I'
  if line:match('^FAIL%s+') then kind = 'W'
  elseif line:match('^ERROR') then kind = 'E'
  end
  -- Our load-fail guard prints a TSV row; keep parsing that since it
  -- carries an explicit "error" type we want to honour.
  if line:find('\t', 1, true) then
    return M.parse_line(line)
  end
  return { filename = '', lnum = 0, type = kind, text = line }
end

function M.parse_lg_line(line) return parse_lg_line(line) end

local FAILURE_STATUS = {
  ['eval-error'] = true,
  ['namespace-not-found'] = true,
  ['namespace-not-loaded'] = true,
  ['error'] = true,
}

local function resolve_filename(client, file)
  if not file or file == '' then return '' end
  if file == 'NO_SOURCE_FILE' then return '' end
  return resource.find(client, file)
end

local function fmt_text(...)
  local parts = {}
  for _, p in ipairs({...}) do
    if p and p ~= '' then parts[#parts + 1] = p end
  end
  return table.concat(parts, ' | ')
end

-- Collapse a report field to a single line for the located header entry.
-- A raw \n inside a quickfixtextfunc line truncates the rendered entry, so
-- header fields (ns/var, context, message) must be newline-free.
local function oneline(s)
  if type(s) ~= 'string' or s == '' then return nil end
  local collapsed = vim.trim((s:gsub('%s+', ' ')))
  return collapsed ~= '' and collapsed or nil
end

-- Append a multi-line report field (:expected / :actual / :error) as one
-- quickfix entry per physical line — vim collapses embedded \n, so detail
-- only survives as separate entries (the fireplace / errorformat approach).
-- Continuation entries carry type '' so they're rendered plain and excluded
-- from the failure count.
local function push_block(items, label, s)
  if type(s) ~= 'string' then return end
  for i, ln in ipairs(vim.split(s, '\n', { plain = true, trimempty = true })) do
    local body = (ln:gsub('%s+$', ''))
    if body ~= '' then
      -- Label only the first line; later lines keep their own indentation
      -- (meaningful for pretty-printed maps / stacktraces) under a fixed base.
      local prefix = (i == 1) and (label .. ': ') or ''
      items[#items + 1] = { filename = '', lnum = 0, type = '', text = '    ' .. prefix .. body }
    end
  end
end

local SRC_EXTS = { '.clj', '.cljc', '.cljs' }

-- Map a namespace to its classpath-relative source path, munging Clojure ns
-- naming to file naming (dashes → underscores, dots → directory separators).
local function ns_resource_base(ns)
  if type(ns) ~= 'string' or ns == '' then return nil end
  return (ns:gsub('%-', '_'):gsub('%.', '/'))
end

local function resolve_ns_file(client, ns)
  local base = ns_resource_base(ns)
  if not base then return '' end
  for _, ext in ipairs(SRC_EXTS) do
    local hit = resolve_filename(client, base .. ext)
    if hit:sub(1, 1) == '/' then return hit end
  end
  return ''
end

-- Find the line where a def-form (deftest, defspec, …) names var_name, by
-- reading the source file and matching top-level forms — same logic as
-- var_at_cursor, run in reverse. Returns nil when the file/var isn't found.
local function var_def_line(file, var_name)
  if not var_name or var_name == '' then return nil end
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok or type(lines) ~= 'table' then return nil end
  for _, form in ipairs(runtime.forms(table.concat(lines, '\n'))) do
    local def = runtime.parse_def(form.code)
    if def and def.name == var_name then return form.line end
  end
  return nil
end

-- cider's :file/:line point at whichever frame fired the assertion. For a fail
-- that's the assertion itself (keep it). For a generation error it's a library
-- (alpha.clj, check.cljc) whose bare filename resolves to nothing usable, so we
-- fall back to the test var's own namespace file and locate the deftest line in
-- it — the test's location should come from the test, not the stacktrace.
local function report_location(client, report, ns_name, var_name)
  local f = resolve_filename(client, report.file)
  if f:sub(1, 1) == '/' then
    return f, tonumber(report.line) or 0
  end
  local ns_file = resolve_ns_file(client, report.ns or ns_name)
  if ns_file == '' then return '', 0 end
  return ns_file, var_def_line(ns_file, var_name) or 0
end

local function collect_op_results(state, results)
  local items = state.items
  state.pending = state.pending or {}
  for ns_name, vars in pairs(results or {}) do
    for var_name, reports in pairs(vars or {}) do
      for _, report in ipairs(reports or {}) do
        local rtype = report.type
        if rtype == 'fail' or rtype == 'error' then
          local file, line = report_location(state.client, report, ns_name, var_name)
          local located = {
            filename = file,
            lnum = line,
            type = rtype == 'fail' and 'W' or 'E',
            text = fmt_text(
              tostring(ns_name) .. '/' .. tostring(var_name),
              oneline(report.context),
              oneline(report.message)
            ),
          }
          items[#items + 1] = located
          push_block(items, 'expected', report.expected)
          push_block(items, 'actual', report.actual)
          push_block(items, 'error', report.error)
          -- Errors carry a Throwable cider stored under [ns var index]; queue a
          -- test-stacktrace fetch to enrich the located line + append frames.
          if rtype == 'error' and report.index ~= nil then
            state.pending[#state.pending + 1] = {
              ns = tostring(ns_name),
              var = tostring(var_name),
              index = report.index,
              located = located,
              anchor = items[#items],
              causes = {},
            }
          end
        end
      end
    end
  end
end

local function index_of(list, item)
  for i, v in ipairs(list) do
    if v == item then return i end
  end
  return nil
end

-- Populate or refresh the live quickfix list. The first call creates the list
-- (and fires the auto-open autocmd); later calls replace its items in place, so
-- results show as they stream in and again once stacktraces are spliced in.
local function refresh(state)
  if state.qf_id then
    quickfix.replace(state.qf_id, state.items)
    state.flushed = #state.items
  else
    state.qf_id = quickfix.set(state.items, state.title or 'Campfire tests')
    state.flushed = #state.items
  end
end

-- Live append: push only the items added since the last flush. Streaming is
-- pure append (collect_op_results / parsed output only grow the list), so this
-- stays O(total) over a run instead of refresh's O(n²) full re-marshal per
-- chunk. The done path still calls refresh() once — apply_traces splices frames
-- mid-list, which append can't express, and a final replace reconciles it.
local function flush(state)
  local n = #state.items
  if not state.qf_id then
    state.qf_id = quickfix.set(state.items, state.title or 'Campfire tests')
  else
    quickfix.append(state.qf_id, vim.list_slice(state.items, (state.flushed or 0) + 1, n))
  end
  state.flushed = n
end

-- Splice each error's fetched frames into the live item list and retarget its
-- located header at the first project frame.
local function apply_traces(state)
  for _, p in ipairs(state.pending) do
    local entries = stacktrace.causes_to_qf(p.causes)
    local at = index_of(state.items, p.anchor)
    if at then
      for k, e in ipairs(entries) do
        table.insert(state.items, at + k, {
          filename = e.filename, lnum = e.lnum, type = '', text = e.text,
        })
      end
    end
  end
end

-- Fan out one test-stacktrace request per errored report, then finalize the
-- quickfix list once they've all responded (each streams its causes followed by
-- a done/no-error status).
local function fetch_traces(state)
  local remaining = #state.pending
  for _, p in ipairs(state.pending) do
    state.client:request(
      { op = 'test-stacktrace', ns = p.ns, var = p.var, index = p.index, scope = 'user' },
      function(message)
        if message.stacktrace or message.class then
          p.causes[#p.causes + 1] = {
            class = message.class,
            message = message.message,
            data = message.data,
            stacktrace = message.stacktrace,
          }
        end
        for _, status in ipairs(message.status or {}) do
          if status == 'done' or status == 'no-error' then
            remaining = remaining - 1
            if remaining == 0 then
              apply_traces(state)
              refresh(state)
              M.after_done(state)
            end
            return
          end
        end
      end)
  end
end

local function append_status_failure(state)
  local text = state.last_root_ex or state.last_ex or state.last_err
  if not text or text == '' then text = 'nREPL eval error' end
  state.items[#state.items + 1] = plain(text, 'E')
end

local function append_no_match_warning(state)
  state.items[#state.items + 1] = plain('no matching tests', 'W')
end

-- Trailing summary line from the cider :summary map. The TSV/lg paths get
-- clojure.test's own printed summary via stdout; this gives the op path parity.
local function append_summary(state, summary)
  local function n(k) return tonumber(summary[k]) or 0 end
  local vars = n('var')
  state.items[#state.items + 1] = plain(
    string.format('Ran %d test%s, %d assertions — %d pass, %d fail, %d error',
      vars, vars == 1 and '' or 's', n('test'), n('pass'), n('fail'), n('error')))
end

function M.handle_output(state, message)
  state.items = state.items or {}
  state.flushed = state.flushed or 0
  state.runtime = state.runtime or 'clj'
  state.op = state.op or 'eval'
  state.saw_failure_status = state.saw_failure_status or false
  state.summary = state.summary or nil

  if message.results then
    collect_op_results(state, message.results)
  end
  if message.summary then
    state.summary = message.summary
  end
  if message.ex then state.last_ex = message.ex end
  if message['root-ex'] then state.last_root_ex = message['root-ex'] end
  if message.err and message.err ~= '' then
    state.last_err = (state.last_err or '') .. message.err
  end

  local text = (message.out or '') .. (message.err or '')
  if text ~= '' then
    for _, line in ipairs(vim.split(text, '\n', { plain = true, trimempty = true })) do
      local item
      if state.op ~= 'eval' then
        -- test-var-query: the tests' own *out*/*err* prints arrive as regular
        -- session output forwarding. Surface each line plain (type '') so user
        -- prints land in the list — fireplace parity — without counting as
        -- failures.
        item = { filename = '', lnum = 0, type = '', text = line }
      elseif state.runtime == 'lg' then
        item = parse_lg_line(line)
        if item and state.buffer_file and (item.filename == nil or item.filename == '') then
          item.filename = state.buffer_file
        end
      else
        item = M.parse_line(line)
        if item and item.filename and item.filename ~= '' then
          item.filename = resolve_filename(state.client, item.filename)
        end
      end
      if item then state.items[#state.items + 1] = item end
    end
  end

  for _, status in ipairs(message.status or {}) do
    if FAILURE_STATUS[status] and not state.saw_failure_status then
      state.saw_failure_status = true
      append_status_failure(state)
    end
  end

  local done = false
  for _, status in ipairs(message.status or {}) do
    if status == 'done' then done = true end
  end

  if done then
    if state.op == 'test-var-query' and state.summary then
      local total = tonumber(state.summary.test or state.summary['test']) or 0
      if total == 0 then
        append_no_match_warning(state)
      else
        append_summary(state, state.summary)
      end
    end
    flush(state)
    if state.op == 'test-var-query' and state.pending and #state.pending > 0
        and stacktrace.test_op_available(state.client) then
      fetch_traces(state) -- refreshes + finishes asynchronously once traces arrive
    else
      M.after_done(state)
    end
  elseif #state.items > 0 then
    flush(state) -- live update as fails stream in
  end
  return state.items
end

-- Fired once per request on the `done` status, after the live quickfix
-- list is populated. Opens the cwindow without yanking focus (fireplace
-- behaviour) and echoes Success/Failure so the user doesn't have to peek at
-- the qf list to know what happened.
function M.after_done(state)
  local failures = 0
  for _, it in ipairs(state.items or {}) do
    if it and (it.type == 'E' or it.type == 'W') then failures = failures + 1 end
  end

  if state.open_qf then
    local cur_winid = vim.fn.win_getid()
    quickfix.populated()        -- let qf plugins react now (once), not mid-stream
    vim.cmd('botright cwindow')  -- and open for setups without such a plugin
    if vim.fn.win_getid() ~= cur_winid then vim.fn.win_gotoid(cur_winid) end
  end

  if state.label and state.label ~= '' then
    local prefix = failures == 0 and 'Success: ' or 'Failure: '
    local hl = failures == 0 and 'MoreMsg' or 'WarningMsg'
    vim.api.nvim_echo({ { prefix .. state.label, hl } }, false, {})
  end
end

function M.run(kind, opts)
  opts = opts or {}
  local client = opts.client
  if not client then
    local campfire = require('campfire')
    local err
    if campfire.ensure_current then
      client, err = campfire.ensure_current()
    else
      client = campfire.current()
    end
    if not client then return nil, err or 'Campfire: no live nREPL connection' end
  end
  local runtime_name = opts.runtime or client.lang or require('campfire').runtime({})
  opts = vim.tbl_extend('force', { describe = client.describe or {}, runtime = runtime_name }, opts)
  local request, err = M.request(kind, opts)
  if err then return nil, err end
  -- lg has no per-test metadata, so we route every qf item to the buffer
  -- the user invoked tests from. Better than empty filename + lnum 0.
  local buffer_file
  if runtime_name == 'lg' then
    local name = vim.api.nvim_buf_get_name(opts.bufnr or 0)
    if name and name ~= '' then buffer_file = name end
  end
  local state = {
    title = opts.title or ('Campfire tests' .. (opts.label and (' — ' .. opts.label) or '')),
    label = opts.label,
    open_qf = opts.open_qf,
    runtime = runtime_name,
    buffer_file = buffer_file,
    client = client,
    op = request.op,
  }
  -- cider tags a test run's stdout/stderr with a stale message id (the
  -- session's *out* writer, captured at the last eval — not the op), so the
  -- id-based router drops it. Listen on the op's session for the run's
  -- duration to recover user prints (println/prn inside tests), matching the
  -- TSV/lg paths where output rides the single eval id. Cleared on done.
  local function send_op()
    if request.op == 'test-var-query' and client.set_output_listener then
      local sid = request.session or (client.session and client:session('user'))
      if sid then
        state.out_session = sid
        client:set_output_listener(sid, function(message) M.handle_output(state, message) end)
      end
    end
    return client:request(request, function(message)
      M.handle_output(state, message)
      if state.out_session then
        for _, s in ipairs(message.status or {}) do
          if s == 'done' then client:set_output_listener(state.out_session, nil) end
        end
      end
    end)
  end

  -- cider's test-var-query selects vars via find-ns. orchard only honours
  -- :load-project-ns? in its no-:exactly branch, so a specific test ns that was
  -- never required reports `namespace-not-found` (and we'd show "no matching
  -- tests"). Require the involved nses up front — same `:reload` pre-step
  -- fireplace uses — then run the op; surface a load failure rather than running
  -- against a missing ns. (The eval/TSV paths already require inside their wrap.)
  if request.op == 'test-var-query' then
    local to_load = involved_nses(opts)
    if #to_load > 0 then
      -- cljs's REPL-special require is the bare symbol; clojure.core/require only
      -- resolves on the JVM (mirrors build_tsv_wrap's per-spec require_sym).
      local require_sym = CLJS_FAMILY[runtime_name] and 'require' or 'clojure.core/require'
      local code = '(' .. require_sym .. ' ' .. quoted(to_load, "'") .. ' :reload)'
      local failed, err_text
      return client:request(
        { op = 'eval', code = code, session = request.session, scope = 'user' },
        function(msg)
          if msg.err then err_text = (err_text or '') .. msg.err end
          if msg.ex then failed = true; err_text = err_text or msg.ex end
          for _, s in ipairs(msg.status or {}) do
            if s == 'eval-error' then failed = true end
            if s == 'done' then
              if failed then
                state.last_err = err_text
                  or ('namespace-load-failed: ' .. table.concat(to_load, ','))
                M.handle_output(state, { status = { 'error', 'done' } })
              else
                send_op()
              end
            end
          end
        end)
    end
  end
  return send_op()
end

-- Identify the def-form var at the cursor regardless of which macro defined
-- it. Walks top-level forms, finds the one containing `row`, and reads the
-- name token after the head + any leading ^meta / ^{...} metadata. Catches
-- deftest, defspec, deftest-check, deftest-check-ns, deftest-checking-async,
-- defn ^{:test (fn …)} foobar, and any future def* macro.
function M.var_at_cursor(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or 0
  local row = opts.row or vim.api.nvim_win_get_cursor(0)[1]
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then return nil end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local form = runtime.form_at_line(table.concat(lines, '\n'), row)
  if not form then return nil end
  local def = runtime.parse_def(form.code)
  return def and def.name or nil
end

local function label_for(kind, opts)
  if kind == 'expr' then return opts.expr or '<expr>' end
  if opts.patterns and #opts.patterns > 0 then
    return 'all tests #"' .. table.concat(opts.patterns, '|') .. '"'
  end
  if opts.targets and #opts.targets > 0 then
    return table.concat(opts.targets, ' ')
  end
  if kind == 'all' then return 'all tests' end
  return opts.var or opts.ns or '<unknown>'
end

function M.command(args)
  local bang, line1, _, text, override = args[1], args[2], args[3], args[4], args[5]
  text = text or ''
  local open_qf = bang == 0

  if override == 'expr' then
    local opts = { expr = text, open_qf = open_qf, label = text }
    local _, err = M.run('expr', opts)
    if err then return 'echoerr ' .. vim.fn.string(err) end
    return ''
  end

  -- Tokenize whitespace-separated args. Fireplace's `:RunTests ns1 ns2` and
  -- `:0RunTests pat1 pat2` both depend on multi-arg splitting.
  local tokens = {}
  for tok in text:gmatch('%S+') do tokens[#tokens + 1] = tok end

  -- Fireplace parity. Argument shape depends on whether a range was given:
  --   :RunTests            → all tests, no pattern
  --   :RunTests pat …      → (run-all-tests #"pat1|pat2") regex, no range
  --   :0RunTests pat …     → same as above (explicit 0 range)
  --   :.RunTests           → current ns + var-at-cursor
  --   :.RunTests a b a/x   → mix of nses (run-tests) and vars (test-vars)
  local kind, opts
  if line1 == 0 then
    if #tokens == 0 then
      kind, opts = 'all', {}
    else
      kind, opts = 'all', { patterns = tokens }
    end
  else
    if #tokens > 0 then
      kind, opts = 'targets', { targets = tokens }
    else
      local current = runtime.ns()
      if not current then
        return 'echoerr ' .. vim.fn.string('Campfire: no current namespace')
      end
      local var = M.var_at_cursor({ row = line1 > 0 and line1 or nil })
      if var then
        kind, opts = 'var', { var = current .. '/' .. var }
      else
        kind, opts = 'ns', { ns = current }
      end
    end
  end

  opts.open_qf = open_qf
  opts.label = label_for(kind, opts)
  local _, err = M.run(kind, opts)
  if err then return 'echoerr ' .. vim.fn.string(err) end
  return ''
end

return M
