{ pkgs, ... }:
{
  packages = [
    pkgs.go2rtc
  ];

  enterShell = ''
    unset SDKROOT DEVELOPER_DIR NIX_CFLAGS_COMPILE NIX_LDFLAGS
    export DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
    echo "CamBar dev environment"
    command -v go2rtc >/dev/null && echo "go2rtc: $(command -v go2rtc)"
  '';
}
