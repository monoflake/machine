@module("node:test") external test: (string, unit => promise<unit>) => unit = "test"
@module("node:assert/strict") external equal: ('a, 'a) => unit = "deepStrictEqual"
@module("node:assert/strict") external ok: bool => unit = "ok"
@module("node:fs") external mkdirSync: (string, {"recursive": bool}) => unit = "mkdirSync"
@module("node:timers/promises") external sleep: int => promise<unit> = "setTimeout"

let scratch = () => Builder.mkdtempSync(Builder.join([Builder.tmpdir(), "builder-test-"]))
let put = (at, file) => {
  let path = Builder.join([at, file])
  mkdirSync(Builder.join([path, ".."]), {"recursive": true})
  Builder.writeFileSync(path, file)
}

test("layout copies share exclusions and retain nested library and result paths", async () => {
  let at = scratch()
  let kept = ["flake.nix", "system/lib/module.nix", "system/result-data/module.nix"]
  let omitted = [
    ".jj/state",
    ".git/config",
    "node_modules/a/file",
    "lib/file",
    "result-one/file",
    "system/target/file",
    "target/file",
    "system/.DS_Store",
    ".DS_Store",
  ]
  [...kept, ...omitted]->Array.forEach(file => put(at, file))
  let copy = Builder.copied(at)->Option.getOr("")
  ok(copy != "")
  kept->Array.forEach(file => ok(Builder.existsSync(Builder.join([copy, file]))))
  omitted->Array.forEach(file => ok(!Builder.existsSync(Builder.join([copy, file]))))
  let paths = Builder.copied(~paths=["system"], at)->Option.getOr("")
  ok(Builder.existsSync(Builder.join([paths, "system/lib/module.nix"])))
  ok(!Builder.existsSync(Builder.join([paths, "flake.nix"])))
  let custom = Builder.copied(~excluded=["flake.nix"], at)->Option.getOr("")
  ok(!Builder.existsSync(Builder.join([custom, "flake.nix"])))
  ok(Builder.existsSync(Builder.join([custom, "target/file"])))
  equal(Builder.copied(~run=(~cwd, _) => {
      ignore(cwd)
      false
    }, at), None)
})

test("sync and async phases share duration and failure formatting", async () => {
  let said = []
  let warned = []
  let tick = ref(0.)
  let now = () => {
    let before = tick.contents
    tick := before +. 1250.
    before
  }
  let say = s => said->Array.push(s)
  let warn = s => warned->Array.push(s)
  equal(Builder.timed(~now, ~say, ~warn, "copy", () => Ok(3), n => Int.toString(n)), Ok(3))
  equal(
    await Builder.timedAsync(~now, ~say, ~warn, "copy", async () => Ok(3), n => Int.toString(n)),
    Ok(3),
  )
  equal(
    Builder.timed(~now, ~say, ~warn, "copy", () => Error("refused"), n => Int.toString(n)),
    Error("refused"),
  )
  equal(
    await Builder.timedAsync(
      ~now,
      ~say,
      ~warn,
      "copy",
      async () => Error("refused"),
      n => Int.toString(n),
    ),
    Error("refused"),
  )
  equal(said, ["copy 1.3s, 3", "copy 1.3s, 3"])
  equal(warned, ["copy failed after 1.3s, refused", "copy failed after 1.3s, refused"])
})

exception Refused

test("async heartbeats stop after completion and rejection", async () => {
  let said = []
  let say = s => said->Array.push(s)
  let run = async () => {
    await sleep(20)
    Ok()
  }
  equal(await Builder.timedAsync(~say, ~heartbeat=1, "copy", run, _ => "done"), Ok())
  ok(said->Array.some(s => s->String.startsWith("copy running, ")))
  let completed = said->Array.length
  await sleep(10)
  equal(said->Array.length, completed)
  let refused = ref(false)
  try {
    let _ = await Builder.timedAsync(
      ~say,
      ~heartbeat=1,
      "copy",
      async () => {
        await sleep(20)
        throw(Refused)
      },
      _ => "done",
    )
  } catch {
  | Refused => refused := true
  }
  ok(refused.contents)
  let rejected = said->Array.length
  await sleep(10)
  equal(said->Array.length, rejected)
})
