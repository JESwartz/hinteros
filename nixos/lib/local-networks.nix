# Firewall rules that let only the local networks (`hinteros.ssh.allowFrom`, IPv4 and IPv6 CIDR)
# reach a port: SSH (hardening.nix) and the servers' `lan` ports (server.nix). The nftables
# firewall gets `extraInputRules` lines, the iptables one `extraCommands` on `nixos-fw` (both are
# rebuilt from scratch on every firewall reload, so nothing is ever left behind).
{ lib }:
let
  join = lib.concatStringsSep ", ";
in
rec {
  isCidr =
    s:
    builtins.match "[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}" s != null
    || builtins.match "[0-9a-fA-F:]*:[0-9a-fA-F:]*/[0-9]{1,3}" s != null;

  v6 = lib.filter (lib.hasInfix ":");
  v4 = lib.filter (s: !lib.hasInfix ":" s);

  # `ports`: numbers or strings. Nothing when there are no ports or no networks of a family.
  nftRules =
    {
      from,
      proto,
      ports,
      comment,
    }:
    let
      p = join (map toString ports);
      line =
        family: nets:
        lib.optionalString (nets != [ ] && ports != [ ]) ''
          ${family} saddr { ${join nets} } ${proto} dport { ${p} } accept comment "${comment}"
        '';
    in
    line "ip" (v4 from) + line "ip6" (v6 from);

  iptablesRules =
    {
      from,
      proto,
      ports,
      comment,
      ipv6 ? true,
    }:
    lib.concatStrings (
      lib.concatMap (
        port:
        map (
          src:
          "iptables -w -A nixos-fw -p ${proto} --dport ${toString port} -s ${src} -m comment --comment ${comment} -j nixos-fw-accept\n"
        ) (v4 from)
        ++ lib.optionals ipv6 (
          map (
            src:
            "ip6tables -w -A nixos-fw -p ${proto} --dport ${toString port} -s ${src} -m comment --comment ${comment} -j nixos-fw-accept\n"
          ) (v6 from)
        )
      ) ports
    );
}
