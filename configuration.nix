{
  config,
  lib,
  pkgs,
  ...
}: let
  homeserver = "ironmere.duckdns.org";
  dnsProvider = "duckdns";
  dnsTokenEnvVar = "DUCKDNS_TOKEN_FILE";
in {
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
      dns_token = {
        sopsFile = ./secrets/matrix-backend/dns.yaml;
        key = "token";
        owner = "acme";
        mode = "0400";
      };
      livekit_secret = {
        sopsFile = ./secrets/matrix-backend/livekit.yaml;
        key = "secret";
        owner = "livekit";
        group = "livekit";
        mode = "0400";
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
      matrix_registration_token = {
        sopsFile = ./secrets/matrix-backend/registration-token.yaml;
        key = "token";
        owner = "tuwunel";
        mode = "0400";
      };
    };
    templates."livekit.key" = {
      content = "lk-jwt-service: ${config.sops.placeholder.livekit_secret}";
      owner = "livekit";
      group = "livekit";
      mode = "0440";
    };
  };
  console.keyMap = "us";
  environment = {
    binsh = "${pkgs.dash}/bin/dash";
    enableAllTerminfo = true;
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
      allowedUDPPorts = [
        config.services.tailscale.port
        443
      ];
      allowedUDPPortRanges = [{
        from = 50000;
        to = 60000;
      }];
      allowedTCPPorts = [
        80 # HTTP → HTTPS redirect
        443
        7881
      ];
    };
    useDHCP = false;
    useNetworkd = true;
  };
  systemd = {
    network = {
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
    services = {
      lk-jwt-service.environment.LIVEKIT_FULL_ACCESS_HOMESERVERS = "${homeserver}";
      nh-os-switch = {
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
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
    allowed-users = [ "@wheel" ];
    trusted-users = [
      "root"
      "@wheel"
    ];
  };
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.tcp_syncookies" = 1;
    "kernel.dmesg_restrict" = 1;
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
    sudo-rs = {
      enable = true;
      execWheelOnly = true;
      wheelNeedsPassword = true;
    };
    pam.services.su.rootOK = lib.mkForce false;
    protectKernelImage = true;
    lockKernelModules = true;
    acme = {
      acceptTerms = true;
      defaults.email = "jxwi@proton.me";
      certs."${homeserver}" = {
        inherit dnsProvider;
        webroot = null;
        credentialFiles."${dnsTokenEnvVar}" = config.sops.secrets.dns_token.path;
        group = "caddy";
        reloadServices = [ "caddy" ];
      };
    };
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
        KbdInteractiveAuthentication = false;
        X11Forwarding = false;
        MaxAuthTries = 3;
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
    caddy = {
      enable = true;
      virtualHosts."${homeserver}" = {
        useACMEHost = "${homeserver}";
        extraConfig = ''
          header {
            Strict-Transport-Security "max-age=31536000; includeSubDomains"
            X-Frame-Options SAMEORIGIN
            X-Content-Type-Options nosniff
            Referrer-Policy strict-origin-when-cross-origin
            -Server ""
          }
          handle /.well-known/matrix/server {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            respond `{"m.server":"${homeserver}:443"}` 200
          }
          handle /.well-known/matrix/client {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
            respond `{"m.homeserver":{"base_url":"https://${homeserver}"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://${homeserver}/livekit/jwt"}]}` 200
          }
          handle_path /livekit/jwt/* {
            reverse_proxy http://127.0.0.1:8080
          }
          handle_path /livekit/sfu/* {
            reverse_proxy http://127.0.0.1:7880
          }
          handle {
            encode zstd gzip
            reverse_proxy http://127.0.0.1:6167
          }
        '';
      };
    };
    matrix-tuwunel = {
      enable = true;
      settings.global = {
        server_name = "${homeserver}";
        port = [ 6167 ];
        address = [ "127.0.0.1" ];
        allow_federation = false;
        allow_registration = false;
        registration_token_file = config.sops.secrets.matrix_registration_token.path;
        default_room_version = "11";
        rtc_transports = [{
          type = "livekit";
          livekit_service_url = "https://${homeserver}/livekit/jwt";
        }];
      };
    };
    livekit = {
      enable = true;
      keyFile = config.sops.templates."livekit.key".path;
      settings = {
        room.auto_create = false;
        rtc = {
          tcp_port = 7881;
          port_range_start = 50000;
          port_range_end = 60000;
          use_external_ip = true;
        };
      };
    };
    lk-jwt-service = {
      enable = true;
      keyFile = config.sops.templates."livekit.key".path;
      livekitUrl = "wss://${homeserver}/livekit/sfu/";
    };
    prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      enabledCollectors = [
        "systemd"
        "cpu"
        "meminfo"
        "diskstats"
        "netdev"
        "filesystem"
      ];
    };
  };
  system.stateVersion = "25.11";
  time.timeZone = "America/Chicago";
  users = {
    mutableUsers = false;
    motd = "Welcome to our matrix backend server.";
    groups = {
      livekit = {};
      lk-jwt-service = {};
      jaxxen = {};
      garth = {};
    };
    users = {
      livekit = {
        isSystemUser = true;
        group = "livekit";
      };
      lk-jwt-service = {
        isSystemUser = true;
        group = "lk-jwt-service";
        extraGroups = [ "livekit" ];
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
