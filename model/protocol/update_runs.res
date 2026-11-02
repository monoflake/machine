/**
 * The update's runs out of TLC's output, `node update_runs.res.mjs <output>`: each run that ended
 * on its own once, in a stable order, which the update crate's replay test reads, RFC w0w82.
 */
@module("node:fs") external readText: (string, string) => string = "readFileSync"
@val external argv: array<string> = "process.argv"

/** The value after a name in a row TLC printed, up to the next space or quote. */
let field = (line, name) =>
  switch RegExp.fromString(`${name}=([a-z0-9,]*)`)->RegExp.exec(line) {
  | Some(found) =>
    found->RegExp.Result.matches->Array.get(0)->Option.flatMap(x => x)->Option.getOr("")
  | None => ""
  }

let flag = (line, name) => field(line, name) == "1" ? "true" : "false"

/** A run row as TLC printed it, held as one case of the fixture with the steps it took. */
let runOf = line => {
  let steps = switch field(line, "steps") {
  | "" => []
  | text => text->String.split(",")->Array.map(step => `"${step}"`)
  }
  `{"case":{"pointer":"${field(line, "pointer")}","running":${flag(line, "running")},"taken":${flag(
      line,
      "taken",
    )},"realise":"${field(line, "realise")}","switch":"${field(line, "switch")}","freeze":"${field(
      line,
      "freeze",
    )}","sync":"${field(line, "sync")}"},"steps":[${steps->Array.join(",")}]}`
}

let fixtureOf = out => {
  let rows =
    out
    ->String.split("\n")
    ->Array.filter(line => line->String.includes("run pointer="))
    ->Array.map(runOf)
  let runs = Set.fromArray(rows)->Set.values->Array.fromIterator->Array.toSorted(String.compare)
  `{\n"runs":[\n${runs->Array.join(",\n")}\n]\n}`
}

Console.log(fixtureOf(readText(argv->Array.getUnsafe(2), "utf8")))
