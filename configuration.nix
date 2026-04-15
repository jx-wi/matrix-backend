{
  config,
  lib,
  pkgs,
  ...
}:
{
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = [ "wireguard" ];
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
  };
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      tailscale_auth_key = {
        sopsFile = ./secrets/matrix-backend/tailscale.yaml;
        key = "auth_key";
      };
      jaxxen_hashed_password = {
        sopsFile = ./secrets/matrix-backend/jaxxen/password.yaml;
        key = "hashed_password";
        neededForUsers = true;
      };
      garth_hashed_password = {
        sopsFile = ./secrets/matrix-backend/garth/password.yaml;
        key = "hashed_password";
        neededForUsers = true;
      };
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
      # allowedTCPPorts = [ 443 ];
    };
    useDHCP = false;
    useNetworkd = true;
  };
  systemd = {
    network = {
      enable = true;
      networks."10-lan" = {
        address = [ "192.168.1.101/24" ];
        matchConfig.Name = "e*";
        dns = [
          "192.168.1.1"
          "1.1.1.1"
          "1.0.0.1"
        ];
        gateway = [ "192.168.1.1" ];
      };
    };
    services.nh-os-switch = {
      description = "Run nh os switch github:jx-wi/matrix-backend";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.nh}/bin/nh os switch github:jx-wi/matrix-backend";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
    timers.nh-os-switch = {
      description = "Weekly nh os switch (Monday 9am)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Mon 09:00";
        Persistent = true;
      };
    };
  };
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
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
    sudo-rs = {
      enable = true;
      execWheelOnly = true;
      wheelNeedsPassword = true;
    };
    pam.services.su.rootOK = lib.mkForce false;
    protectKernelImage = true;
    lockKernelModules = true;
  };
  services = {
    fstrim.enable = true;
    qemuGuest.enable = true;
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
    fail2ban = {
      enable = true;
      bantime = "24h";
      maxretry = 5;
    };
    tailscale = {
      enable = true;
      useRoutingFeatures = "server";
      authKeyFile = config.sops.secrets.tailscale_auth_key.path;
      extraUpFlags = [
        "--ssh"
        "--advertise-tags=tag:matrix-backend"
      ];
    };
    prometheus.exporters.node = {
      enable = true;
      enabledCollectors = [
        "systemd"
        "cpu"
        "meminfo"
        "diskstats"
        "netdev"
        "filesystem"
        # "hwmon"
        # "thermal"
      ];
    };
  };
  system.stateVersion = "25.11";
  time.timeZone = "America/Chicago";
  users = {
    mutableUsers = false;
    motd = "Welcome to our matrix backend server.";
    groups = {
      matrix = {};
      jaxxen = {};
      garth = {};
    };
    users = {
      matrix = {
        isSystemUser = true;
        group = "matrix";
        home = "/var/lib/matrix";
        createHome = true;
      };
      jaxxen = {
        isNormalUser = true;
        group = "jaxxen";
        shell = pkgs.zsh;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGsK6bi38PTgEgIEkbWDwnfbuxlnqThC8EG1YY2JODr6 jaxxen@fleet" ];
        hashedPasswordFile = config.sops.secrets.jaxxen_hashed_password.path;
      };
      garth = {
        isNormalUser = true;
        group = "garth";
        shell = pkgs.zsh;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINyAiR+HClBoACzaQu4zpdS5bgosI2RGLctxuIh8HK/G garth@fleet" ];
        hashedPasswordFile = config.sops.secrets.garth_hashed_password.path;
      };
      root.hashedPassword = "!";
    };
  };
}
