# The seed's network-config rendered as one networkd .network file, docs/network.md.
{
  writeShellApplication,
  yq-go,
  jq,
}:
writeShellApplication {
  name = "machine-seed-render";
  runtimeInputs = [
    yq-go
    jq
  ];
  text = builtins.readFile ./render.sh;
}
