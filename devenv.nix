{ pkgs, ... }:
{
  packages = [
    pkgs.go2rtc
  ];

  enterShell = ''
    echo "CamBar dev environment"
    command -v go2rtc >/dev/null && echo "go2rtc: $(command -v go2rtc)"
  '';
}
