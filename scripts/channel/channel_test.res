@module("node:test") external test: (string, unit => unit) => unit = "test"
@module("node:assert/strict") external equal: ('a, 'a) => unit = "deepStrictEqual"
@module("node:assert/strict") external ok: bool => unit = "ok"

let store = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nix-2.34.9"
let lock = `{"root":"root","nodes":{"root":{"inputs":{"nixpkgs":"pkgs"}},"pkgs":{"locked":{"narHash":"sha256-abc/def="}}}}`
let make = (~hit=true, ~platform="linux", ~same=true, ~failure=false, ()) => {
  let ran = []
  let said = []
  let warned = []
  let made = []
  let world: Channel.world = {
    read: _ => lock,
    realpath: p =>
      p->String.endsWith("/bin/nix-daemon")
        ? `${p->String.startsWith(Channel.profile) && !same
              ? "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nix-2.35.3"
              : store}/bin/nix-daemon`
        : store,
    exists: p =>
      p->String.includes("/warnings/")
        ? made->Array.includes(p)
        : p->String.startsWith("/cache/") && hit,
    directories: _ => ["z", "a"],
    mkdir: p => made->Array.push(p),
    run: c => {
      ran->Array.push(c)
      if failure {
        Error("nix unavailable\nsecond line")
      } else if c.args->Array.includes("--json") {
        Ok(`{"version":"2.34.9"}`)
      } else if c.args->Array.includes("--version") {
        Ok("nix (Nix) 2.34.9")
      } else {
        Ok(store)
      }
    },
    say: s => said->Array.push(s),
    warn: s => warned->Array.push(s),
    cwd: "/repo",
    home: "/home",
    cache: Some("/cache"),
    platform,
  }
  (world, ran, said, warned, made)
}

test("a cache hit invokes no Nix", () => {
  let (world, ran, said, warned, made) = make()
  Channel.execute(world, ["path"])
  equal(said, [store])
  equal(ran, [])
  equal(warned, [])
  equal(made, [])
})

test("a cache miss roots the lock's exact nixpkgs output", () => {
  let (world, ran, _, _, made) = make(~hit=false, ())
  equal(Channel.path(world, None), store)
  equal(made, ["/cache/channel-nix/sha256-abc"])
  equal(
    (ran->Array.getUnsafe(0)).args,
    [
      "build",
      "--print-out-paths",
      "--out-link",
      "/cache/channel-nix/sha256-abc/def=",
      "--inputs-from",
      "path:/repo",
      "nixpkgs#nix^out",
    ],
  )
})

test("failures return the profile with exactly one warning", () => {
  let (world, _, said, warned, _) = make(~hit=false, ~failure=true, ())
  Channel.execute(world, ["path"])
  equal(said, [Channel.profile])
  equal(warned->Array.length, 1)
  ok(!(warned->Array.getUnsafe(0)->String.includes("\n")))
  let broken = {...world, read: _ => "invalid JSON"}
  equal(Channel.path(broken, None), Channel.profile)
  equal(warned->Array.length, 2)
})

test("the Mac warning speaks only on a daemon difference", () => {
  [true, false]->Array.forEach(same => {
    let (world, ran, _, warned, _) = make(~platform="darwin", ~same, ())
    Channel.execute(world, ["path"])
    equal(ran, [])
    Channel.execute(world, ["path"])
    equal(warned->Array.length, same ? 0 : 1)
    if !same {
      equal(
        warned->Array.getUnsafe(0),
        `the Mac's nix-daemon is 2.35.3, the channel's is 2.34.9: run ${Channel.macCommand}`,
      )
    }
  })
})

test("daemon reads the installed unit and clears ExecStart through sudo", () => {
  let (world, ran, said, _, _) = make()
  Channel.execute(world, ["daemon"])
  equal((ran->Array.getUnsafe(0)).program, "systemctl")
  equal((ran->Array.getUnsafe(0)).args, ["cat", "nix-daemon.service"])
  let privileged = ran->Array.filter(c => c.program == "sudo")
  equal(
    privileged->Array.map(c => c.args),
    [
      ["mkdir", "-p", "/etc/systemd/system/nix-daemon.service.d"],
      ["tee", "/etc/systemd/system/nix-daemon.service.d/channel.conf"],
      ["systemctl", "daemon-reload"],
      ["systemctl", "restart", "nix-daemon.service"],
    ],
  )
  equal(
    (privileged->Array.getUnsafe(1)).input,
    Some(`[Service]\nExecStart=\nExecStart=${store}/bin/nix-daemon --daemon\n`),
  )
  ok(said->Array.includes("daemon: 2.34.9"))
})

test("mac installs by name and reports versions before and after", () => {
  let (world, ran, said, _, _) = make(~platform="darwin", ())
  Channel.execute(world, ["mac"])
  let privileged = ran->Array.filter(c => c.program == "sudo")
  equal(
    privileged->Array.map(c => c.args),
    [
      ["nix-env", "--profile", Channel.profile, "--install", store],
      ["launchctl", "kickstart", "-k", "system/org.nixos.nix-daemon"],
    ],
  )
  ok(ran->Array.every(c => !(c.args->Array.includes("--set"))))
  equal(said->Array.filter(s => s == "daemon: 2.34.9")->Array.length, 2)
  ok(said->Array.includes("before"))
  ok(said->Array.includes("after"))
  Channel.rollback->Array.forEach(line => ok(said->Array.includes(line)))
})

test("mac dry run runs nothing even without a cached package", () => {
  [true, false]->Array.forEach(hit => {
    let (world, ran, said, _, made) = make(~platform="darwin", ~hit, ())
    Channel.execute(world, ["mac", "--dry-run"])
    equal(ran, [])
    equal(made, [])
    let target = hit ? store : "/cache/channel-nix/sha256-abc/def="
    ok(said->Array.includes(`sudo nix-env --profile ${Channel.profile} --install ${target}`))
    ok(said->Array.includes("sudo launchctl kickstart -k system/org.nixos.nix-daemon"))
  })
})

test("cloud picks its first machine and follows nixpkgs references", () => {
  let (world, _, _, _, _) = make()
  equal(Channel.directory({...world, exists: _ => true}, Some("/cloud")), "/cloud/machines/a")
  equal(
    Channel.hash(`{"root":"r","nodes":{"r":{"inputs":{"nixpkgs":["machine","nixpkgs"],"machine":"m"}},"m":{"inputs":{"nixpkgs":"p"}},"p":{"locked":{"narHash":"sha256-test="}}}}`),
    "sha256-test=",
  )
})

test("mac help runs nothing", () => {
  let (world, ran, said, _, made) = make(~platform="darwin", ())
  Channel.execute(world, ["mac", "--help"])
  equal(ran, [])
  equal(made, [])
  equal(said, [Channel.help])
})
