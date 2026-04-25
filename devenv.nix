{ pkgs, ... }:
let
  camsnap = pkgs.callPackage ./nix/pkgs/camsnap.nix {};
in
{
  packages = [
    camsnap
    pkgs.ffmpeg
    pkgs.go2rtc
  ];

  enterShell = ''
    echo "CamBar dev environment"
    command -v camsnap >/dev/null && echo "camsnap: $(command -v camsnap)"
    command -v ffmpeg >/dev/null && echo "ffmpeg: $(command -v ffmpeg)"
    command -v go2rtc >/dev/null && echo "go2rtc: $(command -v go2rtc)"
  '';
}
