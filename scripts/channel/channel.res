type command = {program: string, args: array<string>, input: option<string>}
type world = {
  read: string => string,
  realpath: string => string,
  exists: string => bool,
  directories: string => array<string>,
  entries: string => array<string>,
  mkdir: string => unit,
  run: command => result<string, string>,
  say: string => unit,
  warn: string => unit,
  cwd: string,
  home: string,
  cache: option<string>,
  platform: string,
}

let profiles = "/nix/var/nix/profiles"
let profile = `${profiles}/default`
let installed = `${profiles}/per-user/root/profile`
let macCommand = "mise run //repos/monoflake/machine:channel mac"
let text = (json, key) =>
  json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))->Option.getOrThrow
let string = json => json->JSON.Decode.string->Option.getOrThrow
let call = (world, program, args, ~input=None) => world.run({program, args, input})
let required = result => result->Result.getOrThrow
let directory = (world, lock) => {
  let root = lock->Option.getOr(world.cwd)
  let machines = `${root}/machines`
  if world.exists(machines) {
    let first =
      world.directories(machines)
      ->Array.toSorted((a, b) => compare(a, b)->Int.toFloat)
      ->Array.get(0)
      ->Option.getOrThrow
    `${machines}/${first}`
  } else {
    root
  }
}

let hash = source => {
  let lock = JSON.parseOrThrow(source)
  let nodes = text(lock, "nodes")
  let root = text(lock, "root")->string
  let rec input = (node, name, depth) => {
    if depth > 32 {
      Error("cyclic lock input")->required
    } else {
      let value = text(text(text(nodes, node), "inputs"), name)
      switch JSON.Decode.string(value) {
      | Some(node) => node
      | None =>
        value
        ->JSON.Decode.array
        ->Option.getOrThrow
        ->Array.reduce(root, (node, part) => input(node, string(part), depth + 1))
      }
    }
  }
  let node = input(root, "nixpkgs", 0)
  let hash = text(text(text(nodes, node), "locked"), "narHash")->string
  if !(hash->String.startsWith("sha256-")) || hash->String.includes("..") {
    Error("invalid nixpkgs narHash")->required
  } else {
    hash
  }
}

let cached = (world, lock) => {
  let directory = directory(world, lock)
  let hash = hash(world.read(`${directory}/flake.lock`))
  let cache = world.cache->Option.getOr(`${world.home}/.cache`)
  (directory, `${cache}/channel-nix/${hash}`)
}

let resolve = (world, lock) => {
  try {
    let (directory, link) = cached(world, lock)
    if world.exists(link) {
      Ok(world.realpath(link))
    } else {
      world.mkdir(link->String.split("/")->Array.slice(~start=0, ~end=-1)->Array.join("/"))
      call(
        world,
        "nix",
        [
          "build",
          "--print-out-paths",
          "--out-link",
          link,
          "--inputs-from",
          `path:${directory}`,
          "nixpkgs#nix^out",
        ],
      )->Result.flatMap(output => {
        let path = output->String.trim
        path->String.startsWith("/nix/store/") && !(path->String.includes("\n"))
          ? Ok(path)
          : Error("nix build returned no single store path")
      })
    }
  } catch {
  | JsExn(error) => Error(JsExn.message(error)->Option.getOr("lock or cache could not be read"))
  | _ => Error("lock or cache could not be read")
  }
}

let version = path =>
  path
  ->String.split("/")
  ->Array.find(p => p->String.includes("-nix-"))
  ->Option.mapOr("unknown", p => p->String.split("-nix-")->Array.getUnsafe(1))
let compareMac = (world, channel) => {
  if world.platform == "darwin" {
    try {
      let daemon = world.realpath(`${profile}/bin/nix-daemon`)
      let expected = world.realpath(`${channel}/bin/nix-daemon`)
      if daemon != expected {
        let cache = world.cache->Option.getOr(`${world.home}/.cache`)
        let name = p => p->String.split("/")->Array.getUnsafe(3)
        let marker = `${cache}/channel-nix/warnings/${name(daemon)}/${name(expected)}`

        // mise evaluates its environment more than once for one task.
        if !world.exists(marker) {
          try world.mkdir(marker) catch {
          | _ => ()
          }
          world.warn(
            `the Mac's nix-daemon is ${version(daemon)}, the channel's is ${version(
                expected,
              )}: run ${macCommand}`,
          )
        }
      }
    } catch {
    | _ => world.warn("channel: the Mac's nix-daemon path could not be read")
    }
  }
}
let path = (world, lock) =>
  switch resolve(world, lock) {
  | Ok(channel) =>
    compareMac(world, channel)
    channel
  | Error(why) =>
    world.warn(`channel: ${why->String.split("\n")->Array.getUnsafe(0)}; using ${profile}`)
    profile
  }

let versions = (world, channel) => {
  world.say(call(world, `${channel}/bin/nix`, ["--version"])->required)
  let info = switch call(world, `${channel}/bin/nix`, ["store", "info", "--json"]) {
  | Ok(json) =>
    try `daemon: ${text(JSON.parseOrThrow(json), "version")->string}` catch {
    | _ => call(world, `${channel}/bin/nix`, ["store", "info"])->required
    }
  | Error(_) => call(world, `${channel}/bin/nix`, ["store", "info"])->required
  }
  world.say(info)
}
let rollback = [
  `sudo nix-env --profile ${profile} --rollback`,
  "sudo launchctl kickstart -k system/org.nixos.nix-daemon",
]
// The first switch starts the default chain anew, its one generation with nothing to roll back to.
let restore = [
  `sudo ln -sfn per-user/root/profile ${profile}`,
  "sudo launchctl kickstart -k system/org.nixos.nix-daemon",
]
let generations = world =>
  world.entries(profiles)
  ->Array.filter(name => /^default-\d+-link$/->RegExp.test(name))
  ->Array.length
let rollbackAfter = (world, count) => count <= 1 && world.exists(installed) ? restore : rollback
let help =
  [
    "channel path [--lock <flake directory>] | daemon | mac [--dry-run]",
    "The lock selects Nix. path falls back to the default profile on failure.",
    `On the Mac only ${macCommand} changes Nix and asks for sudo.`,
    "The Mac runs upstream Nix installed by NixOS/nix-installer, never Determinate Nix.",
    "Its version is root's default profile. Install by name keeps nss-cacert.",
    "Never use nix upgrade-nix, nix-env --set or rerun the installer.",
    "Keep systems.determinate.nix-installer.nix-hook as it is. It runs",
    "/nix/nix-installer repair at boot to restore the shell hook after macOS updates.",
    "Renaming it would desync /nix/receipt.json and the installer's uninstall.",
    "mac prints client and daemon versions before and after, then the rollback commands.",
    "--dry-run prints the commands and runs none.",
    "Rollback with these commands",
    ...rollback,
    "After the first switch, whose chain holds one generation, restore the installer's profile",
    ...restore,
  ]->Array.join("\n")

let execute = (world, args) => {
  let lockIndex = args->Array.findIndex(a => a == "--lock")
  let lock =
    lockIndex >= 0
      ? Some(args->Array.get(lockIndex + 1)->Option.getOr("/missing-lock-argument"))
      : None
  let dry = args->Array.includes("--dry-run")
  if args->Array.includes("--help") || args->Array.includes("-h") {
    world.say(help)
  } else {
    switch args->Array.get(0) {
    | Some("path") => world.say(path(world, lock))
    | Some("mac") | Some("daemon") =>
      let mac = args->Array.get(0) == Some("mac")
      if !dry && world.platform != (mac ? "darwin" : "linux") {
        Error("channel: this action is for another OS")->required
      }
      let channel = if dry {
        // A dry run reads the root but never builds a missing package.
        let (directory, link) = cached(world, lock)
        if world.exists(link) {
          world.realpath(link)
        } else {
          world.say(
            `nix build --print-out-paths --out-link '${link}' --inputs-from 'path:${directory}' 'nixpkgs#nix^out'`,
          )
          link
        }
      } else {
        resolve(world, lock)->required
      }
      let sudo = (args, ~input=None) => {
        if dry {
          world.say(`sudo ${args->Array.join(" ")}`)
        } else {
          call(world, "sudo", args, ~input)->required->ignore
        }
      }
      if mac {
        if !dry {
          world.say("before")
          versions(world, channel)
        }
        sudo(["nix-env", "--profile", profile, "--install", channel])
        sudo(["launchctl", "kickstart", "-k", "system/org.nixos.nix-daemon"])
        if !dry {
          world.say("after")
          versions(world, channel)
        }
        world.say("rollback")
        // nix-env adds no generation when the profile already holds the channel's Nix.
        let adds =
          dry && try world.realpath(`${profile}/bin/nix-daemon`) !=
            world.realpath(`${channel}/bin/nix-daemon`) catch {
          | _ => true
          }
        rollbackAfter(world, generations(world) + (adds ? 1 : 0))->Array.forEach(world.say)
      } else {
        if !dry {
          world.say(call(world, "systemctl", ["cat", "nix-daemon.service"])->required)
        }
        sudo(["mkdir", "-p", "/etc/systemd/system/nix-daemon.service.d"])
        sudo(
          ["tee", "/etc/systemd/system/nix-daemon.service.d/channel.conf"],
          ~input=Some(`[Service]\nExecStart=\nExecStart=${channel}/bin/nix-daemon --daemon\n`),
        )
        sudo(["systemctl", "daemon-reload"])
        sudo(["systemctl", "restart", "nix-daemon.service"])
        if !dry {
          versions(world, channel)
        }
      }
    | _ => world.say(help)
    }
  }
}

@module("node:fs") external read: (string, @as("utf8") _) => string = "readFileSync"
@module("node:fs") external realpath: string => string = "realpathSync"
@module("node:fs") external exists: string => bool = "existsSync"
@module("node:fs") external readdir: string => array<string> = "readdirSync"
@module("node:fs") external stat: string => {"isDirectory": unit => bool} = "statSync"
@module("node:fs") external mkdir: (string, {"recursive": bool}) => unit = "mkdirSync"
@module("node:os") external home: unit => string = "homedir"
@val external cwd: unit => string = "process.cwd"
@val external platform: string = "process.platform"
@val external env: Dict.t<string> = "process.env"
@val external argv: array<string> = "process.argv"
@val external isMain: bool = "import.meta.main"
type process
@val external process: process = "process"
@set external setExitCode: (process, int) => unit = "exitCode"
type output = {status: Nullable.t<int>, stdout: Nullable.t<string>, stderr: Nullable.t<string>}
type spawnOptions = {encoding: string, input: option<string>}
@module("node:child_process")
external spawn: (string, array<string>, spawnOptions) => output = "spawnSync"
let live: world = {
  read,
  realpath,
  exists,
  directories: path =>
    readdir(path)->Array.filter(name => stat(`${path}/${name}`)["isDirectory"]()),
  entries: path => exists(path) ? readdir(path) : [],
  mkdir: path => mkdir(path, {"recursive": true}),
  run: c => {
    let output = spawn(c.program, c.args, {encoding: "utf8", input: c.input})
    output.status->Nullable.toOption == Some(0)
      ? Ok(output.stdout->Nullable.toOption->Option.getOr("")->String.trim)
      : Error(
          `${c.program} failed ${output.stderr
            ->Nullable.toOption
            ->Option.getOr("unavailable")
            ->String.trim}`,
        )
  },
  say: Console.log,
  warn: Console.error,
  cwd: cwd(),
  home: home(),
  cache: env->Dict.get("XDG_CACHE_HOME"),
  platform,
}
if isMain {
  try execute(live, argv->Array.slice(~start=2)) catch {
  | JsExn(error) =>
    Console.error(JsExn.message(error)->Option.getOr("channel failed"))
    setExitCode(process, 1)
  | _ =>
    Console.error("channel failed")
    setExitCode(process, 1)
  }
}
