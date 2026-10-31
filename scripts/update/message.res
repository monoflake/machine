// The scheduled message uses .github/update for moved locks and the workspace builder otherwise.
// The workspace's docs/ci.md defines the workflow entry.

@module("node:child_process")
external spawnSync: (
  string,
  array<string>,
  {"cwd": string, "encoding": string, "maxBuffer": int, "input": string, "env": Dict.t<string>},
) => {"status": Nullable.t<int>, "stdout": string, "stderr": string} = "spawnSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external mkdirSync: string => unit = "mkdirSync"
@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"
@module("node:path") external resolve: string => string = "resolve"
@val external argv: array<string> = "process.argv"
@val external env: Dict.t<string> = "process.env"
@val external exit: int => unit = "process.exit"
@val external cwd: unit => string = "process.cwd"
@val external assign: (@as(json`{}`) _, Dict.t<string>) => Dict.t<string> = "Object.assign"

let systems = ["x86_64-linux", "aarch64-linux"]
let watched = ["flake.lock", "system/containers/manifest.lock"]

let fail = why => {
  Console.error(`message: ${why}`)
  exit(1)
}

/** A command's stdout, its failure ending the run with what it wrote. */
let run = (~input="", ~path=?, program, args) => {
  let given = assign(env)
  path->Option.forEach(bin =>
    given->Dict.set("PATH", `${bin}:${env->Dict.get("PATH")->Option.getOr("")}`)
  )
  let ran = spawnSync(
    program,
    args,
    {"cwd": cwd(), "encoding": "utf8", "maxBuffer": 1073741824, "input": input, "env": given},
  )
  if ran["status"] != Nullable.make(0) {
    Console.error(ran["stderr"])
    fail(`${program} ${args->Array.join(" ")} failed`)
  }
  ran["stdout"]
}

/** Both systems' closures of the flake at `flake`, as closure.jq reads them, written to `file`. */
let closure = (~nix, flake, file) => {
  let drvs =
    systems->Array.map(system =>
      `${run(
          ~path=nix,
          "nix",
          ["eval", "--raw", `path:${flake}#checks.${system}.machine.drvPath`],
        )}^*`
    )
  let shown = run(~path=nix, "nix", ["derivation", "show", "-r", ...drvs])
  writeFileSync(file, run(~input=shown, "jq", ["-f", ".github/update/closure.jq"]))
}

let flakeMessage = (base, file) => {
  let temp = mkdtempSync(`${base}/machine-message-`)
  let old = `${temp}/old`
  let now = `${temp}/new`
  mkdirSync(old)
  run("git", ["archive", "--format=tar", "-o", `${temp}/old.tar`, "HEAD"])->ignore
  run("tar", ["-xf", `${temp}/old.tar`, "-C", old])->ignore
  if Builder.copied(~into=now, cwd()) == None {
    fail("layout not copied")
  }
  let nix =
    run("node", ["scripts/channel/channel.res.mjs", "path", "--lock", "."])->String.trim ++ "/bin"
  closure(~nix, old, `${temp}/old.json`)
  closure(~nix, now, `${temp}/new.json`)
  let quote = value => value->JSON.Encode.string->JSON.stringify->String.replaceAll("${", "\\${")
  let expression = `import ./.github/update {
  old = ${quote(`path:${old}`)};
  new = ${quote(`path:${now}`)};
  closures = { old = ${quote(`${temp}/old.json`)}; new = ${quote(`${temp}/new.json`)}; };
}`
  writeFileSync(file, run(~path=nix, "nix", ["eval", "--raw", "--impure", "--expr", expression]))
}

switch argv->Array.slice(~start=2) {
| [file] =>
  let changed =
    run("git", ["diff", "--name-only", "-z", "HEAD", "--", ...watched])->String.split("\x00")
  let flakeMoved = changed->Array.some(file => watched->Array.includes(file))
  let temp = env->Dict.get("RUNNER_TEMP")->Option.getOr(tmpdir())->resolve
  if flakeMoved {
    flakeMessage(temp, file)
  } else {
    let workspace = env->Dict.get("GITHUB_WORKSPACE")->Option.orElse(env->Dict.get("WORKSPACE"))
    let workspace = switch workspace {
    | Some(path) => path
    | None =>
      fail("GITHUB_WORKSPACE or WORKSPACE is required")
      ""
    }
    run(
      "node",
      [`${workspace}/scripts/deps/scheduled.res.mjs`, "message", "monoflake/machine", file],
    )->ignore
  }
| _ => fail("message <file>")
}
