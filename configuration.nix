{
  config,
  lib,
  pkgs,
  ...
}:
{
  boot = {
    kernelPackages = pkgs.linuxPackages_hardened;
    lanzaboote = {
      enable = true;
      configurationLimit = 16;
      pkiBundle = "/var/lib/sbctl";
    };
    loader.efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot";
    };
    tmp.cleanOnBoot = true;
  };
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 75;
    priority = 100;
  };
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      ssh_host_ed25519_key = {
        path = "/etc/ssh/ssh_host_ed25519_key";
        owner = "root";
        mode = "0600";
      };
      jaxxen_hashed_password.neededForUsers = true;
      garth_hashed_password.neededForUsers = true;
    };
  };
  console.keyMap = "us";
  environment = {
    binsh = "${pkgs.dash}/bin/dash";
    systemPackages = with pkgs; [
      sbctl
      sops
      age
      ssh-to-age
    ];
  };
  networking = {
    hostName = "matrix-backend";
    firewall = {
      enable = true;
      trustedInterfaces = [ "tailscale0" ];
      allowedUDPPorts = [ config.services.tailscale.port ];
    };
    # useDHCP = false;
    # useNetworkd = true;
    networkmanager.enable = true;
  };
  /*
  systemd.network = {
    enable = true;
    networks."10-lan" = {
      address = [ "192.168.0.101/24" ];
      matchConfig.Name = "e*";
      dns = [
        "192.168.0.1"
        "1.1.1.1"
        "1.0.0.1"
      ];
      gateway = [ "192.168.0.1" ];
    };
  };
  */
  nix.settings = {
    sandbox = false;
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };
  programs = {
    zsh.enable = true;
    nh = {
      enable = true;
      clean = {
        dates = "weekly";
        extraArgs = "--keep 16";
      };
    };
  };
  swapDevices = [{
    device = "/.swapfile";
    size = 8192;
    randomEncryption.enable = true;
  }];
  security = {
    pam.services.su.rootOK = lib.mkForce false;
    allowUserNamespaces = false;
    sudo-rs = {
      enable = true;
      execWheelOnly = true;
      wheelNeedsPassword = true;
    };
  };
  services = {
    fstrim.enable = true;
    openssh = {
      enable = true;
      hostKeys = [{
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }];
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
      };
    };
    fail2ban.enable = true;
    tailscale = {
      enable = true;
      useRoutingFeatures = "server";
      extraUpFlags = [ "--ssh" ];
    };
  };
  system.stateVersion = "25.11";
  time.timeZone = "America/Chicago";
  users = {
    mutableUsers = false;
    motd = "welcome to our matrix backend server";
    users = {
      jaxxen = {
        isNormalUser = true;
        shell = pkgs.zsh;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGsK6bi38PTgEgIEkbWDwnfbuxlnqThC8EG1YY2JODr6 jaxxen@fleet" ];
        hashedPasswordFile = config.sops.secrets.jaxxen_hashed_password.path;
      };
      garth = {
        isNormalUser = true;
        shell = pkgs.zsh;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINyAiR+HClBoACzaQu4zpdS5bgosI2RGLctxuIh8HK/G garth@fleet" ];
        hashedPasswordFile = config.sops.secrets.garth_hashed_password.path;
      };
      root.hashedPassword = "!";
    };
  };
}
