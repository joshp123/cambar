{ ... }:
{
  enterShell = ''
    unset SDKROOT DEVELOPER_DIR NIX_CFLAGS_COMPILE NIX_LDFLAGS
    export DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
    echo "CamBar dev environment"
  '';
}
