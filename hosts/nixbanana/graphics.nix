{ lib, ... }:

{
  hardware.graphics.enable = true;

  services.xserver.videoDrivers = lib.mkForce [ "modesetting"];

  # environment.variables = {
  #   MESA_LOADER_DRIVER_OVERRIDE = "nvk";
  #   NVK_I_WANT_A_BROKEN_VULKAN_DRIVER = "1";
  # };
}
