/***
 * The builder, a Nix store in a container building every machine's system, and a system copied
 * from it to a machine and switched to, so the machine builds nothing, RFC n0o4l, docs/local.md.
 */

type spawned = {status: Nullable.t<int>, stdout: Nullable.t<string>, stderr: Nullable.t<string>}
type spawnOptions = {stdio: array<string>, encoding: string, env?: Dict.t<string>}
@module("node:child_process")
external spawnSync: (string, array<string>, spawnOptions) => spawned = "spawnSync"
@module("node:fs") external readFileSync: (string, @as("utf8") _) => string = "readFileSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:fs") external readdirSync: string => array<string> = "readdirSync"
@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
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

/** A phase run and its time printed, beside what `told` makes of its value or why it failed. */
let timed = (name, run, told) => {
  let started = Date.now()
  let result = run()
  let took = ((Date.now() -. started) /. 1000.)->Float.toFixed(~digits=1)
  switch result {
  | Ok(value) => Console.log(`${name} ${took}s, ${told(value)}`)
  | Error(why) => Console.error(`${name} failed after ${took}s, ${why}`)
  }
  result
}

/** The SSH public keys this computer logs in with, its agent's and its own files', each once. */
let keys = () => {
  let directory = join([homedir(), ".ssh"])
  let files = existsSync(directory)
    ? readdirSync(directory)
      ->Array.filter(name => name->String.startsWith("id_") && name->String.endsWith(".pub"))
      ->Array.map(name => readFileSync(join([directory, name])))
    : []
  let agent = quiet("ssh-add", ["-L"])->Option.getOr("")
  let seen = Set.make()
  [agent, ...files]
  ->Array.flatMap(text => text->String.split("\n"))
  ->Array.map(String.trim)
  ->Array.filter(line => {
    let key = line->String.split(" ")->Array.slice(~start=0, ~end=2)->Array.join(" ")
    let fresh =
      (line->String.startsWith("ssh-") || line->String.startsWith("ecdsa-")) &&
        !(seen->Set.has(key))
    seen->Set.add(key)
    fresh
  })
}

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

/** A flake's directory copied whole but for what version control and tools keep, which Nix reads
 * as `path:`, since it reads a flake in place from git's index, the workspace's docs/lessons.md. */
let copied = directory => {
  let copy = mkdtempSync(join([tmpdir(), "flake-"]))
  ran(
    "rsync",
    [
      "-a",
      ...[".jj", ".git", "node_modules", "/lib", "/result*", ".DS_Store"]->Array.map(p =>
        `--exclude=${p}`
      ),
      `${directory}/`,
      `${copy}/`,
    ],
  )
    ? Some(copy)
    : None
}

let up = () => {
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
        image,
        "sh",
        "-c",
        readFileSync(join([root, "builder", "entry.sh"])),
      ],
    )->Option.isNone
  ) {
    Error(`${container} did not start`)
  } else {
    switch waited(60, () => configured([builder])) {
    | None => Error(`${container} made no host key`)
    | Some(config) =>
      switch waited(30, () =>
        spawnSync(
          "nix",
          ["store", "info", "--store", store],
          {stdio: ["ignore", "ignore", "ignore"], encoding: "utf8", env: nixEnv(config)},
        ).status->Nullable.toOption == Some(0)
          ? Some()
          : None
      ) {
      | None => Error(`${store} did not answer`)
      | Some() => Ok(config)
      }
    }
  }
}

/** The builder, started unless it runs, and the ssh configuration reaching it and `others`. */
let started = others =>
  running(container)
    ? configured([builder, ...others])->Option.mapOr(
        Error(`${container} gave no host key`),
        c => Ok(c),
      )
    : up()->Result.flatMap(_ =>
        configured([builder, ...others])->Option.mapOr(Error("a host key not read"), c => Ok(c))
      )

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
    Console.log(`would stop and remove ${container} if it is there, keeping the volume ${volume}`)
    Console.log(`would run ${image} as ${container}, privileged, its store the volume ${volume}`)
    Console.log(`would publish its sshd on localhost:${port}, root reached by this computer's keys`)
  | Some("up") =>
    switch up() {
    | Ok(_) => Console.log(`builder: ${container} answers as ${store} on localhost:${port}`)
    | Error(why) => fail(`builder: ${why}`)
    }
  | Some("down") if dry =>
    Console.log(`would stop and remove ${container}, keeping the volume ${volume}`)
  | Some("down") =>
    removed(container)
      ? Console.log(`builder: ${container} removed, its store kept in ${volume}`)
      : fail(`builder: ${container} not removed`)
  | _ => fail("builder: say up or down, `builder up`")
  }
}
