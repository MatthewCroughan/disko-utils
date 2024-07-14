{
  inputs.disko.url = "github:nix-community/disko";
  outputs = { disko, ... }: {
    /*  Creates a shell script that will:

        1. Make and partition ZFS on a given block device
        2. nixos-install a given nixosConfiguration to it
        3. `umount` and `zpool export` the pool.

        This function will also attempt to clean the nixosConfiguration by
        removing machine-specific details such as filesystems,
        networking.interfaces.

        This function does not require the given nixosConfiguration to have a
        disko configuration, as it will force an opinionated one in. This is
        only intended for one-time stateless setups where you do not intend to
        run a nixos-rebuild switch on the machine that results from this
        function.

        Type: mkOpinionatedZfsNuke :: nixosConfiguration -> str -> derivation

        Example:
          mkOpinionatedZfsNuke self.nixosConfigurations.myMachine "/dev/sda"
          => derivation
    */

    mkOpinionatedZfsNuke = nixosConfiguration: device:
      let
        pkgs = nixosConfiguration.pkgs;
        cleanedConfiguration = nixosConfiguration.extendModules {
          modules = [
            {
              fileSystems = pkgs.lib.mkOverride 50 {};
              networking.interfaces = pkgs.lib.mkOverride 50 {};
              boot.initrd.luks.devices = pkgs.lib.mkOverride 50 {};
            }
          ];
        };
        extendedConfiguration = cleanedConfiguration.extendModules {
          modules = [
            disko.nixosModules.default
            ./mkZfsNuke/disko.nix
          ];
          specialArgs = {
            inherit device;
          };
        };
        finalConfiguration = extendedConfiguration.extendModules {
          modules = [
            ({ config, ... }: pkgs.lib.mkForce (pkgs.lib.mkMerge (disko.lib.lib.config extendedConfiguration.config.disko.devices)))
          ];
        };
      in
      (pkgs.writeShellScriptBin "diskoScript" ''
        ${finalConfiguration.config.system.build.diskoScript}
        nixos-install --no-root-password --option substituters "" --no-channel-copy --system ${finalConfiguration.config.system.build.toplevel}
        umount -R '${finalConfiguration.config.disko.rootMountPoint}'
        zpool export '${toString (builtins.attrNames finalConfiguration.config.disko.devices.zpool)}'
      '');

    /*  Creates a shell script that will:

        1. Make and partition ZFS on a given block device
        2. nixos-install a given nixosConfiguration to it
        3. `umount` and `zpool export` the pool.

        This function requires that a disko configuration with a zpool is
        already present inside of the given nixosConfiguration.

        Type: mkZfsNuke :: nixosConfiguration -> str -> derivation

        Example:
          mkZfsNuke self.nixosConfigurations.myMachine "/dev/sda"
          => derivation
    */

    mkZfsNuke = nixosConfiguration: device:
      let
        pkgs = nixosConfiguration.pkgs;
      in
      (pkgs.writeShellScriptBin "install-${nixosConfiguration.config.system.name}-to-${device}" ''
        ${nixosConfiguration.config.system.build.diskoScript}
        nixos-install --no-root-password --option substituters "" --no-channel-copy --system ${nixosConfiguration.config.system.build.toplevel}
        umount -R '${nixosConfiguration.config.disko.rootMountPoint}'
        zpool export '${toString (builtins.attrNames nixosConfiguration.config.disko.devices.zpool)}'
      '');

    /*  Creates a NixOS installer iso that contains the toplevel from the given
        nixosConfiguration in the closure. This installer will then runs the
        diskoScript from a given nixosConfiguration on boot, install the
        toplevel via nixos-install and reboot

        This function requires that a disko configuration is already present
        inside of the given nixosConfiguration.

        Type: mkAutoInstaller :: nixosConfiguration -> derivation

        Example:
          mkAutoInstaller self.nixosConfigurations.myMachine
          => derivation
    */

    mkAutoInstaller = { nixosConfiguration, flakeToInstall ? null, extraModules ? [] }:
      let
        pkgs = nixosConfiguration.pkgs;
        nixosSystem = import "${pkgs.path}/nixos/lib/eval-config.nix";
      in
      (nixosSystem {
        system = pkgs.system;
        modules = extraModules ++ [
          "${pkgs.path}/nixos/modules/installer/cd-dvd/installation-cd-base.nix"
          {
            boot.kernelPackages = pkgs.linuxPackages_latest;
            isoImage.forceTextMode = true;
            isoImage.squashfsCompression = "zstd -Xcompression-level 1";
            services.getty.autologinUser = pkgs.lib.mkForce "root";
            environment.systemPackages = [
              (pkgs.writeShellScriptBin "diskoScript" ''
                ${nixosConfiguration.config.system.build.diskoScript}
                nixos-install --no-root-password --option substituters "" --no-channel-copy --system ${nixosConfiguration.config.system.build.toplevel}
                ${if (flakeToInstall != null) then "cp --no-preserve=mode -rT ${flakeToInstall} /mnt/etc/nixos" else ""}
                reboot
              '')
            ];
            programs.bash.interactiveShellInit = ''
              if [ "$(tty)" = "/dev/tty1" ]; then
                diskoScript
              fi
            '';
          }
        ];
      }).config.system.build.isoImage;
  };
}
