# Cross-repo guard: the daemon (hinteros-system) must accept every state.json this repo writes or
# ships, and the installer must produce what the daemon parses. `hinteros-system check-state`
# parses files with the same State::parse the service uses (exit 0 all valid, 1 invalid, 2 usage
# or IO); the check fails if it rejects any of
#   (a) devices/*/state.json,
#   (b) the state.json files hinteros-install writes (`--state-dir`, the real installer code path
#       and plan validation) for representative plans (the picks are the starter set,
#       not state; their box features are `requirements`),
#   (c) the VM test fixtures (tests/vm/fixtures/*/state.json).
# Builds a few text files; no VM.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  sys = (pkgs.extend self.overlays.default).hinteros-system;
  installer = self.nixosConfigurations.installer.config.hinteros.installer.package;
  # The same installer built for the beta channel (a beta ISO).
  betaInstaller = installer.override { defaultChannel = "beta"; };
  index = self.nixosConfigurations.installer.config.hinteros.catalog.index;
  entries = self.inputs.hinteros-catalog.catalog;
  appIds = import ../../nixos/lib/app-ids.nix entries;

  dirsWith =
    root: file:
    map (n: root + "/${n}/${file}") (
      lib.attrNames (
        lib.filterAttrs (n: t: t == "directory" && builtins.pathExists (root + "/${n}/${file}")) (
          builtins.readDir root
        )
      )
    );
  deviceStates = dirsWith ../../devices "state.json";
  fixtureStates = dirsWith ../vm/fixtures "state.json";

  # name -> plan fields besides the admin account, disk and defaults the installer needs. Terms are
  # accepted at the version of this ISO's catalog index (see the jq below).
  plans = {
    minimal = {
      network = "offline";
      apps = [ ];
    };
    offline-defaults = {
      network = "offline";
      apps = appIds.preselected;
    };
    offline-all-on-iso = {
      network = "offline";
      apps = appIds.onIso;
      ssh.enable = true;
    };
    online-ssh = {
      network = "online";
      ssh.enable = true;
      hostname = "tv-2";
      admin = {
        user = "alex";
        password = "password";
      };
      channel = "beta";
      apps = appIds.preselected;
    };
    online-all = {
      network = "online";
      apps = appIds.all;
      hostname = "livingroom";
      admin = {
        user = "james";
        hashedPassword = "$6$salt$0123456789abcdefABCDEF";
      };
    };
    online-one = {
      network = "online";
      apps = [ "steam" ];
    };
  };
  planFiles = lib.mapAttrs (
    n: p:
    pkgs.writeText "plan-${n}.json" (
      builtins.toJSON (
        {
          disk = "/dev/vdb";
          diskSeq = 1;
          hostname = "hinteros";
          admin = {
            user = "james";
            password = "hunter22";
          };
        }
        // p
      )
    )
  ) plans;
in
pkgs.runCommand "hinteros-state-check"
  {
    nativeBuildInputs = [
      sys
      installer
      pkgs.jq
    ];
  }
  ''
    export HINTEROS_INSTALL_LOG=$TMPDIR/install.log
    # Terms of every app that has them, accepted at the catalog's version.
    terms=$(jq -c '[.entries[] | select(.terms != null) | {key: .id, value: .terms.version}] | from_entries' \
      ${index}/share/hinteros/catalog.json)

    mkdir states
    ${lib.concatStrings (
      lib.mapAttrsToList (n: f: ''
        jq --argjson t "$terms" '. + {acceptedTerms: $t}' ${f} > plan.json
        hinteros-install --plan plan.json --state-dir states/${n} > progress.log || { cat progress.log; exit 1; }
      '') planFiles
    )}
    # The spare p1, no apps; the picks are the starter set and their box features the
    # requirements.
    test "$(jq -c '[.schemaVersion, .profiles, has("apps"), .requirements, .services]' states/minimal/system/state.json)" = '[2,[{"id":"p1"}],false,[],[]]'
    test "$(jq -c .disk states/minimal/system/state.json)" = '{"layout":"gpt-esp-btrfs","rootUuid":"00000000-0000-0000-0000-000000000000","espUuid":"0000-0000"}'
    test "$(jq -c .requirements states/online-one/apps/state.json)" = '["graphics32","steam-devices"]'
    test "$(jq -c .requirements states/offline-all-on-iso/apps/state.json)" = '[]'
    test "$(jq -c '[.version, .ids, .by]' states/online-one/apps/starter.json)" = '[1,["steam"],"installer"]'
    test "$(jq -c .ids states/minimal/apps/starter.json)" = '[]'
    test "$(jq -c .settings.ssh.enable states/online-ssh/apps/state.json)" = true
    test "$(jq -r .settings.admin.user states/online-ssh/apps/state.json)" = alex

    # The plan validation: an admin password shorter than 8 characters (the installer UI's
    # minimum) is refused with exit 2, also without SSH.
    jq --argjson t "$terms" '. + {acceptedTerms: $t} | .admin.password = "1234567"' ${planFiles.minimal} > short.json
    rc=0
    hinteros-install --plan short.json --state-dir states-short > short.log || rc=$?
    test "$rc" = 2 || { cat short.log; echo "a short admin password: exit $rc, not 2" >&2; exit 1; }
    grep -q '"code":"admin-password-short"' short.log || { cat short.log; exit 1; }

    # keepData: the disk, the channel and the network; the hostname, admin account (password
    # optional) and ssh only if they change. No state of its own. What it does not take (apps) is
    # refused, a bad hostname too; a normal plan still needs them.
    echo '{"disk":"/dev/vdb","diskSeq":1,"keepData":true,"channel":"beta","network":"offline"}' > keep.json
    hinteros-install --plan keep.json --state-dir states-keep > keep.log || { cat keep.log; exit 1; }
    test ! -e states-keep
    jq '. + {hostname: "tv", admin: {user: "alex"}, ssh: {enable: true}}' keep.json > keep-host.json
    hinteros-install --plan keep-host.json --state-dir states-keep > keep-host.log || { cat keep-host.log; exit 1; }
    test ! -e states-keep
    jq '. + {apps: ["youtube"]}' keep.json > keep-apps.json
    rc=0
    hinteros-install --plan keep-apps.json --state-dir states-keep > keep-apps.log || rc=$?
    test "$rc" = 2 || { cat keep-apps.log; echo "keepData with apps: exit $rc, not 2" >&2; exit 1; }
    grep -q '"code":"keep-data-field"' keep-apps.log || { cat keep-apps.log; exit 1; }
    jq '. + {hostname: "-tv"}' keep.json > keep-badhost.json
    rc=0
    hinteros-install --plan keep-badhost.json --state-dir states-keep > keep-badhost.log || rc=$?
    test "$rc" = 2 || { cat keep-badhost.log; exit 1; }
    grep -q '"code":"hostname-invalid"' keep-badhost.log || { cat keep-badhost.log; exit 1; }
    jq '.keepData = "yes"' keep.json > keep-bad.json
    rc=0
    hinteros-install --plan keep-bad.json --state-dir states-keep > keep-bad.log || rc=$?
    test "$rc" = 2 || { cat keep-bad.log; exit 1; }
    grep -q '"code":"keep-data-invalid"' keep-bad.log || { cat keep-bad.log; exit 1; }
    jq '.keepData = false' keep.json > keep-off.json
    rc=0
    hinteros-install --plan keep-off.json --state-dir states-keep > keep-off.log || rc=$?
    test "$rc" = 2 || { cat keep-off.log; exit 1; }
    grep -q '"code":"hostname-invalid"' keep-off.log || { cat keep-off.log; exit 1; }
    grep -q '"code":"admin-missing"' keep-off.log || { cat keep-off.log; exit 1; }

    # A profile's account name is no admin's.
    jq --argjson t "$terms" '. + {acceptedTerms: $t} | .admin.user = "hinteros-p1"' ${planFiles.minimal} > reserved.json
    rc=0
    hinteros-install --plan reserved.json --state-dir states-reserved > reserved.log || rc=$?
    test "$rc" = 2 || { cat reserved.log; echo "admin user hinteros-p1: exit $rc, not 2" >&2; exit 1; }
    grep -q '"code":"admin-user-reserved"' reserved.log || { cat reserved.log; exit 1; }

    # A beta installer: a plan for the stable channel needs the stable tip as `rev` (its own beta
    # revision is no stable release); beta, the default, is fine. A stable installer on beta is fine
    # (online-ssh above).
    jq --argjson t "$terms" '. + {acceptedTerms: $t, channel: "stable"}' ${planFiles.minimal} > stable.json
    rc=0
    ${lib.getExe' betaInstaller "hinteros-install"} --plan stable.json --state-dir states-beta > stable.log || rc=$?
    test "$rc" = 2 || { cat stable.log; echo "stable plan on a beta installer: exit $rc, not 2" >&2; exit 1; }
    grep -q '"code":"channel-needs-rev"' stable.log || { cat stable.log; exit 1; }
    jq 'del(.channel)' stable.json > beta.json
    ${lib.getExe' betaInstaller "hinteros-install"} --plan beta.json --state-dir states-beta > beta.log || { cat beta.log; exit 1; }
    rm -r states-beta

    find states -name state.json | sort
    hinteros-system check-state ${
      lib.concatStringsSep " " (map toString (deviceStates ++ fixtureStates))
    } $(find states -name state.json | sort)

    # The guard guards: another schema (exit 1) and a state without a required field are rejected.
    jq '.schemaVersion = 1' states/minimal/system/state.json > bad.json
    if hinteros-system check-state bad.json; then echo "check-state accepted schema 1" >&2; exit 1; fi
    jq 'del(.stateVersion)' states/minimal/system/state.json > bad.json
    if hinteros-system check-state bad.json; then echo "check-state accepted a state without stateVersion" >&2; exit 1; fi

    # A field the daemon does not know is ignored (a box on an older channel reads a newer state).
    jq '. + {nonsense: true}' states/minimal/system/state.json > unknown.json
    hinteros-system check-state unknown.json

    # settings.timeZone (time-zone.md): absent in every state above; a zone name is accepted, a
    # value that is not a string is not.
    jq '.settings.timeZone = "America/Chicago"' states/minimal/system/state.json > tz.json
    hinteros-system check-state tz.json
    jq '.settings.timeZone = 5' states/minimal/system/state.json > tz-bad.json
    if hinteros-system check-state tz-bad.json; then echo "check-state accepted timeZone 5" >&2; exit 1; fi
    # The disk's UUIDs are extra fields the daemon keeps.
    jq '.disk.rootUuid = "11111111-2222-3333-4444-555555555555"' states/minimal/system/state.json > disk.json
    hinteros-system check-state disk.json
    touch $out
  ''
