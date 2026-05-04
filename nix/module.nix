{
  lib,
  config,
  ...
}:
let
  cfg = config.services.my-service;
in
{
  options.services.my-service = {
    enable = lib.mkEnableOption "my-service";
  };

  config = lib.mkIf cfg.enable {
    # your configuration here
  };
}
