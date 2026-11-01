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

type child
@module("node:child_process")
external spawn: (string, array<string>, Builder.spawnOptions) => child = "spawn"
@send external kill: (child, string) => bool = "kill"
@scope("JSON") @val external stringify: 'a => string = "stringify"

let modulePath = Builder.join([Builder.root, "scripts", "builder.res.mjs"])->stringify
let launched = source =>
  spawn(
    "node",
    ["--input-type=module", "-e", source],
    {
      stdio: ["ignore", "ignore", "inherit"],
      encoding: "utf8",
    },
  )
let present = path =>
  Builder.waited(5, () => Builder.existsSync(path) ? Some() : None)->Option.isSome

let fixture = (
  ~script="entry",
  ~files=["ssh-ed25519 disk"],
  ~authorized=["ssh-ed25519 disk", "ssh-ed25519 agent"],
  (),
) =>
  Builder.parsed(
    stringify({
      "Image": Builder.image,
      "Cmd": ["sh", "-c", script],
      "Labels": Dict.fromArray([(Builder.fileKeysLabel, Builder.keyRecord(files))]),
      "Env": [`KEYS=${Builder.keyRecord(authorized)}`],
    }),
  )->Option.getOrThrow

test(
  "freshness includes the entry script and disk keys but tolerates an absent agent",
  async () => {
    let check = (~given=["ssh-ed25519 disk"], ~files=["ssh-ed25519 disk"], ~script="entry", c) =>
      Builder.matching(~given, ~files, ~script, c)
    ok(check(fixture()))
    ok(!check(~script="changed entry", fixture()))
    ok(!check(~given=["ssh-ed25519 new"], fixture()))
    ok(!check(~files=[], fixture()))
    ok(!check(~files=["ssh-ed25519 disk", "ssh-ed25519 new"], fixture()))
    ok(check(~given=["ssh-ed25519 disk", "ssh-ed25519 agent"], fixture()))
    equal(
      Builder.normalizedKeys([
        "ssh-ed25519 disk comment\nssh-ed25519   disk other",
        "ecdsa-sha2-nistp256 xyz comment",
      ]),
      ["ecdsa-sha2-nistp256 xyz", "ssh-ed25519 disk"],
    )
    let at = scratch()
    Builder.writeFileSync(Builder.join([at, "id_test.pub"]), "ssh-ed25519 disk comment")
    equal(Builder.fileKeys(~directory=at, ()), ["ssh-ed25519 disk"])
  },
)

test("lock location does not depend on a caller's temporary directory", async () => {
  equal(Builder.lockPath("/home/test"), "/home/test/.local/state/machine-builder/lock")
})

test("a retained reuse lease fences replacement until its caller releases it", async () => {
  let path = Builder.join([scratch(), "lock"])
  let contender = Builder.opened(path)
  equal(
    Builder.up(
      ~path,
      ~fresh=false,
      ~reuse=() => {
        equal(Builder.taken(contender), None)
        Some("config")
      },
      ~make=() => Error("must reuse"),
    ),
    Ok(Builder.Reused("config")),
  )
  equal(Builder.taken(contender), None)
  let messages = []
  ok(
    Builder.acquired(
      ~seconds=0,
      ~say=s => messages->Array.push(s),
      path,
      contender,
    )->Result.isError,
  )
  ok(messages->Array.some(s => s->String.includes("waiting for")))
  Builder.lease.contents->Option.forEach(Builder.released)
  Builder.lease := None
  equal(Builder.taken(contender), Some())
  Builder.released(contender)
  let guard = Builder.opened(path)
  let checked = ref(false)
  equal(
    Builder.up(
      ~path,
      ~fresh=true,
      ~reuse=() => Some("old"),
      ~isCurrent=() => {
        equal(Builder.taken(guard), None)
        checked := true
        false
      },
      ~make=() => {
        equal(Builder.taken(guard), None)
        Ok("new")
      },
    ),
    Ok(Builder.Made("new")),
  )
  ok(checked.contents)
  equal(Builder.taken(guard), Some())
  Builder.released(guard)
  equal(Builder.held(~path, () => Error("refused")), Error("refused"))
  let next = Builder.opened(path)
  equal(Builder.taken(next), Some())
  Builder.released(next)
  let threw = ref(false)
  try {
    let _ = Builder.held(~path, () => throw(Refused))
  } catch {
  | Refused => threw := true
  }
  ok(threw.contents)
  let last = Builder.opened(path)
  equal(Builder.taken(last), Some())
  Builder.released(last)
})

test(
  "process death releases the lock without a pid record and competing takeovers serialize",
  async () => {
    let at = scratch()
    let path = Builder.join([at, "lock"])->stringify
    let ready = Builder.join([at, "ready"])
    let holder = launched(
      `import * as b from ${modulePath};
import {writeFileSync} from "node:fs";
const db=b.opened(${path}); db.exec("BEGIN EXCLUSIVE");
writeFileSync(${stringify(ready)}, "ready");
setInterval(()=>{},1000);`,
    )
    let started = present(ready)
    let _ = holder->kill("SIGKILL")
    ok(started)
    let log = Builder.join([at, "events"])
    let children = [0, 1, 2]->Array.map(i => {
      let done = Builder.join([at, `done${Int.toString(i)}`])
      let child = launched(
        `import * as b from ${modulePath};
import {appendFileSync,writeFileSync} from "node:fs";
const db=b.opened(${path});
const result=b.acquired(5, ()=>{}, ${path}, db);
if(result.TAG!=="Ok") process.exit(1);
appendFileSync(${stringify(log)}, ${stringify("enter\n")});
Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,30);
appendFileSync(${stringify(log)}, ${stringify("exit\n")});
b.released(db); writeFileSync(${stringify(done)}, "done");`,
      )
      (child, done)
    })
    let finished = children->Array.every(((_, done)) => present(done))
    children->Array.forEach(((child, _)) => child->kill("SIGKILL")->ignore)
    ok(finished)
    equal(Builder.readFileSync(log), "enter\nexit\nenter\nexit\nenter\nexit\n")
    await sleep(10)
  },
)
