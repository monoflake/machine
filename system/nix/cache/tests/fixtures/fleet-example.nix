let
  keys = {
    pointer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample";
    nix = "example.com:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    access = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample";
  };
  machine = system: memory: {
    inherit system memory;
    planned = false;
    at = "16:00";
  };
  x = memory: machine "x86_64-linux" memory;
  a = memory: machine "aarch64-linux" memory;
in
{
  flake = "https://example.com/machines";
  defaults = {
    x86_64-linux = {
      a1 = 1;
      a2 = 2;
      a3 = 3;
    };
    aarch64-linux = {
      b1 = 1;
      b2 = 1;
      b3 = 1;
      b4 = 2;
    };
  };
  machines = {
    a1 = x 4096 // {
      at = "02:00";
      inherit keys;
    };
    a2 = x 1900 // {
      at = "04:00";
      inherit keys;
    };
    a3 = x 8192 // {
      inherit keys;
    };
    b1 = a 8192 // {
      inherit keys;
    };
    b2 = a 8192 // {
      inherit keys;
    };
    b3 = a 8192 // {
      inherit keys;
    };
    b4 = a 8192 // {
      inherit keys;
    };
    c1 = x 512 // {
      at = "08:00";
    };
    c2 = x 768 // {
      at = "10:00";
    };
    c3 = x 1024 // {
      at = "12:00";
    };
    c4 = a 512 // {
      at = "06:00";
    };
    c5 = a 768 // {
      at = "10:00";
    };
    c6 = a 1024 // {
      at = "14:00";
    };
    b5 = a 8192 // {
      inherit keys;
      planned = true;
    };
  };
}
