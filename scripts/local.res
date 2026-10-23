/***
 * The local machine, `local/` as a NixOS container in Docker reached by ssh on localhost, started
 * or switched by `up` and stopped by `down`, RFC n0o4l and docs/local.md.
 */

@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external mkdirSync: string => unit = "mkdirSync"
@module("node:fs") external chmodSync: (string, int) => unit = "chmodSync"
@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"
@module("node:path") @variadic external join: array<string> => string = "join"
@val external isMain: bool = "import.meta.main"
@scope("JSON") @val
external stringify: {"system": string, "keys": array<string>} => string = "stringify"

let container = "machine-local"
let port = "2222"
/** The entry on this computer, and its own port inside, ENTRY on a keypad. */
let entry = "8080"
let entered = "36879"
/** The driver's management, its own port on this computer too, so a control here reaches it. */
let driver = "37483"
/** Each port published on this computer's loopback alone and its own inside, the entry twice, its
 * own port the one a control here reaches. */
let published = [(port, "22"), (entry, entered), (entered, entered), (driver, driver)]
/** The store, and what outlives the container, the disk, the driver's state and sshd's key. */
let nix = "machine-local-nix"
let state = "machine-local-state"
/** An image of an empty root owned by root, which the system's activation fills; its tag is
 * raised when what it holds changes. */
let empty = "machine-empty:1"
let local = {Builder.name: container, port, hostKey: "/var/lib/ssh/ssh_host_ed25519_key.pub"}

/** The system Nix calls this computer's Docker's, by the architecture it runs containers of. */
let system = () =>
  switch Builder.quiet("docker", ["version", "--format", "{{.Server.Arch}}"]) {
  | Some("arm64") => Ok("aarch64-linux")
  | Some("amd64") => Ok("x86_64-linux")
  | Some(other) => Error(`Docker runs ${other}, which no machine is`)
  | None => Error("Docker did not answer")
  }

/** What builds the local machine's system, `lib.local` of this checkout's copy with this
 * computer's keys. */
let arguments = system =>
  Builder.copied(Builder.root)->Option.mapOr(Error("this checkout not copied"), copy => {
    let given = join([copy, "local.json"])
    writeFileSync(given, stringify({"system": system, "keys": Builder.keys()}))
    Ok([
      "--impure",
      "--expr",
      `((builtins.getFlake "path:${copy}").lib.local (builtins.fromJSON (builtins.readFile ${given}))).config.system.build.toplevel`,
    ])
  })

let imported = () =>
  Builder.quiet("docker", ["image", "inspect", empty])->Option.isSome || {
      let root = mkdtempSync(join([tmpdir(), "empty-"]))
      chmodSync(root, 0o755)
      ["etc", "root", "var"]->Array.forEach(d => mkdirSync(join([root, d])))
      let archive = `${root}.tar`
      Builder.ran(
        "tar",
        ["-C", root, "--uid", "0", "--gid", "0", "--no-mac-metadata", "-cf", archive, "."],
      ) &&
      Builder.quiet("docker", ["import", archive, empty])->Option.isSome
    }

/** The system's closure copied from the builder's store into the local machine's, which no
 * container runs yet, by a container holding both volumes. */
let seeded = path =>
  Builder.ran(
    "docker",
    [
      "run",
      "--rm",
      "--volume",
      `${Builder.volume}:/nix`,
      "--volume",
      `${nix}:/local/nix`,
      Builder.image,
      "nix",
      "copy",
      "--no-check-sigs",
      "--to",
      "/local",
      path,
    ],
  )
    ? Ok(path)
    : Error(`${nix} not given the system`)

/** The container started on `path`, systemd its first process, and answering ssh. */
let booted = path =>
  if !Builder.removed(container) {
    Error(`${container} not removed`)
  } else if !imported() {
    Error(`${empty} not imported`)
  } else if (
    Builder.quiet(
      "docker",
      [
        "run",
        "--detach",
        "--name",
        container,
        "--hostname",
        "local",
        "--privileged",
        "--cgroupns",
        "private",
        "--restart",
        "unless-stopped",
        "--stop-signal",
        "SIGRTMIN+3",
        // A listen address, on this computer alone.
        ...published->Array.flatMap(((outside, inside)) => [
          "--publish",
          `127.0.0.1:${outside}:${inside}`,
        ]),
        "--tmpfs",
        "/run:exec,mode=755,size=256m",
        "--tmpfs",
        "/tmp:exec,mode=1777,size=1g",
        "--volume",
        `${nix}:/nix`,
        "--volume",
        `${state}:/var/lib`,
        empty,
        `${path}/init`,
      ],
    )->Option.isNone
  ) {
    Error(`${container} did not start`)
  } else {
    switch Builder.waited(60, () => Builder.configured([local])) {
    | None => Error(`${container} made no host key`)
    | Some(config) =>
      Builder.waited(30, () =>
        Builder.quiet(
          "ssh",
          ["-F", config, container, `nix-env -p /nix/var/nix/profiles/system --set ${path}`],
        )
      )->Option.mapOr(Error(`${container} did not answer ssh`), _ => Ok(path))
    }
  }

/** Whether it runs and publishes every port, so one started before a port was published is
 * started again rather than switched. */
let current = () =>
  Builder.running(container) &&
  published->Array.every(((outside, inside)) =>
    Builder.quiet("docker", ["port", container, `${inside}/tcp`])->Option.mapOr(false, ports =>
      ports->String.includes(`127.0.0.1:${outside}`)
    )
  )

let up = () =>
  system()
  ->Result.flatMap(system => arguments(system))
  ->Result.flatMap(arguments =>
    if current() {
      Builder.started([local])->Result.flatMap(config =>
        Builder.deployed(~config, ~target=container, arguments)
      )
    } else {
      Builder.started([])->Result.flatMap(config =>
        Builder.timed("build", () => Builder.built(~config, arguments), path => path)
        ->Result.flatMap(
          path =>
            Builder.timed(
              "copy",
              () => Builder.removed(container) ? seeded(path) : Error(`${container} not removed`),
              _ => `into ${nix}`,
            ),
        )
        ->Result.flatMap(
          path => Builder.timed("boot", () => booted(path), _ => `${container} answers ssh`),
        )
      )
    }
  )

if isMain {
  let dry = Builder.args->Array.includes("--dry-run")
  switch Builder.args->Array.find(a => !(a->String.startsWith("--"))) {
  | Some("up") if dry =>
    Console.log(`would start ${Builder.container} unless it runs, and build local/ in it`)
    Console.log(`would switch ${container} to it over ssh on localhost:${port} if it runs with`)
    Console.log(`  its entry published`)
    Console.log(`would otherwise remove ${container}, copy it into the volume ${nix} and start`)
    Console.log(`  ${container} on it, privileged, its state the volume ${state}, its sshd on`)
    Console.log(`  localhost:${port}, its entry on localhost:${entry} and localhost:${entered}`)
    Console.log(`  and its driver on localhost:${driver}`)
  | Some("up") =>
    switch up() {
    | Ok(_) =>
      Console.log(
        `local: ${container} runs it, \`ssh -p ${port} root@localhost\`, its entry on localhost:${entry} and localhost:${entered}, its driver on localhost:${driver}`,
      )
    | Error(why) => Builder.fail(`local: ${why}`)
    }
  | Some("down") if dry =>
    Console.log(`would stop and remove ${container}, keeping the volumes ${nix} and ${state}`)
  | Some("down") =>
    Builder.removed(container)
      ? Console.log(`local: ${container} removed, its store and state kept in ${nix} and ${state}`)
      : Builder.fail(`local: ${container} not removed`)
  | _ => Builder.fail("local: say up or down, `local up`")
  }
}
