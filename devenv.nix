{ pkgs, ... }:
let
  camsnap = pkgs.callPackage ./nix/pkgs/camsnap.nix {};
in
{
  packages = [
    camsnap
    pkgs.ffmpeg
  ];

  enterShell = ''
    echo "CamBar dev environment"
    command -v camsnap >/dev/null && echo "camsnap: $(command -v camsnap)"
    command -v ffmpeg >/dev/null && echo "ffmpeg: $(command -v ffmpeg)"
  '';
}
