{ pkgs, ... }:

{
  virtualisation.libvirtd = {
    enable = true;
    onBoot = "ignore";
    onShutdown = "shutdown";
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
    };
  };

  # Expose OVMF at stable paths so terranix opnsense config can reference them
  # without embedding /nix/store hashes.
  environment.etc = {
    "ovmf/OVMF_CODE.fd".source = "${pkgs.OVMFFull.fd}/FV/OVMF_CODE.fd";
    "ovmf/OVMF_VARS.fd".source = "${pkgs.OVMFFull.fd}/FV/OVMF_VARS.fd";
  };

  environment.systemPackages = with pkgs; [ virt-manager virtiofsd ];
}
