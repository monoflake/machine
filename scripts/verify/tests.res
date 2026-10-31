// The shell and eval tests run at once, one per core, each printed whole in the list's order.

@val external exitWith: int => unit = "process.exit"
@module("node:os") external availableParallelism: unit => int = "availableParallelism"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external metaUrl: string = "import.meta.url"
@module("node:path") external dirname: string => string = "dirname"
@module("node:child_process")
external execFile: (
  string,
  array<string>,
  {"cwd": string, "encoding": string, "maxBuffer": int},
  (Nullable.t<JSON.t>, string, string) => unit,
) => unit = "execFile"

type test = {name: string, cwd: string, program: string, args: array<string>}

let root = metaUrl->fileURLToPath->dirname->dirname->dirname

let cache = "system/nix/cache/tests"
let update = "system/nix/update/tests"

let shell = (~cwd=".", path, ~args=[]) => {
  name: [cwd == "." ? path : `${cwd}/${path}`, ...args]->Array.join(" "),
  cwd,
  program: "bash",
  args: [path, ...args],
}

let evaluated = path => {
  name: path,
  cwd: ".",
  program: "nix",
  args: ["eval", "--impure", "--json", "--file", path, "--apply", "f: f {}"],
}

/** Every test verify runs, each holding its own temporary directory, so none waits on another. */
let tests = [
  ...[
    "endpoint-test.sh",
    "fetch/protocol-test.sh",
    "delivery-test.sh",
    "lock-test.sh",
    "outcome-test.sh",
    "fleet-test.sh",
    "module-test.sh",
    "compatibility-test.sh",
    "self-test.sh",
    "upload/run-test.sh",
    "upload/upstream-test.sh",
    "build/build-test.sh",
    "fetch/gc-test.sh",
  ]->Array.map(path => shell(~cwd=cache, path)),
  ...[
    "success",
    "failure",
    "term",
    "self",
    "self-copy-failure",
    "self-gc",
    "gc-error",
  ]->Array.map(mode => shell(~cwd=cache, "build/run-test.sh", ~args=[mode])),
  ...["configured", "copy"]->Array.map(mode =>
    shell(~cwd=cache, "build/self-test.sh", ~args=[mode])
  ),
  shell(~cwd=cache, "fetch/gc-test.sh", ~args=["valid"]),
  ...[
    "fetch-test.sh",
    "driver-test.sh",
    "driver-eval-test.sh",
    "eval-test.sh",
    "nudge-eval-test.sh",
    "nudge-test.sh",
  ]->Array.map(path => shell(`${update}/${path}`)),
  shell("system/base/seed/tests.sh"),
  shell("system/network/tests.sh"),
  shell("system/network/addresses/tests.sh"),
  shell(".github/update/driver-test.sh"),
  evaluated("system/names-test.nix"),
  evaluated("system/base/time/eval-test.nix"),
  evaluated("system/nix/collect-test.nix"),
]

type outcome = {test: test, output: string, passed: bool, seconds: float}

let run = test =>
  Promise.make((resolve, _) => {
    let started = Date.now()
    execFile(
      test.program,
      test.args,
      {"cwd": `${root}/${test.cwd}`, "encoding": "utf8", "maxBuffer": 268435456},
      (error, out, err) =>
        resolve({
          test,
          output: out ++ err,
          passed: error->Nullable.toOption->Option.isNone,
          seconds: (Date.now() -. started) /. 1000.,
        }),
    )
  })

/** Each item started with at most `limit` running, the results in the items' order. */
let pooled = (items: array<'a>, ~limit, start: 'a => promise<'b>): promise<array<'b>> =>
  Promise.make((resolve, _) => {
    let results = Array.make(~length=items->Array.length, None)
    let next = ref(0)
    let finished = ref(0)
    let rec launch = () =>
      if next.contents < items->Array.length {
        let at = next.contents
        next := at + 1
        start(items->Array.getUnsafe(at))
        ->Promise.thenResolve(result => {
          results->Array.setUnsafe(at, Some(result))
          finished := finished.contents + 1
          if finished.contents == items->Array.length {
            resolve(results->Array.filterMap(r => r))
          } else {
            launch()
          }
        })
        ->ignore
      }
    if items == [] {
      resolve([])
    } else {
      for _ in 1 to Math.Int.min(limit, items->Array.length) {
        launch()
      }
    }
  })

let main = async () => {
  let started = Date.now()
  let outcomes = await pooled(tests, ~limit=availableParallelism(), run)
  outcomes->Array.forEach(({test, output, passed, seconds}) => {
    if output->String.trim != "" {
      Console.log(output->String.trimEnd)
    }
    Console.log(
      `${passed ? "passed" : "FAILED"} ${test.name} in ${seconds->Float.toFixed(~digits=0)}s`,
    )
  })
  let failed = outcomes->Array.filter(o => !o.passed)->Array.map(o => o.test.name)
  let total = ((Date.now() -. started) /. 1000.)->Float.toFixed(~digits=0)
  switch failed {
  | [] => Console.log(`tests: ${tests->Array.length->Int.toString} passed in ${total}s`)
  | _ =>
    Console.error(`tests: ${failed->Array.join(", ")} failed`)
    exitWith(1)
  }
}

main()->ignore
