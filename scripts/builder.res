/***
 * The builder, a Nix store in a container building every machine's system, and a system copied
 * from it to a machine and switched to, so the machine builds nothing, RFC n0o4l, docs/local.md.
 */

type spawned = {status: Nullable.t<int>, stdout: Nullable.t<string>, stderr: Nullable.t<string>}
type spawnOptions = {stdio: array<string>, encoding: string, env?: Dict.t<string>, cwd?: string}
@module("node:child_process")
external spawnSync: (string, array<string>, spawnOptions) => spawned = "spawnSync"
@module("node:fs") external readFileSync: (string, @as("utf8") _) => string = "readFileSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:fs") external readdirSync: string => array<string> = "readdirSync"
@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:fs") external realpathSync: string => string = "realpathSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"
@module("node:os") external homedir: unit => string = "homedir"
@module("node:path") @variadic external join: array<string> => string = "join"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"
@val external isMain: bool = "import.meta.main"
@val external env: Dict.t<string> = "process.env"
@val external argv: array<string> = "process.argv"
@val
external with_: (@as(json`{}`) _, Dict.t<string>, Dict.t<string>) => Dict.t<string> =
  "Object.assign"
type process
@val external process: process = "process"
@set external setExitCode: (process, int) => unit = "exitCode"

/** This repository, monoflake/machine, wherever the script is compiled from. */
let root = join([fileURLToPath(importMetaUrl), "..", ".."])

let container = "machine-builder"
let volume = "machine-builder"
let port = "2221"
let image = "nixos/nix:2.35.4@sha256:f159a58f390677f41e8e900a74b6e2f9c7f27b364122ae6acf7a652ce6c551c0"
let store = `ssh-ng://${container}`
/** A container reached by ssh, its name, the port it is published on and its host key's file. */
type reached = {name: string, port: string, hostKey: string}
let builder = {name: container, port, hostKey: "/nix/var/machine-builder/ssh_host_ed25519_key.pub"}

let args = argv->Array.slice(~start=2)
let fail = why => {
  Console.error(why)
  process->setExitCode(1)
}

/** A command run with its output shown, and whether it succeeded. */
let ran = (~env=?, command, arguments) =>
  spawnSync(
    command,
    arguments,
    {stdio: ["ignore", "inherit", "inherit"], encoding: "utf8", ?env},
  ).status->Nullable.toOption == Some(0)

/** A command run with its errors shown, and what it wrote, or none when it failed. */
let said = (~env=?, command, arguments) => {
  let run = spawnSync(
    command,
    arguments,
    {stdio: ["ignore", "pipe", "inherit"], encoding: "utf8", ?env},
  )
  run.status->Nullable.toOption == Some(0)
    ? Some(run.stdout->Nullable.toOption->Option.getOr("")->String.trim)
    : None
}

/** A command run with nothing shown, and what it wrote, or none when it failed. */
let quiet = (command, arguments) => {
  let run = spawnSync(command, arguments, {stdio: ["ignore", "pipe", "pipe"], encoding: "utf8"})
  run.status->Nullable.toOption == Some(0)
    ? Some(run.stdout->Nullable.toOption->Option.getOr("")->String.trim)
    : None
}

let pause = () =>
  spawnSync("sleep", ["0.2"], {stdio: ["ignore", "ignore", "ignore"], encoding: "utf8"})->ignore

/** What `ready` gives, tried every 200 ms for `seconds`. */
let waited = (seconds, ready) => {
  let rec attempt = left =>
    switch ready() {
    | Some(value) => Some(value)
    | None if left > 0 =>
      pause()
      attempt(left - 1)
    | None => None
    }
  attempt(seconds * 5)
}

/** Phase durations are formatted here for synchronous and asynchronous work. */
let duration = milliseconds => (milliseconds /. 1000.)->Float.toFixed(~digits=1) ++ "s"

let reported = (~say=Console.log, ~warn=Console.error, name, took, result, told) => {
  switch result {
  | Ok(value) => say(`${name} ${duration(took)}, ${told(value)}`)
  | Error(why) => warn(`${name} failed after ${duration(took)}, ${why}`)
  }
  result
}

/** A phase run and its time printed using Builder's duration format. */
let timed = (~now=Date.now, ~say=Console.log, ~warn=Console.error, name, run, told) => {
  let started = now()
  let result = run()
  reported(~say, ~warn, name, now() -. started, result, told)
}

type timer
@module("node:timers") external setInterval: (unit => unit, int) => timer = "setInterval"
@module("node:timers") external clearInterval: timer => unit = "clearInterval"

/** An awaited phase with an optional heartbeat, cleared even when the action throws. */
let timedAsync = async (
  ~now=Date.now,
  ~say=Console.log,
  ~warn=Console.error,
  ~heartbeat=?,
  name,
  run,
  told,
) => {
  let started = now()
  let timer =
    heartbeat->Option.map(milliseconds =>
      setInterval(() => say(`${name} running, ${duration(now() -. started)}`), milliseconds)
    )
  try {
    let result = await run()
    timer->Option.forEach(clearInterval)
    reported(~say, ~warn, name, now() -. started, result, told)
  } catch {
  | e =>
    timer->Option.forEach(clearInterval)
    throw(e)
  }
}

let normalizedKeys = texts => {
  let seen = Set.make()
  texts
  ->Array.flatMap(text => text->String.split("\n"))
  ->Array.map(line =>
    line
    ->String.trim
    ->String.replaceRegExp(/\s+/g, " ")
    ->String.split(" ")
    ->Array.slice(~start=0, ~end=2)
    ->Array.join(" ")
  )
  ->Array.filter(key => {
    let fresh =
      (key->String.startsWith("ssh-") || key->String.startsWith("ecdsa-")) && !(seen->Set.has(key))
    seen->Set.add(key)
    fresh
  })
  ->Array.toSorted((a, b) => compare(a, b)->Int.toFloat)
}

let fileKeys = (~directory=join([homedir(), ".ssh"]), ()) =>
  (
    existsSync(directory)
      ? readdirSync(directory)
        ->Array.filter(name => name->String.startsWith("id_") && name->String.endsWith(".pub"))
        ->Array.map(name => readFileSync(join([directory, name])))
      : []
  )->normalizedKeys

let keys = () => normalizedKeys([quiet("ssh-add", ["-L"])->Option.getOr(""), ...fileKeys()])
let entry = () => readFileSync(join([root, "builder", "entry.sh"]))
let fileKeysLabel = "machine-builder.file-keys"
let keyRecord = keys => keys->Array.join("\n")

let exists = name => quiet("docker", ["inspect", "--format", "{{.Id}}", name])->Option.isSome
let running = name =>
  quiet("docker", ["inspect", "--format", "{{.State.Running}}", name]) == Some("true")

/** A container stopped and removed, its volumes kept; one absent is already gone. */
let removed = name =>
  !exists(name) ||
  (quiet("docker", ["stop", "--time", "30", name])->Option.isSome &&
    quiet("docker", ["rm", name])->Option.isSome)

/** An ssh configuration naming each container by its port and host key, read from the container,
 * ahead of this computer's own, so neither is written to. */
let configured = (containers: array<reached>) => {
  let directory = mkdtempSync(join([tmpdir(), "ssh-"]))
  let known = join([directory, "known_hosts"])
  // By the shell's own builtins, as nothing else is on a NixOS container's PATH under docker exec.
  let read =
    containers->Array.map(c =>
      quiet(
        "docker",
        ["exec", c.name, "/bin/sh", "-c", `read -r key < ${c.hostKey} && echo "$key"`],
      )
    )
  switch read->Array.every(Option.isSome) {
  | false => None
  | true =>
    writeFileSync(
      known,
      containers
      ->Array.mapWithIndex((c, i) => `${c.name} ${read->Array.getUnsafe(i)->Option.getOr("")}\n`)
      ->Array.join(""),
    )
    let hosts =
      containers->Array.map(c =>
        [
          `Host ${c.name}`,
          "  HostName localhost",
          `  Port ${c.port}`,
          "  User root",
          `  HostKeyAlias ${c.name}`,
          `  UserKnownHostsFile ${known}`,
          "  StrictHostKeyChecking yes",
          "  BatchMode yes",
        ]->Array.join("\n")
      )
    let config = join([directory, "config"])
    writeFileSync(
      config,
      [
        ...hosts,
        "Match all",
        "Include ~/.ssh/config",
        "Include /etc/ssh/ssh_config",
        "",
      ]->Array.join("\n"),
    )
    Some(config)
  }
}

/** Nix's environment with ssh reading `config`. */
let nixEnv = config => with_(env, Dict.fromArray([("NIX_SSHOPTS", `-F ${config}`)]))

/** Builder owns the exclusions for layouts copied for Nix. */
let excluded = [".jj", ".git", "node_modules", "/lib", "/result*", "target", ".DS_Store"]

let copyRun = (~cwd, args) =>
  spawnSync(
    "rsync",
    args,
    {
      stdio: ["ignore", "inherit", "inherit"],
      encoding: "utf8",
      cwd,
    },
  ).status->Nullable.toOption == Some(0)

/** Paths copied in a repository's layout, or the whole directory when no paths are given. */
let copied = (~paths=[], ~excluded=excluded, ~into=?, ~run=copyRun, directory) => {
  let copy = switch into {
  | Some(copy) => copy
  // Nix refuses a path flake reached through a symlink, as macOS gives its temporary directory.
  | None => realpathSync(mkdtempSync(join([tmpdir(), "flake-"])))
  }
  run(
    ~cwd=directory,
    [
      paths == [] ? "-a" : "-aR",
      ...excluded->Array.map(p => `--exclude=${p}`),
      ...paths == [] ? ["./"] : paths,
      `${copy}/`,
    ],
  )
    ? Some(copy)
    : None
}

/** Whether the builder's store answers through `config`. */
let answering = config =>
  waited(30, () =>
    spawnSync(
      "nix",
      ["store", "info", "--store", store],
      {stdio: ["ignore", "ignore", "ignore"], encoding: "utf8", env: nixEnv(config)},
    ).status->Nullable.toOption == Some(0)
      ? Some()
      : None
  )->Option.isSome

/** The builder made anew, any container of its name removed first, its volume kept. */
let made = () => {
  let given = keys()
  if given == [] {
    Error("no SSH public key in `ssh-add -L` or ~/.ssh/id_*.pub to log in to it with")
  } else if !removed(container) {
    Error(`${container} not stopped`)
  } else if (
    quiet(
      "docker",
      [
        "run",
        "--detach",
        "--name",
        container,
        "--privileged",
        "--restart",
        "unless-stopped",
        // A listen address, on this computer alone.
        "--publish",
        `127.0.0.1:${port}:22`,
        "--volume",
        `${volume}:/nix`,
        "--env",
        `KEYS=${given->Array.join("\n")}`,
        "--label",
        `${fileKeysLabel}=${keyRecord(fileKeys())}`,
        image,
        "sh",
        "-c",
        entry(),
      ],
    )->Option.isNone
  ) {
    Error(`${container} did not start`)
  } else {
    switch waited(60, () => configured([builder])) {
    | None => Error(`${container} made no host key`)
    | Some(config) => answering(config) ? Ok(config) : Error(`${store} did not answer`)
    }
  }
}

/** The builder running and answering, its ssh configuration, or none. */
let reused = () => running(container) ? configured([builder])->Option.filter(answering) : None

let parsed = text =>
  try Some(JSON.parseOrThrow(text)) catch {
  | _ => None
  }

let matching = (~given, ~files, ~script, config) => {
  let field = name => config->JSON.Decode.object->Option.flatMap(o => o->Dict.get(name))
  let text = name => field(name)->Option.flatMap(JSON.Decode.string)
  let authorized =
    field("Env")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filterMap(JSON.Decode.string)
    ->Array.find(v => v->String.startsWith("KEYS="))
    ->Option.map(v => normalizedKeys([v->String.replaceRegExp(/^KEYS=/, "")]))
    ->Option.getOr([])
  let recorded =
    field("Labels")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.flatMap(o => o->Dict.get(fileKeysLabel))
    ->Option.flatMap(JSON.Decode.string)
  text("Image") == Some(image) &&
  field("Cmd") == Some(JSON.Array([JSON.String("sh"), JSON.String("-c"), JSON.String(script)])) &&
  recorded == Some(keyRecord(files)) &&
  given->Array.every(key => authorized->Array.includes(key))
}

let current = given =>
  quiet("docker", ["inspect", "--format", "{{json .Config}}", container])
  ->Option.flatMap(parsed)
  ->Option.mapOr(false, config => matching(~given, ~files=fileKeys(), ~script=entry(), config))

type database
@module("node:sqlite") @new external database: string => database = "DatabaseSync"
@send external exec: (database, string) => unit = "exec"
@send external close: database => unit = "close"
@module("node:fs")
external mkdirSync: (string, {"recursive": bool, "mode": int}) => unit = "mkdirSync"

let lockPath = home => join([home, ".local", "state", container, "lock"])
let lock = lockPath(homedir())
let lease: ref<option<database>> = ref(None)

let opened = path => {
  mkdirSync(join([path, ".."]), {"recursive": true, "mode": 0o700})
  database(path)
}

let taken = db =>
  try {
    db->exec("BEGIN EXCLUSIVE")
    Some()
  } catch {
  | JsExn(e) if JsExn.message(e) == Some("database is locked") => None
  }

let acquired = (~seconds=300, ~say=Console.error, path, db) => {
  let attempts = ref(0)
  waited(seconds, () => {
    switch taken(db) {
    | Some() => Some()
    | None =>
      if mod(attempts.contents, 25) == 0 {
        say(
          `builder: waiting for ${path}, ${duration(
              Int.toFloat(attempts.contents) *. 200.,
            )} elapsed`,
        )
      }
      attempts := attempts.contents + 1
      None
    }
  })->Option.mapOr(
    Error(`a running caller held ${path} past ${Int.toString(seconds)} seconds`),
    _ => Ok(),
  )
}

let released = db => {
  db->exec("ROLLBACK")
  db->close
}

// A reuse lease lasts through its caller's build and copy and is released by process exit.
let held = (~retain=false, ~path=lock, make) =>
  switch lease.contents {
  | Some(_) => make()
  | None =>
    let db = opened(path)
    switch acquired(path, db) {
    | Error(why) =>
      db->close
      Error(why)
    | Ok() =>
      lease := Some(db)
      try {
        let result = make()
        if !retain || result->Result.isError {
          lease := None
          released(db)
        }
        result
      } catch {
      | e =>
        lease := None
        released(db)
        throw(e)
      }
    }
  }

/** How a builder came to answer, reused as it ran or made anew. */
type answered = Reused(string) | Made(string)

/** The builder reused where it runs and answers, and otherwise made by one caller at a time; with
 * `fresh`, one from another image, entry script or keys is made anew too. */
let up = (~fresh, ~path=lock, ~reuse=reused, ~make=made, ~isCurrent=() => current(keys())) =>
  held(~path, ~retain=!fresh, () => {
    switch reuse()->Option.filter(_ => !fresh || isCurrent()) {
    | Some(config) => Ok(Reused(config))
    | None => make()->Result.map(config => Made(config))
    }
  })

/** The builder reused or made, and the ssh configuration reaching it and `others`. */
let started = others =>
  up(~fresh=false)->Result.flatMap(_ => {
    if !current(keys()) {
      Console.error(
        `${container} runs another image, entry script or other keys; \`builder up\` makes it anew`,
      )
    }
    configured([builder, ...others])->Option.mapOr(Error("a host key not read"), c => Ok(c))
  })

let built = (~config, arguments) =>
  switch said(
    ~env=nixEnv(config),
    "nix",
    [
      "build",
      "--eval-store",
      "auto",
      "--store",
      store,
      "--no-link",
      "--print-out-paths",
      ...arguments,
    ],
  ) {
  | Some(path) if path->String.startsWith("/nix/store/") => Ok(path)
  | _ => Error("nix build failed")
  }

/** What `target` lacks of `path`'s closure copied from the builder through this computer, and how
 * many paths that was. */
let sent = (~config, path, target) => {
  let run = spawnSync(
    "nix",
    ["copy", "--no-check-sigs", "--from", store, "--to", `ssh-ng://${target}`, path],
    {stdio: ["ignore", "inherit", "pipe"], encoding: "utf8", env: nixEnv(config)},
  )
  let lines = run.stderr->Nullable.toOption->Option.getOr("")->String.split("\n")
  run.status->Nullable.toOption == Some(0)
    ? Ok(lines->Array.filter(line => line->String.startsWith("copying path "))->Array.length)
    : {
        lines->Array.forEach(line => Console.error(line))
        Error("nix copy failed")
      }
}

/** `target`'s system profile set to `path` and switched to, never rebooting. */
let switched = (~config, path, target) =>
  ran(
    "ssh",
    [
      "-F",
      config,
      target,
      `nix-env -p /nix/var/nix/profiles/system --set ${path} && ${path}/bin/switch-to-configuration switch`,
    ],
  )
    ? Ok(path)
    : Error(`${target} did not switch, journalctl there says why`)

/** A system built in the builder by `arguments`, copied to `target` and switched to there. */
let deployed = (~config, ~target, arguments) =>
  timed("build", () => built(~config, arguments), path => path)
  ->Result.flatMap(path =>
    timed(
      "copy",
      () => sent(~config, path, target),
      n => `${Int.toString(n)} paths to ${target}`,
    )->Result.map(_ => path)
  )
  ->Result.flatMap(path =>
    timed("switch", () => switched(~config, path, target), _ => `${target} runs it`)
  )

if isMain {
  let dry = args->Array.includes("--dry-run")
  switch args->Array.find(a => !(a->String.startsWith("--"))) {
  | Some("up") if dry =>
    Console.log(
      `would reuse ${container} where it runs and answers from this image, entry script and keys,`,
    )
    Console.log(
      `  and otherwise, holding ${lock}, stop and remove it, keeping the volume ${volume},`,
    )
    Console.log(`  and run ${image} as ${container}, privileged, its store the volume ${volume}`)
    Console.log(`would publish its sshd on localhost:${port}, root reached by this computer's keys`)
  | Some("up") =>
    switch up(~fresh=true) {
    | Ok(Reused(_)) =>
      Console.log(`builder: ${container} reused, answering as ${store} on localhost:${port}`)
    | Ok(Made(_)) =>
      Console.log(`builder: ${container} made, answering as ${store} on localhost:${port}`)
    | Error(why) => fail(`builder: ${why}`)
    }
  | Some("down") if dry =>
    Console.log(
      `would hold ${lock}, then stop and remove ${container}, keeping the volume ${volume}`,
    )
  | Some("down") =>
    switch held(() => removed(container) ? Ok() : Error(`${container} not removed`)) {
    | Ok() => Console.log(`builder: ${container} removed, its store kept in ${volume}`)
    | Error(why) => fail(`builder: ${why}`)
    }
  | _ => fail("builder: say up or down, `builder up`")
  }
}
