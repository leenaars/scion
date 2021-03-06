{ config, pkgs, lib, ... }:

with lib;
let
  cfg = config.services.scionlab;
in
{
  options.services.scionlab = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether or not to connect to the experimental global deployment of SCION, SCIONLab
      '';
    };

    openvpnConfig = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to the OpenVPN config for the AS to connect to
      '';
    };

    configDirectory = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to the configuration directory needed for SCION, i.e. gen/
      '';
    };

    configTarball = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to the configuration tarball downloaded from SCIONLab
      '';
    };

    identifier = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "16-ffaa_0_1002";
      description = ''
        ISD and AS identifier?
      '';
    };
  };

  config = mkMerge [
    (mkIf (cfg.configTarball != null) {
      assertions = [
        {
          assertion = cfg.configTarball != null -> cfg.openvpnConfig != null && cfg.configDirectory != null;
          message = "Manual openvpnConfig and/or configDirectory conflicts with generated.";
        }
      ];

      services.scionlab =
        let
          extractedTarball =
            pkgs.runCommand "extracted-scionlab-config"
              {
                src = cfg.configTarball;
                nativeBuildInputs = [ pkgs.gnutar pkgs.jq pkgs.coreutils ];
              } ''
              tar xvf $src

              mkdir -p $out
              cp client-scionlab-*.conf $out/client-scionlab.conf
              cp -r gen $out

              for file in $(grep -rl gen/ $out); do
                sed -i 's@gen/@/etc/scion/gen/@g' $file
              done

              cat gen/scionlab-config.json | jq '.host_id = $id | .host_secret = $secret' \
                --arg id "$(od -A n -t x8 -N 16 /dev/random | tr -d ' \n')" \
                --arg secret "$(od -A n -t x8 -N 16 /dev/random | tr -d ' \n')" > gen/scionlab-config.json
            '';
        in
        {
          openvpnConfig = extractedTarball + "/client-scionlab.conf";
          configDirectory = extractedTarball + "/gen";
        };
    }
    )

    (mkIf (cfg.enable && cfg.openvpnConfig != null) {
      services.openvpn.servers.scionlab.config = (builtins.readFile cfg.openvpnConfig)
        + ''
        # Manage DNS configuration on a per-link basis for systemd-resolved
        script-security 2
        up ${pkgs.update-systemd-resolved}/libexec/openvpn/update-systemd-resolved
        up-restart
        down ${pkgs.update-systemd-resolved}/libexec/openvpn/update-systemd-resolved
        down-pre

        # Send all DNS traffic through the VPN tunnel and prevent DNS leaks
        dhcp-option DOMAIN-ROUTE .
      ''
      ;
    }
    )

    (mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.enable -> cfg.identifier != null;
          message = "ISD AS identifier is invalid.";
        }
        {
          assertion = cfg.enable -> cfg.configDirectory != null;
          message = "SCION configuration is invalid.";
        }
      ];

      environment.etc."scion/gen".source = cfg.configDirectory;
      environment.systemPackages = with pkgs; [ scion ];

      systemd.targets.scionlab = {
        # Since this is the "manual" approach, we have to ensure the openvpn is started before scionlab
        after = [ "openvpn-scionlab.service" ];
        requires = [ "openvpn-scionlab.service" ];
        wants = [ "scion-dispatcher.service" ] ++ map (service: "${service}${cfg.identifier}.service") [ "scion-border-router@" "scion-control-service@" "scion-daemon@" ];
        wantedBy = [ "multi-user.target" ];
        description = "SCIONLab Service";
      };

      systemd.tmpfiles.rules = [
        "d /run/shm                 0750 scion scion -"
        "d /run/shm/dispatcher      0750 scion scion -"
        "d /run/shm/sciond          0750 scion scion -"
        "d /var/lib/scion           0750 scion scion -"
        "d /var/lib/scion/logs      0750 scion scion -"
        "d /var/lib/scion/traces    0750 scion scion -"
        "d /var/lib/scion/gen       0750 scion scion -"
        "d /var/lib/scion/gen-cache 0750 scion scion -"
        "d /var/lib/scion/gen-certs 0750 scion scion -"
      ];

      systemd.services =
        let
          baseplateServices =
            genAttrs
              [ "scion-dispatcher" "scion-border-router@" "scion-control-service@" "scion-daemon@" ]
              (service: {
                after = [ "network-online.target" ] ++ optional (service != "scion-dispatcher") "scion-dispatcher.service";
                wants = [ "network-online.target" ];
                partOf = [ "scionlab.target" ];
                # This seems to generate services with @scionlab
                # wantedBy = [ "scionlab.target" ];

                documentation = [ "https://www.scionlab.org" ];
                path = with pkgs; [ coreutils scion scion-systemd-wrapper openssl ];
                environment = {
                  TZ = "UTC";
                  GODEBUG = "cgocheck=0";
                };

                serviceConfig = {
                  Type = "simple";
                  User = "scion";
                  Group = "scion";

                  WorkingDirectory = "/var/lib/scion";

                  RestartSec = 10;
                  Restart = "on-failure";
                  RemainAfterExit = false;
                  KillMode = "control-group";
                };
              });
        in
        recursiveUpdate baseplateServices {
          scion-dispatcher = {
            description = "SCION Dispatcher";
            serviceConfig = {
              ExecStartPre = "${pkgs.coreutils}/bin/rm -rf /run/shm/dispatcher/";
              ExecStart = "${pkgs.scion-systemd-wrapper}/bin/scion-systemd-wrapper ${pkgs.scion}/bin/godispatcher /etc/scion/gen/dispatcher/disp.toml %i";
            };
          };

          "scion-border-router@" = {
            description = "SCION Border Router";
            serviceConfig = {
              ExecStart = "${pkgs.scion-systemd-wrapper}/bin/scion-systemd-wrapper ${pkgs.scion}/bin/border /etc/scion/gen/ISD-isd-/AS-as-/br%i/br.toml %i";
            };
          };

          "scion-control-service@" = {
            description = "SCION Control Service";
            serviceConfig = {
              ExecStart = "${pkgs.scion-systemd-wrapper}/bin/scion-systemd-wrapper ${pkgs.scion}/bin/cs /etc/scion/gen/ISD-isd-/AS-as-/cs%i/cs.toml %i";
            };

            preStart = ''
              old=$(umask)

              if [ ! -f gen-certs/tls.key ]; then
                umask 0177
                ${pkgs.openssl}/bin/openssl genrsa -out "gen-certs/tls.key" 2048
              fi

              if [ ! -f gen-certs/tls.pem ]; then
                umask "$old"
                ${pkgs.openssl}/bin/openssl req -new -x509 -key "gen-certs/tls.key" -out "gen-certs/tls.pem" -days 3650 -subj /CN=scion_def_srv
              fi
            '';
          };

          "scion-daemon@" = {
            description = "SCION Daemon";
            serviceConfig = {
              ExecStartPre = "${pkgs.coreutils}/bin/rm -rf /run/shm/sciond/";
              ExecStart = "${pkgs.scion-systemd-wrapper}/bin/scion-systemd-wrapper ${pkgs.scion}/bin/sciond /etc/scion/gen/ISD-isd-/AS-as-/endhost/sd.toml %i";
            };
          };
        };

      users = {
        users.scion = {
          group = "scion";
          description = "SCIONLab user";
        };

        groups.scion = { };
      };
    }
    )
  ];
}
