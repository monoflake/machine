.derivations
| {
    paths: keys,
    names: [.[].name] | unique,
    patched: [
      .[]
      | .name as $package
      | ((.inputs.drvs // {} | keys[]), (.inputs.srcs // [])[])
      | select(test("CVE-[0-9]{4}-[0-9]+"))
      | {patch: ., package: $package}
    ] | unique
  }
