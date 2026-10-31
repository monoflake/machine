# The swap's size in MiB by the memory installed, RFC vr5lw, 2 GiB up to 2, the memory up to 8 and
# half beyond, 8 to 16.
memory:
let
  half = memory / 2;
in
if memory <= 2048 then
  2048
else if memory <= 8192 then
  memory
else if half > 16384 then
  16384
else if half < 8192 then
  8192
else
  half
